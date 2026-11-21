# myScoopTools 打包设计文档 — aria2ghost 并入套件

> v1.3.3（2026-11-21）：scoop-deepclean 的 pnpm store prune 增加 store 存在性预检（避免 exit 38）；release 资产形态不变。
> v1.3.1（2026-11-21）：脚本空环境变量与退出码修复；release 资产形态不变。
> 状态：**已实现（v1.2.0）· 模拟测试通过** · 2026-11-20 设计 / 2026-11-21 修正
> 重要修正：file:// url 方案被模拟测试证伪（aria2 静默跳过仍返回 0），
> 已改为 https 占位 payload，详见 §10。
> 目标命令：`scoop install myScoopTools` 一次装好整套工具并自动生效；
> `scoop uninstall myScoopTools` 自动还原，不留残留。

---

## 1. 目标与用户体验

```powershell
# 首次（本机 bucket 已注册，可直接装）
scoop install myScoopTools
#   → scoop-deepclean 命令可用（现有功能）
#   → aria2ghost 壳自动部署：Scoop 下载改走 Ghost Downloader CLI
#   → aria2 自动 hold，防止更新覆盖

# 日常
scoop-deepclean                # 一键深度清理
scoop-aria2ghost status        # 查看当前下载引擎 / 回退引擎 / hold / ghd 状态
scoop-aria2ghost restore       # 临时还原为原 aria2 引擎
scoop-aria2ghost deploy        # 重新部署壳（aria2 被更新覆盖后修复）

# 迭代（沿用现有 source-of-truth 工作流）
# 改代码 → build.ps1 → test.ps1 → git commit → scoop update myScoopTools --force

# 卸载
scoop uninstall myScoopTools   # 自动还原 aria2c.exe，移除命令
```

## 2. 现状盘点（设计依据）

| 项 | 状态 |
|---|---|
| 本地 bucket `mytools` | 已注册 → `file:///E:/code/Ai_tools_plugins/aria2ghost`，目录即 git 仓库 |
| `myScoopTools.json` | v1.1.0，仅含 scoop-deepclean；**零下载模式**：无 `url`，`pre_install` 从 `bucketdir $bucket`（或本地 json 路径的父目录）直接复制脚本 |
| myScoopTools 应用 | 当前**未安装**（bucket 里有 manifest，apps 下无目录） |
| aria2ghost 壳 | 已手动部署：`apps\aria2\current\aria2c.exe` = 壳 v1.0；`aria2c-next.exe` = aria2-next 3.1.1 快照；aria2 已 hold |
| Ghost Downloader | 4.5.11 portable（dsh bucket），`current\bin\ghd.exe` 可用，代理 Auto（系统代理） |
| Scoop 能力核实 | v0.6.0 支持 `pre_install / post_install / pre_uninstall / post_uninstall`（lib/install.ps1 ValidateSet）；helper 路径硬编码 `apps\aria2\current\aria2c.exe`，不走 shim、不可配置 |

## 3. 总体设计

**沿用 v1.1.0 的本地 bucket 模式**：bucket 目录里直接放编译好的壳 exe 与脚本，
`pre_install` 复制到应用目录，`post_install` 调管理命令完成部署，`pre_uninstall` 完成还原。
注意：Scoop v0.6.0 的 `Get-SupportedArchitecture` 强制要求非空 url，纯零下载不可行；
url 采用 https 占位 payload（内容无关紧要，真实工具全部来自 bucket 复制，见 §4/§10）。

