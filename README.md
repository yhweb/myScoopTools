# aria2ghost — aria2 → Ghost Downloader 转译壳（Scoop 专用）

让 Scoop 内部下载（原本调用 aria2c.exe）改走 **Ghost Downloader 的官方 CLI `ghd.exe`**。
Scoop 无需任何改动；对 Scoop 来说它仍然是一个"aria2c.exe"。

本目录是 **source of truth**，同时注册为本地 bucket `mytools`，
是 `myScoopTools` 工具套件（scoop-deepclean + aria2ghost）的源码仓库。
打包设计与实现记录见 **[PACKAGING.md](PACKAGING.md)**（v1.2.0 已实现，模拟测试通过）。

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
            └─ 任一失败 → 自动回退 aria2c-next.exe（真 aria2 系二进制，仅重试失败条目）
                 └─ 仍失败 → 非 0 退出，Scoop 再回退内置 .NET 下载器
```

- 首次调用会自动在后台拉起 Ghost Downloader 主程序（ghd 的官方行为）。
- 代理跟随 Ghost Downloader 自身设置（当前为 Auto = 系统代理）；
  Scoop 的 `--all-proxy` 不会透传（ghd 无逐任务代理参数）。
- `--split` 等 aria2 调优参数被忽略，线程数由 Ghost 自己管理；
  `--user-agent`、`--header`（Cookie）、referer 会透传给 ghd。
- Scoop URL 尾部的 `#/文件名` 重命名语法会被剥掉后再交给 ghd。
- `ghd add` 瞬时失败自动重试一次（3 秒间隔）。
- `--stop-with-process`：Scoop 进程消失时壳自动退出（码 7）；
  Ghost 任务会继续下完并落入 Scoop 缓存，无害（下次安装直接命中缓存）。

## 文件布局

| 位置 | 内容 |
|---|---|
| `E:\code\Ai_tools_plugins\aria2ghost\Aria2GhostShim.cs` | 壳源码（C#，仅依赖 .NET Framework 4.x） |
| `E:\code\Ai_tools_plugins\aria2ghost\build.ps1` | 编译脚本（系统自带 csc） |
| `E:\code\Ai_tools_plugins\aria2ghost\test.ps1` | 三路径测试：Ghost 引擎 + aria2 回退 + file:// 本地复制 |
| `E:\code\Ai_tools_plugins\aria2ghost\aria2c.exe` | 编译产物（随 bucket 分发，需提交 git） |
| `E:\code\Ai_tools_plugins\aria2ghost\myScoopTools.json` | 套件 manifest（v1.2.0：deepclean + aria2ghost） |
| `E:\code\Ai_tools_plugins\aria2ghost\scoop-deepclean.ps1/.cmd` | 套件现有工具：一键深度清理 |
| `E:\code\Ai_tools_plugins\aria2ghost\scoop-aria2ghost.ps1/.cmd` | 下载引擎管理命令（status/deploy/restore） |
| `D:\Scoop\apps\aria2\current\aria2c.exe` | 已部署的壳 |
| `D:\Scoop\apps\aria2\current\aria2c-next.exe` | 回退引擎快照（当前为 aria2-next 3.1.1） |

ghd.exe 定位顺序：环境变量 `GHD_CLI` → `apps\Ghost-Downloader-portable\current\bin\ghd.exe`
（按壳自身位置推导）→ 最新版本目录。Ghost 升级后无需改壳。

## 构建 / 测试 / 手动部署

```powershell
pwsh -File E:\code\Ai_tools_plugins\aria2ghost\build.ps1   # 编译
pwsh -File E:\code\Ai_tools_plugins\aria2ghost\test.ps1    # 测试（真实下载小文件）
Copy-Item E:\code\Ai_tools_plugins\aria2ghost\aria2c.exe D:\Scoop\apps\aria2\current\aria2c.exe -Force
```

以上手动步骤已由 `scoop install/update myScoopTools` 自动完成（v1.2.0）；手动命令保留供开发调试。

## 还原为纯 aria2-next

```powershell
scoop-aria2ghost restore     # 推荐：还原引擎（保留备份）；deploy 重新部署壳
scoop-aria2ghost status      # 查看引擎/回退/hold/ghd 状态
# 或手动：
Copy-Item D:\Scoop\apps\aria2\current\aria2c-next.exe D:\Scoop\apps\aria2\current\aria2c.exe -Force
```

还原为官方 aria2：`scoop unhold aria2; scoop update aria2`（会覆盖壳与回退引擎）。

