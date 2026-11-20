// aria2c.exe -> Ghost Downloader (ghd) translation shim for Scoop
// ------------------------------------------------------------------
// Scoop invokes aria2c.exe with aria2-style CLI args and an --input-file
// queue. This shim accepts that exact contract and drives Ghost
// Downloader's official CLI (ghd.exe) instead:
//   ghd add <url> -o <dir> --name <out> -H "Referer: ..." --conflict overwrite
//   ghd wait <taskId>   (exit 0 only when completed)
//   ghd task <taskId>   (polled for progress display)
//   ghd remove <taskId> (cleanup, completed file kept)
// On any failure it falls back to the real aria2 binary kept beside it
// as aria2c-next.exe; if that is absent it returns nonzero so Scoop's
// own built-in-downloader fallback kicks in.
//
// Build (no dependencies beyond .NET Framework 4.x, ships with Windows):
//   csc /nologo /target:exe /optimize+ /r:System.Web.Extensions.dll /out:aria2c.exe Aria2GhostShim.cs
//
// ghd.exe resolution order:
//   1. env GHD_CLI (full path override, also used for testing)
//   2. <scoop>\apps\Ghost-Downloader-portable\current\bin\ghd.exe
//      (derived from this shim's own location: <scoop>\apps\aria2\current)
//   3. newest versioned folder under Ghost-Downloader-portable
//
// Notes / limits:
//   - Proxy follows Ghost Downloader's own settings; Scoop's --all-proxy
//     is not forwarded (ghd has no per-task proxy flag).
//   - aria2 tuning flags (--split etc.) are ignored; Ghost manages its
//     own threading. --user-agent / --header / referer ARE forwarded.
//   - First call auto-starts the Ghost Downloader app in the background.
//   - If Scoop's parent process dies (--stop-with-process), the shim
//     exits with code 7; the Ghost task keeps running and will finish
//     into Scoop's cache, which is harmless (next install hits cache).

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

static class Aria2GhostShim
{
    class Entry
    {
        public string Url;
        public string Dir;
        public string Out;
        public string Referer;
    }

    static readonly string ShimDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer();

    static int Main(string[] args)
    {
        try { Console.OutputEncoding = Encoding.UTF8; } catch { }

        foreach (string a in args)
        {
            if (a == "--version")
            {
                Console.WriteLine("aria2c ghost-shim 1.0 (Scoop -> Ghost Downloader CLI)");
                Console.WriteLine("fallback engine: aria2c-next.exe beside this file");
                return 0;
            }
            if (a == "--help" || a == "-h")
            {
                Console.WriteLine("aria2c ghost-shim: accepts Scoop's aria2 invocation (--input-file etc.)");
                Console.WriteLine("and downloads via Ghost Downloader's ghd CLI.");
                Console.WriteLine("Env GHD_CLI overrides the ghd.exe path.");
                Console.WriteLine("On failure, falls back to aria2c-next.exe in the same folder.");
                return 0;
            }
        }

        string inputFile = null, userAgent = null;
        List<string> headers = new List<string>();
        int parentPid = 0;
        List<string> positional = new List<string>();

        foreach (string a in args)
        {
            if (a.StartsWith("--", StringComparison.Ordinal))
            {
                int eq = a.IndexOf('=');
                string key = eq < 0 ? a : a.Substring(0, eq);
                string val = eq < 0 ? "" : a.Substring(eq + 1);
                switch (key)
                {
                    case "--input-file": inputFile = val; break;
                    case "--user-agent": userAgent = val; break;
                    case "--header": headers.Add(val); break;
                    case "--stop-with-process": int.TryParse(val, out parentPid); break;
                    default: break; // other aria2 options: ignored on purpose
                }
            }
            else if (a.Length > 0) positional.Add(a);
        }

        if (parentPid > 0)
        {
            Thread t = new Thread(() => WatchParent(parentPid));
            t.IsBackground = true;
            t.Start();
        }

        List<Entry> entries;
        try
        {
            entries = inputFile != null ? ParseInputFile(inputFile) : EntriesFromUrls(positional);
        }
        catch (Exception e)
        {
            Console.WriteLine("(ERR):cannot parse download input: " + e.Message);
            return 28; // aria2: bad/unrecognized option or argument
        }
        if (entries.Count == 0) return 0;

        string ghd = FindGhd();
        List<Entry> failed = new List<Entry>();
        if (ghd == null)
        {
            Console.WriteLine("[ghost-shim] ghd.exe not found; using fallback engine.");
            failed.AddRange(entries);
        }
        else
        {
            Console.WriteLine("[ghost-shim] engine: Ghost Downloader CLI");
            foreach (Entry e in entries)
                if (!DownloadViaGhost(ghd, e, userAgent, headers)) failed.Add(e);
        }

        if (failed.Count == 0) return 0;
        return FallbackToAria2(args, inputFile, failed, entries.Count);
    }