```
E:\code\Ai_tools_plugins\aria2ghost\        (= bucket mytools, git repo)
├── myScoopTools.json          ← v1.2.0（本设计，待实现）
├── scoop-deepclean.ps1/.cmd   ← 现有工具，不动
├── Aria2GhostShim.cs          ← 壳源码
├── build.ps1 / test.ps1       ← 开发工具（不进包）
├── aria2c.exe                 ← 编译产物，提交 git，随包分发（16KB）
├── scoop-aria2ghost.ps1/.cmd  ← 新增管理命令（待实现）
├── README.md / PACKAGING.md
└── aria2c-next.exe            ← 本地测试产物，.gitignore，不进包

scoop install myScoopTools
  pre_install   复制 deepclean 脚本 + aria2c.exe + scoop-aria2ghost 脚本 → apps\myScoopTools\current
  post_install  scoop-aria2ghost deploy：
                  识别 apps\aria2\current\aria2c.exe 当前引擎
                  非壳 → 备份为 aria2c-next.exe（回退引擎）
                  复制壳 → aria2c.exe；scoop hold aria2
  bin           scoop-deepclean / scoop-aria2ghost 两个 shim

scoop uninstall myScoopTools
  pre_uninstall scoop-aria2ghost restore：aria2c-next.exe 复制回 aria2c.exe
```

### 为什么"寄生"在 aria2 应用目录

Scoop 的 `Get-HelperPath -Helper Aria2` 硬编码解析 `apps\aria2\current\aria2c.exe`，
不查 PATH、无配置项。因此壳必须落在这个路径；myScoopTools 自己的应用目录
只存放"母本"（壳 exe + 脚本），部署 = 从母本复制到 aria2 目录。
这也决定了卸载/更新的责任边界（见 §6）。

## 4. Manifest 草案 v1.2.0

```json
{
    "version": "1.2.0",
    "description": "My Scoop Tools - scoop-deepclean: one-click deep cleanup (scoop cleanup * + scoop cache rm * + bun/uv/pnpm cache with per-item confirmation). aria2ghost: route Scoop's aria2 downloads through Ghost Downloader CLI (ghd) with automatic aria2 fallback; manage via scoop-aria2ghost status|deploy|restore.",
    "license": "MIT",
    "depends": "aria2",
    "url": "https://raw.githubusercontent.com/yhweb/scoop-dsh/main/bucket/Ghost-Downloader-portable.json#/scoop-deepclean.ps1",
    "notes": [
        "Commands: scoop-deepclean (-DryRun) / scoop-aria2ghost status|deploy|restore",
        "aria2ghost needs Ghost Downloader (ghd.exe) for the Ghost engine; without it downloads fall back to the bundled aria2 engine automatically.",
        "aria2 is held after install to protect the shim; after 'scoop unhold aria2' + update, run 'scoop-aria2ghost deploy' to repair.",
        "Source of truth: E:\\code\\Ai_tools_plugins\\aria2ghost",
        "After editing: build.ps1 -> test.ps1 -> bump version -> git commit -> git -C D:\\Scoop\\buckets\\mytools pull -> scoop update myScoopTools (quick: -f -k)."
    ],
    "pre_install": [
        "$src = if ($bucket) { bucketdir $bucket } else { Split-Path $url -Parent }",
        "foreach ($f in 'scoop-deepclean.ps1','scoop-deepclean.cmd','scoop-aria2ghost.ps1','scoop-aria2ghost.cmd','aria2c.exe') { if (!(Test-Path \"$src\\$f\")) { abort \"Source missing: $src\\$f\" } }",
        "Copy-Item \"$src\\scoop-deepclean.ps1\",\"$src\\scoop-deepclean.cmd\",\"$src\\scoop-aria2ghost.ps1\",\"$src\\scoop-aria2ghost.cmd\",\"$src\\aria2c.exe\" $dir -Force"
    ],
    "post_install": [
        "& \"$dir\\scoop-aria2ghost.cmd\" deploy"
    ],
    "pre_uninstall": [
        "& \"$dir\\scoop-aria2ghost.cmd\" restore"
    ],
    "bin": [
        "scoop-deepclean.ps1",
        "scoop-aria2ghost.ps1"
    ]
}
```

要点说明：

- **`depends: "aria2"`**：保证 `apps\aria2\current` 存在（全新机器上 Scoop 会先装
  官方 aria2）。本机已装 aria2（hold 中）则直接复用，不重复安装。
  不写 `aria2-next`：Scoop 只认应用名 `aria2`，aria2-next 目录不满足 helper 解析。
