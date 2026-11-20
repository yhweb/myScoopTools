#Requires -Version 5.1
<#
.SYNOPSIS
    scoop-deepclean — scoop 一键深度清理（放入 shims，命令行直接可用）
.DESCRIPTION
    默认依次执行：
      1) scoop cleanup *   （逻辑复制自官方 libexec/scoop-cleanup.ps1）
      2) scoop cache rm *  （逻辑复制自官方 libexec/scoop-cache.ps1）
      3) 逐项回车确认：bun pm cache rm / uv cache clean / pnpm store prune
         回车=执行该项，s=跳过该项，q=结束后续所有项
    删除遇到文件占用时，定位占用进程（exe 路径或加载模块位于目标目录内），
    询问是否结束进程后重试（默认 N，不结束）。
.PARAMETER DryRun
    只预览将清理的内容与体积，不删除、不询问、不执行任何命令。
.NOTES
    清理逻辑来源（保持同源，便于对照升级）：
      D:\Scoop\apps\scoop\current\libexec\scoop-cleanup.ps1
      D:\Scoop\apps\scoop\current\libexec\scoop-cache.ps1
      lib\versions.ps1  -> Select-CurrentVersion / Get-InstalledVersion
      lib\install.ps1   -> unlink_persist_data / persist_def
    建议用 pwsh 7 运行（Remove-Item 对 junction 的处理更安全）。
#>
[CmdletBinding()]
param([switch]$DryRun)

$ErrorActionPreference = 'Stop'

# ---------- 路径解析（与 scoop core.ps1 一致） ----------
$script:ScoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
$script:CfgFile   = Join-Path $env:USERPROFILE '.config\scoop\config.json'
$script:Cfg       = if (Test-Path $script:CfgFile) { try { Get-Content $script:CfgFile -Raw | ConvertFrom-Json } catch { $null } } else { $null }
$script:AppsDir   = Join-Path $script:ScoopRoot 'apps'
$script:CacheDir  = if ($env:SCOOP_CACHE) { $env:SCOOP_CACHE } elseif ($script:Cfg -and $script:Cfg.cachePath) { $script:Cfg.cachePath } else { Join-Path $script:ScoopRoot 'cache' }
$script:Freed     = [long]0
$script:Potential = [long]0

function Write-Info($msg)  { Write-Host $msg -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host $msg -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host $msg -ForegroundColor Yellow }
function Write-Err2($msg)  { Write-Host $msg -ForegroundColor Red }

function Get-DirSize([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return [long]0 }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item -isnot [System.IO.DirectoryInfo]) { return [long]$item.Length }
    # 不跟随 junction，避免把 persist 数据算进来
    $sum = [long]0
    $stack = [System.Collections.Stack]::new()
    $stack.Push($item)
    while ($stack.Count) {
        $d = $stack.Pop()
        foreach ($c in (Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue)) {
            if ($c.LinkType) { continue }
            if ($c -is [System.IO.DirectoryInfo]) { $stack.Push($c) } else { $sum += $c.Length }
        }
    }
    return $sum
}

function Format-Size([long]$Bytes) {
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}

# ---------- 复制自官方 lib\versions.ps1: Select-CurrentVersion / Get-InstalledVersion ----------
function Get-AppCurrentVersion([string]$AppDir) {
    $currentPath = Join-Path $AppDir 'current'
    $v = $null
    if (Test-Path -LiteralPath $currentPath) {
        $mf = Join-Path $currentPath 'scoop-manifest.json'
        if (-not (Test-Path -LiteralPath $mf)) { $mf = Join-Path $currentPath 'manifest.json' }
        if (Test-Path -LiteralPath $mf) {
            try { $v = (Get-Content -LiteralPath $mf -Raw | ConvertFrom-Json).version } catch { $v = $null }
        }
        if ($v -eq 'nightly') {
            $t = @((Get-Item -LiteralPath $currentPath).Target)[0]
            if ($t) { $v = Split-Path $t -Leaf }
        }
    }
    if (-not $v) {
        $installed = @(Get-ChildItem (Join-Path $AppDir '*\scoop-install.json'), (Join-Path $AppDir '*\install.json') -ErrorAction SilentlyContinue |
            Sort-Object -Property LastWriteTimeUtc | ForEach-Object { $_.Directory.Name } | Select-Object -Unique |
            Where-Object { $_ -ne 'current' -and $_ -notlike '_*.old*' })
        if ($installed.Count) { $v = $installed[-1] }
    }
    if (-not $v -and (Test-Path -LiteralPath $currentPath)) {
        $t = @((Get-Item -LiteralPath $currentPath).Target)[0]
        if ($t) { $v = Split-Path $t -Leaf }
    }
    return $v
}