    // ---------------- Ghost engine ----------------

    static bool DownloadViaGhost(string ghd, Entry e, string ua, List<string> headers)
    {
        try
        {
            Directory.CreateDirectory(e.Dir);

            // file:/// URLs (e.g. local-bucket manifests): plain local copy,
            // no download engine involved. Keeps 'scoop install myScoopTools'
            // clean instead of relying on the aria2 fallback chain.
            if (e.Url.StartsWith("file:///", StringComparison.OrdinalIgnoreCase))
            {
                string local = Uri.UnescapeDataString(e.Url.Substring(8)).Replace('/', '\\');
                if (!File.Exists(local))
                {
                    Console.WriteLine("(ERR):local file not found: " + local);
                    return false;
                }
                File.Copy(local, Path.Combine(e.Dir, e.Out), true);
                Console.WriteLine("(OK):local file copied. " + e.Out);
                return true;
            }

            List<string> addArgs = new List<string>();
            addArgs.Add("add"); addArgs.Add(e.Url);
            addArgs.Add("-o"); addArgs.Add(e.Dir);
            addArgs.Add("--name"); addArgs.Add(e.Out);
            addArgs.Add("--conflict"); addArgs.Add("overwrite");
            if (!string.IsNullOrEmpty(e.Referer)) { addArgs.Add("-H"); addArgs.Add("Referer: " + e.Referer); }
            if (!string.IsNullOrEmpty(ua)) { addArgs.Add("-H"); addArgs.Add("User-Agent: " + ua); }
            foreach (string h in headers) { addArgs.Add("-H"); addArgs.Add(h); }

            string addOut = null;
            string taskId = null;
            int rc = 1;
            for (int attempt = 1; attempt <= 2; attempt++)
            {
                rc = RunCapture(ghd, addArgs, out addOut);
                taskId = ExtractTaskId(addOut);
                if (rc == 0 && taskId != null) break;
                if (attempt == 1)
                {
                    Console.WriteLine("[ghost-shim] ghd add failed (attempt 1), retrying in 3s: " + Compact(addOut));
                    Thread.Sleep(3000);
                }
            }
            if (rc != 0 || taskId == null)
            {
                Console.WriteLine("(ERR):ghd add failed: " + Compact(addOut));
                return false;
            }

            ProcessStartInfo psi = MakePsi(ghd, new string[] { "wait", taskId });
            psi.RedirectStandardOutput = true;
            psi.StandardOutputEncoding = Encoding.UTF8;
            Process wait = Process.Start(psi);

            while (!wait.WaitForExit(1500))
            {
                string tOut;
                if (RunCapture(ghd, new string[] { "task", taskId }, out tOut) == 0)
                {
                    Dictionary<string, object> d = FirstResult(tOut);
                    if (d != null)
                    {
                        double prog = Num(d, "progress");
                        double size = Num(d, "fileSize");
                        Console.WriteLine("[DL:" + prog.ToString("0.#") + "% " +
                            Size(prog / 100.0 * size) + "/" + Size(size) + "]");
                    }
                }
            }
            // wait prints exactly one small JSON line at the end; read it
            // synchronously after exit (deterministic, no async-read race).
            string waitOut = wait.StandardOutput.ReadToEnd();
            wait.WaitForExit();
            int wrc = wait.ExitCode;
            Dictionary<string, object> res = FirstResult(waitOut);
            if (res == null)
            {
                string finalOut;
                if (RunCapture(ghd, new string[] { "task", taskId }, out finalOut) == 0)
                    res = FirstResult(finalOut);
            }
            string st = res != null ? Str(res, "status") : null;

            if (wrc == 0 && st == "completed")
            {
                string target = Path.Combine(e.Dir, e.Out);
                if (!File.Exists(target) && res != null)
                {
                    string of = Str(res, "outputFolder"), nm = Str(res, "name");
                    if (!string.IsNullOrEmpty(of) && !string.IsNullOrEmpty(nm))
                    {
                        string src = Path.Combine(of, nm);
                        if (File.Exists(src) && !src.Equals(target, StringComparison.OrdinalIgnoreCase))
                        {
                            if (File.Exists(target)) File.Delete(target);
                            File.Move(src, target);
                        }
                    }
                }
                string dummy;
                RunCapture(ghd, new string[] { "remove", taskId }, out dummy);
                if (File.Exists(target))
                {
                    Console.WriteLine("(OK):download completed. " + e.Out);
                    return true;
                }
                Console.WriteLine("(ERR):completed but file missing: " + target);
                return false;
            }

            string err = res != null ? Str(res, "error") : null;
            Console.WriteLine("(ERR):ghd download failed [" + (st ?? ("exit " + wrc)) + "] " +
                Compact(err ?? waitOut));
            string dummy2;
            RunCapture(ghd, new string[] { "remove", taskId }, out dummy2);
            return false;
        }
        catch (Exception ex)
        {
            Console.WriteLine("(ERR):ghost engine exception: " + ex.Message);
            return false;
        }
    }