## 注意事项

- aria2 应用处于 hold 状态，日常 `scoop update` 不会覆盖壳；
  但 `scoop uninstall aria2` / 重装会清掉整个目录，需重新部署。
- `aria2c-next.exe` 是快照：`scoop update aria2-next` 升级后如需同步回退引擎，
  重新复制 `apps\aria2-next\current\aria2-next.exe` 过来即可。
- Ghost 的 BT/磁力能力天然可用；metalink 等 Ghost 不支持的协议会经回退链
  由 aria2 系引擎处理。
- 下载记录：壳完成后会 `ghd remove` 清理任务列表，Ghost 界面里不会堆积
  Scoop 的下载条目；文件保留在 Scoop 缓存目录。

---

# scoop-deepclean — scoop 一键深度清理工具

> 本仓库同时是本地 scoop bucket `mytools` 的源，工具以 `myScoopTools` 之名可被 scoop 安装。
> 上半部分是 aria2→Ghost 转译壳的文档，本部分描述清理工具。

## 功能说明

一条命令完成三层清理，逻辑直接复制自 scoop 官方脚本（`libexec/scoop-cleanup.ps1`、`libexec/scoop-cache.ps1`），并增强占用处理：

| 阶段 | 内容 | 交互 |
|---|---|---|
| 1/3 | `scoop cleanup *`：删除所有应用的旧版本目录 | 自动；遇文件占用时询问 |
| 2/3 | `scoop cache rm *`：清空下载缓存（含 `.txt` url 记录） | 自动；遇文件占用时询问 |
| 3/3 | `bun pm cache rm` → `uv cache clean` → `pnpm store prune` | **逐项确认：回车=执行 / s=跳过 / q=结束后续** |

### 占用处理（阶段 1/2）

删除失败时，用 **Windows Restart Manager**（系统"文件正在使用"对话框同款 API）+ exe 路径扫描定位占用进程，列出 PID / 名称 / 路径后询问：

```
是否结束上述进程并重试删除? [y/N]
```

- **默认 N**（直接回车=不结束、跳过该项），输入 y 才结束进程并重试，最多 3 次
- 能识别三类占用：exe 在旧版本目录内运行、加载了目录内 DLL、独占打开目录内文件（含工作目录占用）
- 无法定位时跳过并提示用资源监视器排查，不会盲杀

### uv 缓存锁特判（阶段 3）

`uv run` / `uvx` 等长驻进程会持有 uv 缓存锁，直接 `uv cache clean` 会无限等待
（`Cache is currently in-use, waiting for other uv processes to finish`）。
脚本检测到运行中的 uv 进程时，列出其 PID 与完整命令行，并给出三选一：

```
s=跳过(默认，直接回车) / f=强制清理(--force，可能影响运行中的 uv 任务) / w=等待执行(阻塞到进程退出)
```

开发服务（如 uvicorn）在跑时直接回车跳过即可，停掉服务后再清。

### 预览模式

```powershell
scoop-deepclean -DryRun   # 只统计将清理的内容与体积，不删除、不询问、不执行
```

## 安全设计

- **当前版本判定**与官方一致：读 `current\scoop-manifest.json`（nightly 取 junction 目标），回退 `install.json` 时间排序；无法确定当前版本的应用**整个跳过**，绝不误删在用版本
- **删除前先解除 persist 链接**（官方 `unlink_persist_data` 逻辑），用户数据目录不受影响
- 体积统计不跟随 junction，避免把 persist 数据算进"可释放"
- 结束进程默认 N；只针对占用目标目录的进程，不碰其他进程
- 脚本兼容 Windows PowerShell 5.1 与 pwsh 7（推荐 pwsh 7，junction 删除行为更安全）

## 文件清单

| 文件 | 作用 |
|---|---|
| `scoop-deepclean.ps1` | 主脚本（唯一事实来源） |
| `scoop-deepclean.cmd` | 手动部署用的 cmd 包装器（scoop 安装后由官方 shim 取代，可不用） |
| `myScoopTools.json` | scoop manifest（本地 bucket `mytools` 的根 manifest） |

## 作为 scoop 应用安装（myScoopTools）

本地 bucket 已注册：`mytools` → `file:///E:/code/Ai_tools_plugins/aria2ghost`（git 仓库）。

