# aria2 → Ghost Downloader 转译壳（Scoop 专用）

让 Scoop 内部下载（原本调用 aria2c.exe）改走 **Ghost Downloader 的官方 CLI `ghd.exe`**。
Scoop 无需任何改动；对 Scoop 来说它仍然是一个"aria2c.exe"。

## 工作原理

```
scoop install/update/download
  └─ Invoke-CachedAria2Download（Scoop 源码，不变）
       └─ apps\aria2\current\aria2c.exe   ← 本壳（替换了原 exe）
            ├─ 解析 aria2 参数 + --input-file 队列（URL / dir / out / referer）
            ├─ 逐条: ghd add <url> -o <dir> --name <out> -H "Referer/UA/Cookie" --conflict overwrite
            │        ghd wait <taskId>（期间轮询 ghd task 输出进度行）
            │        ghd remove <taskId>（清任务记录，保留文件）
            ├─ 全部成功 → 退出码 0，Scoop 继续 hash 校验与安装
            └─ 任一失败 → 自动回退 aria2c-next.exe（真 aria2-next，仅重试失败条目）
                 └─ 仍失败 → 非 0 退出，Scoop 再回退内置 .NET 下载器
```

- 首次调用会自动在后台拉起 Ghost Downloader 主程序（ghd 的官方行为）。
- 代理跟随 Ghost Downloader 自身设置（当前为 Auto = 系统代理）；
  Scoop 的 `--all-proxy` 不会透传（ghd 无逐任务代理参数）。
- `--split` 等 aria2 调优参数被忽略，线程数由 Ghost 自己管理；
  `--user-agent`、`--header`（Cookie）、referer 会透传给 ghd。
- Scoop URL 尾部的 `#/文件名` 重命名语法会被剥掉后再交给 ghd。
- `--stop-with-process`：Scoop 进程消失时壳自动退出（码 7）；
  Ghost 任务会继续下完并落入 Scoop 缓存，无害（下次安装直接命中缓存）。

## 文件布局

| 位置 | 内容 |
|---|---|
| `D:\Scoop\aria2-ghost-shim\Aria2GhostShim.cs` | 壳源码（C#，仅依赖 .NET Framework 4.x） |
| `D:\Scoop\aria2-ghost-shim\build.ps1` | 编译脚本（系统自带 csc） |
| `D:\Scoop\aria2-ghost-shim\test.ps1` | 双路径测试：Ghost 引擎 + aria2-next 回退 |
| `D:\Scoop\apps\aria2\current\aria2c.exe` | 部署的壳 |
| `D:\Scoop\apps\aria2\current\aria2c-next.exe` | 回退引擎（aria2-next 3.1.1 快照） |

ghd.exe 定位顺序：环境变量 `GHD_CLI` → `apps\Ghost-Downloader-portable\current\bin\ghd.exe`
（按壳自身位置推导）→ 最新版本目录。Ghost 升级后无需改壳。

## 构建 / 测试 / 部署

```powershell
pwsh -File D:\Scoop\aria2-ghost-shim\build.ps1     # 编译
pwsh -File D:\Scoop\aria2-ghost-shim\test.ps1      # 测试（真实下载小文件）
Copy-Item D:\Scoop\aria2-ghost-shim\aria2c.exe D:\Scoop\apps\aria2\current\aria2c.exe -Force
```

## 还原为纯 aria2-next

```powershell
Copy-Item D:\Scoop\apps\aria2\current\aria2c-next.exe D:\Scoop\apps\aria2\current\aria2c.exe -Force
```

还原为官方 aria2：`scoop unhold aria2; scoop update aria2`（会覆盖壳与回退引擎）。

## 注意事项

- aria2 应用处于 hold 状态，日常 `scoop update` 不会覆盖壳；
  但 `scoop uninstall aria2` / 重装会清掉整个目录，需重新部署。
- `aria2c-next.exe` 是快照：`scoop update aria2-next` 升级后如需同步回退引擎，
  重新复制 `apps\aria2-next\current\aria2-next.exe` 过来即可。
- Ghost 的 BT/磁力能力天然可用；metalink 等 Ghost 不支持的协议会经回退链
  由 aria2-next 处理。
- 下载记录：壳完成后会 `ghd remove` 清理任务列表，Ghost 界面里不会堆积
  Scoop 的下载条目；文件保留在 Scoop 缓存目录。