# ---------- 复制自官方 lib\install.ps1: persist_def / unlink_persist_data ----------
function Get-PersistSource($persist) {
    if ($persist -is [Array]) { return $persist[0] }
    return $persist
}

function Remove-PersistLinks($manifest, [string]$Dir) {
    if (-not $manifest -or -not $manifest.persist) { return }
    foreach ($p in @($manifest.persist)) {
        $source = Get-PersistSource $p
        $item = Get-Item -LiteralPath (Join-Path $Dir $source) -Force -ErrorAction SilentlyContinue
        if ($item -and $item.LinkType) {
            if ($item -is [System.IO.DirectoryInfo]) {
                attrib -R /L $item.FullName
                Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
            } else {
                Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ---------- 占用进程定位与“询问 kill 后重试”删除 ----------
# Restart Manager：Windows 官方“文件正在使用”对话框同款机制，
# 能定位独占打开文件、加载 DLL、甚至工作目录在目标目录内的进程。
if (-not ('Win32.RestartManager' -as [type])) {
    Add-Type -Namespace Win32 -Name RestartManager -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct RM_UNIQUE_PROCESS { public int dwProcessId; public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime; }
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct RM_PROCESS_INFO {
    public RM_UNIQUE_PROCESS Process;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string strAppName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string strServiceShortName;
    public int ApplicationType; public uint AppStatus; public uint TSSessionId;
    [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
}
[DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
public static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);
[DllImport("rstrtmgr.dll")]
public static extern int RmEndSession(uint pSessionHandle);
[DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
public static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames,
    uint nApplications, RM_UNIQUE_PROCESS[] rgApplications, uint nServices, string[] rgsServiceNames);
[DllImport("rstrtmgr.dll")]
public static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded, ref uint pnProcInfo,
    [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);
'@
}

function Get-RmLockingPid([string[]]$Files) {
    $pids = @()
    if (-not $Files.Count) { return $pids }
    $session = 0
    $key = [Guid]::NewGuid().ToString('N')
    if ([Win32.RestartManager]::RmStartSession([ref]$session, 0, $key) -ne 0) { return $pids }
    try {
        $reg = [Win32.RestartManager]::RmRegisterResources($session, [uint32]$Files.Count, $Files, 0, $null, 0, $null)
        if ($reg -ne 0) { return $pids }
        [uint32]$needed = 0; [uint32]$count = 0; [uint32]$reason = 0
        $r = [Win32.RestartManager]::RmGetList($session, [ref]$needed, [ref]$count, $null, [ref]$reason)
        if ($r -eq 234 -and $needed -gt 0) { # ERROR_MORE_DATA
            $count = $needed
            $arr = [Win32.RestartManager+RM_PROCESS_INFO[]]::new($count)
            $r = [Win32.RestartManager]::RmGetList($session, [ref]$needed, [ref]$count, $arr, [ref]$reason)
            if ($r -eq 0) { $pids = @($arr | Select-Object -First $count | ForEach-Object { $_.Process.dwProcessId }) }
        } elseif ($r -eq 0 -and $count -gt 0) {
            $pids = @($arr | ForEach-Object { $_.Process.dwProcessId })
        }
    } finally { [void][Win32.RestartManager]::RmEndSession($session) }
    return $pids
}

function Get-LockingProcess([string]$Target) {
    $isDir = Test-Path -LiteralPath $Target -PathType Container
    $scanDir = if ($isDir) { $Target } else { Split-Path $Target -Parent }
    $full = (Resolve-Path -LiteralPath $scanDir).Path.TrimEnd('\')
    $prefix = "$full\"
    $ids = [System.Collections.Generic.HashSet[int]]::new()

    # 1) exe 路径位于目标目录内的进程（典型：直接从旧版本目录运行的程序）
    foreach ($p in (Get-Process)) {
        if ($p.Id -eq $PID -or $p.Id -le 4) { continue }
        $pp = $null
        try { $pp = $p.Path } catch {}
        if ($pp -and $pp.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { [void]$ids.Add($p.Id) }
    }

    # 2) Restart Manager 精确定位（独占句柄 / 加载的 DLL / 工作目录占用）
    $files = if ($isDir) {
        @(Get-ChildItem -LiteralPath $Target -Recurse -File -Force -ErrorAction SilentlyContinue |
            Select-Object -First 1000 -ExpandProperty FullName)
    } else { @($Target) }
    foreach ($rmPid in (Get-RmLockingPid $files)) {
        if ($rmPid -ne $PID -and $rmPid -gt 4) { [void]$ids.Add($rmPid) }
    }

    $result = foreach ($id in $ids) { Get-Process -Id $id -ErrorAction SilentlyContinue }
    return @($result | Sort-Object Id -Unique)
}

function Remove-ItemLocked([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return $true
        } catch {
            if (-not (Test-Path -LiteralPath $Path)) { return $true }
            $locks = @(Get-LockingProcess $Path)
            if (-not $locks.Count) {
                Write-Warn2 "  占用中且无法定位进程，已跳过：$Label"
                Write-Warn2 "  原因：$($_.Exception.Message)"
                Write-Warn2 '  可用 资源监视器/CPU/关联的句柄 搜索该路径排查后重试。'
                return $false
            }
            Write-Warn2 "  删除失败（文件被占用）：$Label"
            Write-Warn2 '  检测到以下占用进程：'
            foreach ($lp in $locks) {
                $lpath = $null; try { $lpath = $lp.Path } catch {}
                Write-Host ("    PID {0,-7} {1,-28} {2}" -f $lp.Id, $lp.ProcessName, $lpath)
            }
            $ans = Read-Host '  是否结束上述进程并重试删除? [y/N]'
            if ($ans -notmatch '^\s*[Yy]') {
                Write-Warn2 "  已跳过：$Label"
                return $false
            }
            foreach ($lp in $locks) {
                try { Stop-Process -Id $lp.Id -Force -ErrorAction Stop; Write-Info "  已结束进程 $($lp.ProcessName) (PID $($lp.Id))" } catch { Write-Warn2 "  结束进程 $($lp.Id) 失败：$($_.Exception.Message)" }
            }
            Start-Sleep -Milliseconds 800
        }
    }
    Write-Err2 "  重试后仍无法删除，已跳过：$Label"
    return $false
}

# ---------- 阶段1：scoop cleanup *（复制官方 cleanup() 主流程） ----------
function Invoke-CleanupAll {
    Write-Info '=== [1/3] scoop cleanup * —— 清理所有应用旧版本 ==='
    foreach ($appDir in (Get-ChildItem -LiteralPath $script:AppsDir -Directory)) {
        $app = $appDir.Name
        $versionDirs = @(Get-ChildItem -LiteralPath $appDir.FullName -Directory | Where-Object { $_.Name -ne 'current' })
        if (-not $versionDirs.Count) { continue }
        $current = Get-AppCurrentVersion $appDir.FullName
        if (-not $current) {
            Write-Warn2 "跳过 ${app}：无法确定当前版本（为安全起见不删除）"
            continue
        }
        $old = @($versionDirs | Where-Object { $_.Name -ne $current })
        if (-not $old.Count) { continue }

        Write-Host -ForegroundColor Yellow "Removing ${app}:" -NoNewline
        foreach ($ver in $old) {
            Write-Host " $($ver.Name)" -NoNewline
            $dir = $ver.FullName
            $size = Get-DirSize $dir
            if ($DryRun) {
                Write-Host " [预览 $(Format-Size $size)]" -NoNewline
                $script:Potential += $size
                continue
            }
            # 官方顺序：先解除 persist 链接，再递归删除
            $mfPath = Join-Path $dir 'scoop-manifest.json'
            if (-not (Test-Path -LiteralPath $mfPath)) { $mfPath = Join-Path $dir 'manifest.json' }
            $manifest = if (Test-Path -LiteralPath $mfPath) { try { Get-Content -LiteralPath $mfPath -Raw | ConvertFrom-Json } catch { $null } } else { $null }
            Remove-PersistLinks $manifest $dir
            if (Remove-ItemLocked $dir "$app/$($ver.Name)") {
                $script:Freed += $size
            }
        }
        Write-Host ''

        if (-not $DryRun) {
            # 官方收尾：只剩 current 链接且目标已不存在时，移除空壳目录
            $left = @(Get-ChildItem -LiteralPath $appDir.FullName -Force)
            if ($left.Count -eq 1 -and $left[0].Name -eq 'current' -and $left[0].LinkType) {
                $t = @($left[0].Target)[0]
                if (-not $t -or -not (Test-Path -LiteralPath $t)) {
                    attrib $left[0].FullName -R /L
                    Remove-Item -LiteralPath $left[0].FullName -Force -ErrorAction SilentlyContinue
                    Remove-Item -LiteralPath $appDir.FullName -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
    if ($DryRun) { Write-Ok '（预览模式，未删除）' } else { Write-Ok '旧版本清理完成。' }
}

# ---------- 阶段2：scoop cache rm *（复制官方 cacheremove() 主流程） ----------
function Invoke-CacheRmAll {
    Write-Info '=== [2/3] scoop cache rm * —— 清空下载缓存 ==='
    if (-not (Test-Path -LiteralPath $script:CacheDir)) { Write-Warn2 "缓存目录不存在：$($script:CacheDir)"; return }
    $files = @(Get-ChildItem -LiteralPath $script:CacheDir -File)
    $total = ($files | Measure-Object -Property Length -Sum).Sum
    if (-not $files.Count) { Write-Ok '缓存已是空的。'; return }
    Write-Host ("缓存共 {0} 个文件，{1}" -f $files.Count, (Format-Size $total))
    $deleted = 0
    foreach ($f in $files) {
        if ($DryRun) { Write-Host "  [预览] $($f.Name)  $(Format-Size $f.Length)"; $script:Potential += $f.Length; continue }
        Write-Host "Removing $($f.Name)..."
        if (Remove-ItemLocked $f.FullName $f.Name) {
            $deleted++
            $script:Freed += $f.Length
            $appName = ($f.Name -split '#')[0]
            $urlTxt = Join-Path $script:CacheDir "$appName.txt"
            if (Test-Path -LiteralPath $urlTxt) { Remove-Item -LiteralPath $urlTxt -Force -ErrorAction SilentlyContinue }
        }
    }
    if ($DryRun) { Write-Ok '（预览模式，未删除）' } else { Write-Ok ("已删除 {0} 个缓存文件。" -f $deleted) }
}

# ---------- 阶段3：逐项回车确认的第三方缓存清理 ----------
function Invoke-OptionalSteps {
    Write-Info '=== [3/3] 开发工具缓存 —— 逐项确认（回车=执行 / s=跳过 / q=结束后续） ==='
    $steps = @(
        @{ Name = 'bun';  Exe = 'bun';  Args = @('pm', 'cache', 'rm');   Desc = 'bun 安装缓存' },
        @{ Name = 'uv';   Exe = 'uv';   Args = @('cache', 'clean');      Desc = 'uv 下载/构建缓存' },
        @{ Name = 'pnpm'; Exe = 'pnpm'; Args = @('store', 'prune');      Desc = 'pnpm store 中未被引用的包' }
    )
    foreach ($s in $steps) {
        $full = "$($s.Exe) $($s.Args -join ' ')"
        $cmd = Get-Command $s.Exe -ErrorAction SilentlyContinue
        if (-not $cmd) { Write-Warn2 "未找到 $($s.Exe) 命令，跳过（$full）"; continue }
        if ($DryRun) { Write-Host "  [预览] $full  —— $($s.Desc)"; continue }

        $runArgs = @($s.Args)
        $skipConfirm = $false
        # uv 特判：uv run / uvx 等长驻进程会持有缓存锁，
        # 直接 uv cache clean 会无限等待（"Cache is currently in-use..."）。
        if ($s.Name -eq 'uv') {
            $uvProcs = @(Get-Process -Name 'uv' -ErrorAction SilentlyContinue)
            if ($uvProcs.Count) {
                Write-Warn2 "检测到 $($uvProcs.Count) 个 uv 进程正在运行，uv 缓存被锁定（直接清理会一直等待）："
                foreach ($up in $uvProcs) {
                    $cl = $null
                    try { $cl = (Get-CimInstance Win32_Process -Filter "ProcessId=$($up.Id)" -ErrorAction SilentlyContinue).CommandLine } catch {}
                    Write-Host ("    PID {0,-7} {1}" -f $up.Id, $cl)
                }
                $ua = Read-Host '  s=跳过(默认，直接回车) / f=强制清理(--force，可能影响运行中的 uv 任务) / w=等待执行(阻塞到上述进程退出)'
                if ($ua -match '^\s*[Ff]') {
                    $runArgs += '--force'
                    $skipConfirm = $true
                    Write-Warn2 '将使用 --force 强制清理（忽略占用检查）'
                } elseif ($ua -match '^\s*[Ww]') {
                    $skipConfirm = $true
                    Write-Warn2 '将等待缓存锁释放（可能长时间阻塞，Ctrl+C 可取消）'
                } else {
                    Write-Warn2 '已跳过：uv cache clean（建议停掉相关 uv 进程后再清）'
                    continue
                }
            }
        }

        if (-not $skipConfirm) {
            $ans = Read-Host "回车执行 [$full]（$($s.Desc)），s=跳过，q=结束后续"
            if ($ans -match '^\s*[Qq]') { Write-Warn2 '已结束后续清理项。'; break }
            if ($ans -match '^\s*[Ss]') { Write-Warn2 "已跳过：$full"; continue }
        }
        Write-Info "执行：$($s.Exe) $($runArgs -join ' ')"
        try {
            & $cmd.Source @runArgs
            if ($LASTEXITCODE -eq 0) { Write-Ok "完成：$full" } else { Write-Warn2 "$full 退出码 $LASTEXITCODE" }
        } catch { Write-Err2 "执行失败：$($_.Exception.Message)" }
    }
}

function Invoke-Main {
    Write-Host ''
    Write-Info "scoop-deepclean  |  SCOOP=$($script:ScoopRoot)  CACHE=$($script:CacheDir)"
    if ($DryRun) { Write-Warn2 '*** 预览模式（-DryRun）：只统计，不删除、不执行 ***' }
    Write-Host ''
    Invoke-CleanupAll
    Write-Host ''
    Invoke-CacheRmAll
    Write-Host ''
    Invoke-OptionalSteps
    Write-Host ''
    if ($DryRun) {
        Write-Ok ("预览合计可释放：{0}" -f (Format-Size $script:Potential))
    } else {
        Write-Ok ("本次共释放：{0}（bun/uv/pnpm 清理量见各自输出）" -f (Format-Size $script:Freed))
    }
}

# 供测试 dot-source 时只加载函数、不执行主流程
if ($MyInvocation.InvocationName -ne '.') { Invoke-Main }