```powershell
scoop install myScoopTools     # 按名称安装：scoop-deepclean + scoop-aria2ghost 命令，自动部署下载壳
scoop uninstall myScoopTools   # 卸载：自动还原原 aria2 引擎
scoop-aria2ghost status        # 查看下载引擎/回退/hold/ghd 状态
scoop-aria2ghost restore       # 临时还原原引擎；deploy 重新部署壳
```

**从手动 shim 切换到 scoop 管理**（已完成切换，D:\Scoop\shims 里现为官方 shim）：

```powershell
Remove-Item D:\Scoop\shims\scoop-deepclean.ps1, D:\Scoop\shims\scoop-deepclean.cmd
scoop install myScoopTools
```

### manifest 工作原理

- `url` 是 https 占位 payload（dsh bucket 的 Ghost manifest，`#/` 重命名为 scoop-deepclean.ps1）：
  满足 scoop 的架构校验（必须有 url）。**原 file:/// 方案已废弃**——实测官方 aria2 与 aria2-next
  都会"跳过不支持的协议且返回退出码 0"，Scoop 回退不触发，空缓存的干净首装必崩（PACKAGING.md §10）。
  payload 内容无关紧要，`pre_install` 会用 bucket 里的真实脚本覆盖
- 未写 hash（开发期脚本频繁变动，payload 也随 dsh 更新变化）；scoop 会提示实际 SHA256
- `pre_install` 从 bucket 复制全部工具文件；`bin` 为两个命令生成官方 shim（pwsh 优先、powershell 兜底）
- `post_install` 自动部署 aria2ghost 下载壳并 hold aria2；`pre_uninstall` 自动还原原引擎

### 更新流程

```powershell
# 1. 编辑 scoop-deepclean.ps1，bump myScoopTools.json 的 version
# 2. 提交并同步 bucket 克隆
git -C E:\code\Ai_tools_plugins\aria2ghost add -A
git -C E:\code\Ai_tools_plugins\aria2ghost commit -m "update"
git -C D:\Scoop\buckets\mytools pull        # 或 scoop update（会更新全部 bucket）
# 3. 更新应用
scoop update myScoopTools
# 不 bump 版本的快速刷新（强制+忽略缓存）：
scoop update myScoopTools -f -k
```

### 以后发布到 GitHub

把仓库推到 GitHub 后，将 manifest 的 `url` 换成 release 资产或 archive 地址并补 hash，
即可在任意机器 `scoop bucket add mytools <github-url>` + `scoop install myScoopTools`。

## 验证记录

| 轮次 | 内容 | 结果 |
|---|---|---|
| 1 | 语法解析 + DryRun 预览 | 通过：正确枚举旧版本/缓存，零删除 |
| 2 | 真实独占锁：答 N / 答 Y / 路径已消失 | 通过：N 跳过保进程；Y 定位→结束→删除成功；幂等 |
| 3 | cmd 完整真实运行 | 通过：释放 205.3MB，逐项确认正确 |
| 4 | pwsh 重跑（幂等）+ q 退出 | 通过：已干净、当前版本完好 |
| 5 | uv 锁检测真实环境实测 | 通过：列出 2 个 uv run 进程，默认跳过不再卡死 |
| 6 | 隔离 SCOOP 根目录：bucket 注册→按名安装→shim 运行→卸载 | 通过：全流程正常，不污染真实环境 |

## aria2ghost 合并模拟测试记录（v1.2.0，2026-11-21）

| 轮次 | 内容 | 结果 |
|---|---|---|
| 1 | 最严苛首装：无壳 + aria2-next 引擎下 `scoop install myScoopTools` | https payload 由 aria2-next 正常下载，post_install 自动备份+部署壳+hold ✓ |
| 2 | `scoop install jq` 全新安装（卸载+清缓存后） | `[ghost-shim] engine: Ghost Downloader CLI`，进度可见，hash OK，jq 可运行；Ghost 日志见分片直写 `D:\Scoop\cache\jq#…exe` ✓ |
| 3 | `scoop-deepclean -DryRun` | shim 识别正常（`D:\Scoop\shims\`），正确枚举缓存与开发工具缓存，零删除 ✓ |
| 4 | 卸载→重装往返 | pre_uninstall 还原 aria2-next；重装成功并重新部署壳（修复 file:// 坑后通过）✓ |
| 5 | 回退 / restore / deploy / update -f -k | 全部通过（详见 PACKAGING.md §8/§10）✓ |

关键修正：file:// url 在所有 aria2 引擎下"跳过且返回 0"，Scoop 回退不触发导致干净首装崩溃；
已改为 https 占位 payload（PACKAGING.md §10 有完整实测证据与测试矩阵）。