- **post_install / pre_uninstall 走 `.cmd` 包装器**：与 deepclean 相同模式，
  由 cmd 包装器以 `-ExecutionPolicy Bypass` 调 ps1，避开执行策略问题；
  cmd 内部优先 pwsh 7、回退 Windows PowerShell。
- **`bin` 用 ps1**：Scoop 对 ps1 自动生成 shim（deepclean 已验证此模式）。
- **url 为 https 占位 payload**：指向 dsh bucket 的 Ghost manifest（1.9KB，用户自有公开仓库），
  `#/scoop-deepclean.ps1` 重命名后由 `pre_install` 用真实脚本覆盖。任何引擎（官方 aria2 /
  aria2-next / 壳 / 内置）都能正常下载 https，彻底规避 file:// 静默失败（§10）。
  不写 hash（payload 内容随 dsh 更新变化，真实文件来自 bucket）；版本手动递增；
  发布 GitHub 后可换成自有仓库 raw 文件并考虑 autoupdate（§9）。
- `pre_uninstall` 在应用目录被删除**之前**执行，`$dir` 内脚本仍可用（已核实
  Scoop v0.6.0 支持该钩子）。

## 5. 管理命令 `scoop-aria2ghost` 规格（待实现）

PowerShell 5.1+ 兼容（与 deepclean 一致），路径解析复用 deepclean 的
ScoopRoot/AppsDir 逻辑（`$env:SCOOP` → 默认用户 scoop；全局安装另探测）。

```
scoop-aria2ghost [status|deploy|restore]   # 缺省 status
```

### 引擎识别（deploy/status 共用）

运行 `apps\aria2\current\aria2c.exe --version` 取首行：

| 首行特征 | 判定 |
|---|---|
| `aria2c ghost-shim …` | 已是壳（幂等：deploy 仅更新母本→目标，不动备份） |
| `aria2-next version …` | aria2-next（本机现状） |
| `aria2 version …` | 官方 aria2 |
| exe 不存在 / aria2 未安装 | 报错并提示 `scoop install aria2` |

### deploy

1. 定位 aria2 current 目录；不存在 → 报错退出（依赖应已保证）。
2. 识别当前引擎；**非壳** → 复制当前 `aria2c.exe` 为 `aria2c-next.exe`
   （覆盖旧快照；这就是回退引擎的来源，官方或 aria2-next 均可）。
3. 已是壳 → 保留现有 `aria2c-next.exe`；若缺失则告警（回退链断档，
   提示可从 `apps\aria2-next` 或官方包补一份）。
4. 复制应用目录里的壳母本 → `aria2c.exe`。
5. `scoop hold aria2`（幂等）。
6. 验证：`aria2c.exe --version` 应输出 ghost-shim；打印 ghd 探测结果与
   回退引擎版本，给出 status 摘要。

### restore

1. `aria2c-next.exe` 存在 → 复制回 `aria2c.exe`，打印还原后的引擎版本。
2. 不存在 → 告警：无备份可还原，建议 `scoop unhold aria2; scoop update aria2 --force`
   由官方包恢复；不做破坏性操作。
3. **不自动 unhold**（hold 是用户选择，restore 只换引擎）。

### status

输出：当前引擎（壳/aria2-next/官方+版本）、回退引擎是否存在及版本、
aria2 hold 状态、ghd.exe 探测路径与版本（`ghd --version`）、
Ghost 代理模式提示（读取 UserConfig.json 的 ProxyServer，只读）。

### 错误处理原则

与 deepclean 一致：`$ErrorActionPreference='Stop'`；所有写操作前打印将要做的事；
失败给出可执行的修复建议；不做任何超出 aria2 目录两个 exe 的修改。

## 6. 关键边界与决策