    // ---------------- fallback to real aria2 ----------------

    static int FallbackToAria2(string[] origArgs, string inputFile, List<Entry> failed, int total)
    {
        string real = Path.Combine(ShimDir, "aria2c-next.exe");
        if (!File.Exists(real))
        {
            Console.WriteLine("(ERR):download failed; no fallback engine (aria2c-next.exe) present.");
            return 1;
        }
        Console.WriteLine("[ghost-shim] " + failed.Count + "/" + total +
            " task(s) failed; fallback to aria2-next...");

        string tmp = Path.Combine(Path.GetTempPath(),
            "scoop-ghost-fallback-" + Guid.NewGuid().ToString("N") + ".txt");
        try
        {
            StringBuilder sb = new StringBuilder();
            foreach (Entry e in failed)
            {
                sb.AppendLine(e.Url);
                if (!string.IsNullOrEmpty(e.Referer)) sb.AppendLine("    referer=" + e.Referer);
                sb.AppendLine("    dir=" + e.Dir);
                sb.AppendLine("    out=" + e.Out);
            }
            File.WriteAllText(tmp, sb.ToString(), new UTF8Encoding(false));

            List<string> newArgs = new List<string>();
            if (inputFile != null)
            {
                foreach (string a in origArgs)
                {
                    if (a.StartsWith("--input-file=", StringComparison.Ordinal))
                        newArgs.Add("--input-file=" + tmp);
                    else newArgs.Add(a);
                }
            }
            else
            {
                foreach (string a in origArgs)
                    if (a.StartsWith("--", StringComparison.Ordinal)) newArgs.Add(a);
                newArgs.Add("--input-file=" + tmp);
            }

            ProcessStartInfo psi = MakePsi(real, newArgs); // console inherited, output streams to Scoop
            using (Process p = Process.Start(psi))
            {
                p.WaitForExit();
                return p.ExitCode;
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine("(ERR):fallback engine failed to start: " + ex.Message);
            return 1;
        }
        finally { try { File.Delete(tmp); } catch { } }
    }

    // ---------------- input parsing ----------------

    static List<Entry> ParseInputFile(string path)
    {
        List<Entry> list = new List<Entry>();
        Entry cur = null;
        foreach (string raw in File.ReadAllLines(path, Encoding.UTF8))
        {
            if (raw.Trim().Length == 0) continue;
            string line = raw.TrimEnd();
            string trimmed = line.TrimStart();
            if (trimmed.StartsWith("#", StringComparison.Ordinal)) continue;

            if (char.IsWhiteSpace(raw[0]))
            {
                if (cur == null) continue;
                int eq = trimmed.IndexOf('=');
                if (eq < 0) continue;
                string k = trimmed.Substring(0, eq).Trim();
                string v = trimmed.Substring(eq + 1).Trim();
                if (k == "dir") cur.Dir = v;
                else if (k == "out") cur.Out = v;
                else if (k == "referer") cur.Referer = v;
                // other per-url aria2 options ignored
            }
            else
            {
                cur = new Entry();
                cur.Url = StripScoopFragment(trimmed);
                cur.Dir = Environment.CurrentDirectory;
                cur.Out = FileNameFromUrl(cur.Url);
                list.Add(cur);
            }
        }
        return list;
    }

    static List<Entry> EntriesFromUrls(List<string> urls)
    {
        List<Entry> list = new List<Entry>();
        foreach (string u in urls)
        {
            Entry e = new Entry();
            e.Url = StripScoopFragment(u);
            e.Dir = Environment.CurrentDirectory;
            e.Out = FileNameFromUrl(e.Url);
            list.Add(e);
        }
        return list;
    }

    // Scoop appends "#/filename" to URLs as rename metadata; it is not
    // part of the real request URL (aria2 ignores it, Ghost may choke).
    static string StripScoopFragment(string url)
    {
        int i = url.IndexOf("#/", StringComparison.Ordinal);
        return i >= 0 ? url.Substring(0, i) : url;
    }

    static string FileNameFromUrl(string url)
    {
        string u = url;
        int q = u.IndexOfAny(new char[] { '?', '#' });
        if (q >= 0) u = u.Substring(0, q);
        int s = u.LastIndexOf('/');
        string n = s >= 0 ? u.Substring(s + 1) : u;
        if (n.Length == 0) n = "download";
        foreach (char c in Path.GetInvalidFileNameChars()) n = n.Replace(c, '_');
        return n;
    }

    // ---------------- ghd discovery ----------------

    static string FindGhd()
    {
        string env = Environment.GetEnvironmentVariable("GHD_CLI");
        if (!string.IsNullOrEmpty(env)) return File.Exists(env) ? env : null;
        try
        {
            // shim lives at <scoop>\apps\aria2\current\aria2c.exe
            DirectoryInfo apps = Directory.GetParent(ShimDir).Parent;
            if (apps != null)
            {
                string ghostBase = Path.Combine(apps.FullName, "Ghost-Downloader-portable");
                string cur = Path.Combine(ghostBase, @"current\bin\ghd.exe");
                if (File.Exists(cur)) return cur;
                if (Directory.Exists(ghostBase))
                {
                    List<string> versions = new List<string>(Directory.GetDirectories(ghostBase));
                    versions.Sort();
                    versions.Reverse();
                    foreach (string v in versions)
                    {
                        string p = Path.Combine(v, @"bin\ghd.exe");
                        if (File.Exists(p)) return p;
                    }
                }
            }
        }
        catch { }
        return null;
    }

    // ---------------- parent-process watch ----------------

    static void WatchParent(int pid)
    {
        while (true)
        {
            try
            {
                Process p = Process.GetProcessById(pid);
                if (p.HasExited) break;
            }
            catch (ArgumentException) { break; } // pid no longer exists
            catch { }                          // transient access error: keep watching
            Thread.Sleep(2000);
        }
        Console.WriteLine("[ghost-shim] parent process gone; exiting.");
        Environment.Exit(7);
    }

    // ---------------- process helpers ----------------

    static ProcessStartInfo MakePsi(string exe, IEnumerable<string> args)
    {
        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = exe;
        psi.Arguments = JoinArgs(args);
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        return psi;
    }

    static int RunCapture(string exe, IEnumerable<string> args, out string stdout)
    {
        ProcessStartInfo psi = MakePsi(exe, args);
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.StandardOutputEncoding = Encoding.UTF8;
        psi.StandardErrorEncoding = Encoding.UTF8;
        using (Process p = Process.Start(psi))
        {
            StringBuilder esb = new StringBuilder();
            p.ErrorDataReceived += (s, ev) => { if (ev.Data != null) esb.AppendLine(ev.Data); };
            p.BeginErrorReadLine();
            string o = p.StandardOutput.ReadToEnd();
            p.WaitForExit();
            stdout = esb.Length > 0 ? o + "\n" + esb.ToString() : o;
            return p.ExitCode;
        }
    }

    // MSVCRT-style argument quoting (matches how PowerShell/aria2 parse args)
    static string JoinArgs(IEnumerable<string> args)
    {
        StringBuilder sb = new StringBuilder();
        foreach (string a in args)
        {
            if (sb.Length > 0) sb.Append(' ');
            if (a.Length > 0 && a.IndexOfAny(new char[] { ' ', '\t', '"' }) < 0)
            {
                sb.Append(a);
                continue;
            }
            sb.Append('"');
            int backslashes = 0;
            foreach (char c in a)
            {
                if (c == '\\') { backslashes++; continue; }
                if (c == '"')
                {
                    sb.Append('\\', backslashes * 2 + 1);
                    backslashes = 0;
                    sb.Append('"');
                    continue;
                }
                if (backslashes > 0) { sb.Append('\\', backslashes); backslashes = 0; }
                sb.Append(c);
            }
            sb.Append('\\', backslashes * 2);
            sb.Append('"');
        }
        return sb.ToString();
    }

    // ---------------- JSON helpers ----------------

    static string ExtractTaskId(string json)
    {
        if (string.IsNullOrEmpty(json)) return null;
        Match m = Regex.Match(json, @"tsk_[0-9a-zA-Z]+");
        return m.Success ? m.Value : null;
    }

    static Dictionary<string, object> FirstResult(string json)
    {
        if (string.IsNullOrEmpty(json)) return null;
        try
        {
            Dictionary<string, object> root =
                Json.Deserialize<Dictionary<string, object>>(json.Trim());
            if (root == null || !root.ContainsKey("result")) return null;
            object r = root["result"];
            object[] arr = r as object[];
            if (arr != null) return arr.Length > 0 ? arr[0] as Dictionary<string, object> : null;
            return r as Dictionary<string, object>;
        }
        catch { return null; }
    }

    static string Str(Dictionary<string, object> d, string k)
    {
        object v;
        if (d == null || !d.TryGetValue(k, out v) || v == null) return null;
        return Convert.ToString(v);
    }

    static double Num(Dictionary<string, object> d, string k)
    {
        object v;
        if (d == null || !d.TryGetValue(k, out v) || v == null) return 0;
        try { return Convert.ToDouble(v); } catch { return 0; }
    }

    static string Size(double b)
    {
        if (b >= 1073741824) return (b / 1073741824).ToString("0.0") + "GiB";
        if (b >= 1048576) return (b / 1048576).ToString("0.0") + "MiB";
        if (b >= 1024) return (b / 1024).ToString("0.0") + "KiB";
        return ((long)b) + "B";
    }

    static string Compact(string s)
    {
        if (string.IsNullOrEmpty(s)) return "";
        s = Regex.Replace(s, @"\s+", " ").Trim();
        return s.Length > 300 ? s.Substring(0, 300) + "..." : s;
    }
}