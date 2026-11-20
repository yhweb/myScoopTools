#Requires -Version 5.1
<#
.SYNOPSIS
    scoop-aria2ghost — 管理 Scoop 的 aria2 → Ghost Downloader 下载转译壳
.DESCRIPTION
    status   查看当前引擎 / 回退引擎 / aria2 hold / ghd 探测 / Ghost 代理模式
    deploy   部署壳到 apps\aria2\current\aria2c.exe：
             原引擎备份为 aria2c-next.exe（回退引擎），复制壳母本，hold aria2。幂等。
    restore  把 aria2c-next.exe 还原为 aria2c.exe（不自动 unhold）
.PARAMETER Command
    status | deploy | restore，缺省 status
.NOTES
    myScoopTools 套件成员。Source of truth: E:\code\Ai_tools_plugins\aria2ghost
    壳源码 Aria2GhostShim.cs，设计见 PACKAGING.md。
    路径解析与 scoop core.ps1 / scoop-deepclean 保持一致。
#>
[CmdletBinding()]
param(
    [ValidateSet('status', 'deploy', 'restore')]
    [string]$Command = 'status'
)

$ErrorActionPreference = 'Stop'

function Write-Info($msg)  { Write-Host $msg -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host $msg -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host $msg -ForegroundColor Yellow }
function Write-Err2($msg)  { Write-Host $msg -ForegroundColor Red }

# ---------- 路径解析 ----------
$script:CfgFile = Join-Path $env:USERPROFILE '.config\scoop\config.json'
$script:Cfg = if (Test-Path $script:CfgFile) { try { Get-Content $script:CfgFile -Raw | ConvertFrom-Json } catch { $null } } else { $null }
$script:ScoopRoot = if ($env:SCOOP) { $env:SCOOP }
    elseif ($script:Cfg -and $script:Cfg.rootPath) { $script:Cfg.rootPath }
    elseif ($script:Cfg -and $script:Cfg.root_path) { $script:Cfg.root_path }
    else { Join-Path $env:USERPROFILE 'scoop' }
$script:GlobalRoot = if ($env:SCOOP_GLOBAL) { $env:SCOOP_GLOBAL } else { Join-Path $env:ProgramData 'scoop' }

function Find-Aria2Dir {
    foreach ($root in @($script:ScoopRoot, $script:GlobalRoot)) {
        $d = Join-Path $root 'apps\aria2\current'
        if (Test-Path -LiteralPath (Join-Path $d 'aria2c.exe')) {
            return @{ Dir = $d; Global = ($root -eq $script:GlobalRoot) }
        }
    }
    return $null
}

function Get-EngineInfo([string]$Exe) {
    if (!(Test-Path -LiteralPath $Exe)) { return $null }
    $line = ''
    try { $line = [string](& $Exe --version 2>&1 | Select-Object -First 1) } catch { }
    $kind = 'unknown'
    if ($line -match 'ghost-shim')      { $kind = 'shim' }
    elseif ($line -match 'aria2-next')  { $kind = 'aria2-next' }
    elseif ($line -match '^aria2 version') { $kind = 'aria2' }
    return @{ Kind = $kind; Version = $line.Trim() }
}

function Get-HoldState([string]$AppDir) {
    foreach ($f in 'scoop-install.json', 'install.json') {
        $p = Join-Path $AppDir $f
        if (Test-Path -LiteralPath $p) {
            try { $j = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json; if ($j.hold) { return $true } } catch { }
        }
    }
    return $false
}

function Find-Ghd {
    if ($env:GHD_CLI) { if (Test-Path -LiteralPath $env:GHD_CLI) { return $env:GHD_CLI } else { return $null } }
    foreach ($root in @($script:ScoopRoot, $script:GlobalRoot)) {
        $base = Join-Path $root 'apps\Ghost-Downloader-portable'
        $cur = Join-Path $base 'current\bin\ghd.exe'
        if (Test-Path -LiteralPath $cur) { return $cur }
        if (Test-Path -LiteralPath $base) {
            $vers = Get-ChildItem -LiteralPath $base -Directory | Where-Object { $_.Name -ne 'current' } | Sort-Object Name -Descending
            foreach ($v in $vers) {
                $p = Join-Path $v.FullName 'bin\ghd.exe'
                if (Test-Path -LiteralPath $p) { return $p }
            }
        }
    }
    return $null
}