| 场景 | 行为 / 决策 |
|---|---|
| 全新机器，无 aria2 | `depends` 先装官方 aria2 → deploy 备份官方 exe 为回退引擎 → 换壳 |
| 本机现状（aria2=aria2-next 掉包 + hold） | deploy 识别为 aria2-next，备份快照后换壳；与现有手动部署完全兼容 |
| 重复 install / update --force | deploy 幂等：已是壳则只刷新母本，不重复备份、不丢回退引擎 |
| `scoop update aria2`（hold 中） | 被 hold 跳过，壳安全 |
| 用户 unhold 后 update aria2 | 官方 exe 覆盖壳与快照 → `scoop-aria2ghost deploy` 修复（notes 已提示） |
| `scoop uninstall aria2` | 整个 aria2 目录被删，壳与备份随之消失；myScoopTools 仍在但引擎失效。status 会报"aria2 未安装"；重装 aria2 后 deploy 修复。**不拦截、不代管 aria2 的生命周期** |
| Ghost 未安装 / ghd 找不到 | 壳自动走回退引擎（aria2 系），功能不中断；status 明确提示。不做硬依赖（GUI 应用体积大、且在 dsh bucket，强制依赖侵入性太强） |
| Ghost 升级 | 壳按 `current\bin\ghd.exe` 动态解析，无需改动 |
| aria2-next 升级 | 回退引擎是快照，不自动跟进；可选：deploy 时若检测到 `apps\aria2-next` 且版本更新，提示用户是否刷新快照（默认不动，保持简单） |
| 代理 | 跟随 Ghost 自身设置（Auto=系统代理）；Scoop `--all-proxy` 不透传。README/notes 均已说明 |
| 卸载 myScoopTools | pre_uninstall 还原引擎 → 删应用目录与 shims；aria2 保持 hold（用户可自行 unhold） |
| 壳 exe 是否提交 git | **是**（16KB，零下载模式的分发物）；`aria2c-next.exe`（18MB 测试产物）**否**，加 .gitignore |

## 7. 实施清单（下一步，按序）

1. `.gitignore`：`aria2c-next.exe`（及 `*.user` 等杂项）。
2. 编写 `scoop-aria2ghost.ps1`（§5 规格）+ `.cmd` 包装器（复制 deepclean 模式）。
3. `myScoopTools.json` 升级 v1.2.0（§4 草案）。
4. 本机验收（§8）；git commit。
5. 更新 README：手动部署章节标记为"打包后自动完成"。

## 8. 验收清单（2026-11-21 全部通过，另含 §10 故障注入）

- [x] `scoop install myScoopTools`：deepclean 与 scoop-aria2ghost 两个命令可用；
      aria2c.exe 变为壳、aria2c-next.exe 备份正确、aria2 hold。
- [x] `scoop download jq`（先 `scoop cache rm jq`）：走 Ghost 引擎、进度可见、hash OK。
- [x] 停掉 Ghost/改 `GHD_CLI` 指向不存在路径再 download：自动回退 aria2 系引擎成功。
- [x] `scoop-aria2ghost status`：引擎/备份/hold/ghd 四项信息准确。
- [x] `scoop-aria2ghost restore` → download 走原引擎；`deploy` → 恢复壳。
- [x] `scoop update myScoopTools --force`：幂等，备份不丢、命令仍可用。
- [x] `scoop uninstall myScoopTools`：aria2c.exe 还原为备份引擎，shims 清除，
      deepclean 命令消失；aria2 本体不受影响。
- [x] 卸载后 `scoop install myScoopTools` 可再次完整装回（往返测试）。
- [x] `scoop install jq` 全新安装：Ghost 引擎下载 + hash OK + shim 生成 + 命令可运行，
      Ghost 日志可见分片直写 Scoop 缓存文件。
- [x] `scoop-deepclean -DryRun`：shim 识别正常，正确枚举缓存与开发工具缓存，零删除。

## 9. 路线图

