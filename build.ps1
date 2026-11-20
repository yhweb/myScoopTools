# Build the aria2 -> Ghost Downloader shim.
# Usage:  pwsh -File build.ps1            (compile only)
# Output: aria2c.exe in this folder. Deploy manually or see README.md.
$ErrorActionPreference = 'Stop'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { throw "csc.exe not found: $csc" }
$src = Join-Path $PSScriptRoot 'Aria2GhostShim.cs'
$out = Join-Path $PSScriptRoot 'aria2c.exe'
& $csc /nologo /target:exe /optimize+ /r:System.Web.Extensions.dll "/out:$out" $src
if ($LASTEXITCODE -ne 0) { throw "compile failed ($LASTEXITCODE)" }
Write-Host "built: $out"