# ---------- status ----------
function Show-Status {
    $a = Find-Aria2Dir
    if (!$a) {
        Write-Err2 'aria2: not installed (apps\aria2\current\aria2c.exe not found)'
        Write-Info 'Fix: scoop install aria2'
        return
    }
    $scope = if ($a.Global) { 'global' } else { 'user' }
    Write-Info "aria2 [$scope]: $($a.Dir)"

    $eng = Get-EngineInfo (Join-Path $a.Dir 'aria2c.exe')
    $label = switch ($eng.Kind) {
        'shim'       { 'ghost-shim (Ghost Downloader engine)' }
        'aria2-next' { 'aria2-next (original)' }
        'aria2'      { 'official aria2 (original)' }
        default      { 'unknown' }
    }
    Write-Host "  engine     : $label"
    Write-Host "               $($eng.Version)"

    $fb = Get-EngineInfo (Join-Path $a.Dir 'aria2c-next.exe')
    if ($fb) { Write-Host "  fallback   : $($fb.Version)" }
    else { Write-Warn2 '  fallback   : MISSING (aria2c-next.exe) — fallback chain broken' }

    $held = Get-HoldState $a.Dir
    if ($held) { Write-Host '  hold       : yes' }
    else { Write-Warn2 '  hold       : no — "scoop update aria2" will overwrite the shim!' }

    $ghd = Find-Ghd
    if ($ghd) {
        $gv = [string](& $ghd --version 2>&1 | Select-Object -First 1)
        Write-Host "  ghd        : $gv"
        Write-Host "               $ghd"
    } else {
        Write-Warn2 '  ghd        : not found — downloads will use the fallback engine'
    }

    $uc = Join-Path $env:LOCALAPPDATA 'GhostDownloader\UserConfig.json'
    if (Test-Path -LiteralPath $uc) {
        try {
            $j = Get-Content -LiteralPath $uc -Raw | ConvertFrom-Json
            Write-Host "  ghost proxy: $($j.GeneralDownload.ProxyServer) (Ghost's own setting; Scoop --all-proxy is not forwarded)"
        } catch { }
    }
}

# ---------- deploy ----------
function Invoke-Deploy {
    $a = Find-Aria2Dir
    if (!$a) {
        Write-Err2 'aria2 not installed; cannot deploy.'
        Write-Info 'Fix: scoop install aria2, then: scoop-aria2ghost deploy'
        exit 1
    }
    $target = Join-Path $a.Dir 'aria2c.exe'
    $backup = Join-Path $a.Dir 'aria2c-next.exe'
    $master = Join-Path $PSScriptRoot 'aria2c.exe'
    if (!(Test-Path -LiteralPath $master)) {
        Write-Err2 "Shim master missing: $master"
        Write-Info 'Fix: reinstall myScoopTools (pre_install copies the master).'
        exit 1
    }

    $eng = Get-EngineInfo $target
    if ($eng.Kind -ne 'shim') {
        Write-Info "Current engine: $($eng.Version)"
        Write-Info 'Backing it up as aria2c-next.exe (fallback engine)...'
        Copy-Item -LiteralPath $target -Destination $backup -Force
    } else {
        Write-Info 'Current engine is already the shim; refreshing from master.'
        if (!(Test-Path -LiteralPath $backup)) {
            Write-Warn2 'Fallback engine aria2c-next.exe is MISSING.'
            Write-Info 'Fix: copy an aria2/aria2-next binary there, or reinstall aria2 and deploy again.'
        }
    }

    Copy-Item -LiteralPath $master -Destination $target -Force

    $holdArgs = @('hold', 'aria2')
    if ($a.Global) { $holdArgs += '--global' }
    & scoop @holdArgs | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warn2 "scoop hold aria2 failed ($LASTEXITCODE); shim deployed but updates may overwrite it."
    }

    $new = Get-EngineInfo $target
    if ($new.Kind -eq 'shim') { Write-Ok "Deployed: $($new.Version)" }
    else { Write-Err2 "Deploy verification failed: $($new.Version)"; exit 1 }

    Show-Status
}

# ---------- restore ----------
function Invoke-Restore {
    $a = Find-Aria2Dir
    if (!$a) { Write-Warn2 'aria2 not installed; nothing to restore.'; return }
    $target = Join-Path $a.Dir 'aria2c.exe'
    $backup = Join-Path $a.Dir 'aria2c-next.exe'
    if (!(Test-Path -LiteralPath $backup)) {
        Write-Warn2 'No fallback engine backup (aria2c-next.exe); cannot restore.'
        Write-Info 'Fix: scoop unhold aria2; scoop update aria2 --force  (restores official aria2)'
        return
    }
    Copy-Item -LiteralPath $backup -Destination $target -Force
    $eng = Get-EngineInfo $target
    Write-Ok "Restored: $($eng.Version)"
    Write-Info 'aria2 remains held (change with: scoop unhold aria2).'
}

switch ($Command) {
    'status'  { Show-Status }
    'deploy'  { Invoke-Deploy }
    'restore' { Invoke-Restore }
}