- **Phase 1（本设计）**：本地 bucket，个人使用，零下载模式。
- **Phase 2（可选）**：仓库推 GitHub（如 `yhweb/scoop-mytools`），他人
  `scoop bucket add mytools https://github.com/<user>/scoop-mytools` 后同样
  `scoop install myScoopTools`。壳 exe 随仓库分发；如需规范可改为
  GitHub Release zip + url/hash/autoupdate，manifest 结构不变。
- **Phase 3（可选）**：工具增多后拆分为独立 app（`aria2ghost.json`、
  `scoop-deepclean.json`…），`myScoopTools` 变为 meta 包（仅 depends），
  保持"一条命令装全套"的体验。当前两个工具规模下不拆，避免过度设计。

## 10. 模拟测试发现的坑与修正（2026-11-21）

### 坑：file:// url 在所有 aria2 引擎下静默失败

v1.1.0 用 `url: file:///…ps1` 满足架构校验，预期"aria2 失败 → Scoop 回退内置下载器完成本地复制"。
模拟测试（卸载→重装往返）证伪了这个预期：

```
官方 aria2 1.37.0 实测：
  [ERROR] Unrecognized URI or unsupported protocol: file:///E:/…/scoop-deepclean.ps1
  No files to download.
  EXIT=0   ← 关键：跳过条目后仍返回 0
aria2-next 3.1.1 实测：
  [error] Input file entry skipped: Invalid Metalink document: syntax error
  EXIT=0
```

Scoop 只在 aria2 **非 0 退出**时才回退内置下载器；退出码 0 + 缓存文件缺失 →
`Get-FileHash` 对不存在的文件取值 → 安装崩溃。此前"能装"只是因为缓存里恰好有旧文件
（hash 校验读的是缓存路径）或隔离环境根本没装 aria2。**干净环境首装必崩。**

### 修正：https 占位 payload

- `url` 改为 `https://raw.githubusercontent.com/yhweb/scoop-dsh/main/bucket/Ghost-Downloader-portable.json#/scoop-deepclean.ps1`
  （用户自有公开 dsh bucket 中的小文件，1.9KB，已验证在 origin/main 且可下载）。
- payload 内容无关紧要：`#/` 重命名为 scoop-deepclean.ps1 落到应用目录后，
  `pre_install` 立即用 bucket 里的真实脚本覆盖；其余工具文件同样来自 bucket 复制。
- https 是全部引擎（官方 aria2 / aria2-next / ghost-shim / 内置 .NET）都支持的协议，
  首装、更新、卸载后重装在任何引擎状态下都可靠。
- 壳的 file:// 本地复制能力保留（对其他本地 manifest 仍有用，test.ps1 TEST 3 覆盖）。
- 代价：安装需联网（Scoop 本就依赖网络更新 bucket）；payload 随 dsh 仓库该文件存在而稳定，
  若日后调整 dsh 结构需同步换 url；发布本仓库到 GitHub 后应换成自有 raw 文件（Phase 2）。

### 模拟测试矩阵（修正后，全部通过）

| # | 场景 | 引擎状态 | 结果 |
|---|---|---|---|
| 1 | 首装 myScoopTools | aria2-next，无壳（最严苛） | https payload 由 aria2-next 下载，post_install 部署壳 ✓ |
| 2 | scoop install jq（全新） | ghost-shim | Ghost 引擎下载，hash OK，shim 生成，jq 可运行；Ghost 日志见分片直写缓存 ✓ |
| 3 | GHD_CLI 指向不存在路径 + download | ghost-shim | 自动回退 aria2-next，hash OK ✓ |
| 4 | scoop-deepclean -DryRun | — | shim 识别正常，枚举准确，零删除 ✓ |
| 5 | restore / deploy 往返 | — | 引擎正确切换，备份不丢 ✓ |
| 6 | update -f -k | ghost-shim | 幂等 ✓ |
| 7 | uninstall → install 往返 | 还原 aria2-next 后重装 | 修复前崩溃的场景，修复后通过 ✓ |