# Simulates Scoop's exact aria2 invocation against the shim.
# TEST 1: normal path  -> Ghost Downloader engine
# TEST 2: ghd missing  -> automatic fallback to aria2c-next.exe
$ErrorActionPreference = 'Stop'
$shim = Join-Path $PSScriptRoot 'aria2c.exe'
$ghd  = 'D:\Scoop\apps\Ghost-Downloader-portable\current\bin\ghd.exe'
$td   = Join-Path $env:TEMP 'ghd-shim-test2'
New-Item -ItemType Directory -Force -Path $td | Out-Null

$url = 'https://raw.githubusercontent.com/ScoopInstaller/Main/master/bucket/7zip.json'
$outName = 'testapp#1.0#https___raw.githubusercontent.com_ScoopInstaller_Main_master_bucket_7zip.json'
$inputFile = Join-Path $td 'testapp.txt'
@"
$url
    referer=https://raw.githubusercontent.com/ScoopInstaller/Main/master/bucket/
    dir=$td
    out=$outName
"@ | Set-Content -LiteralPath $inputFile -Encoding utf8NoBOM

$scoopArgs = @(
    "--input-file=$inputFile"
    "--user-agent=Scoop/1.0 (+http://scoop.sh) PowerShell/7.6"
    '--allow-overwrite=true'
    '--auto-file-renaming=false'
    '--retry-wait=3'
    '--split=16'
    '--max-connection-per-server=16'
    '--min-split-size=1M'
    '--console-log-level=warn'
    '--enable-color=false'
    '--no-conf=true'
    '--follow-metalink=true'
    '--metalink-preferred-protocol=https'
    '--min-tls-version=TLSv1.2'
    "--stop-with-process=$PID"
    '--continue'
    '--summary-interval=0'
    '--auto-save-interval=1'
    '--all-proxy=127.0.0.1:7897'
)
$f = Join-Path $td $outName

'=== TEST 1: Ghost engine ==='
$env:GHD_CLI = $ghd
if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
& $shim @scoopArgs
"exit=$LASTEXITCODE"
if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $f)) {
    "PASS: file exists, $((Get-Item -LiteralPath $f).Length) bytes"
} else { 'FAIL'; exit 1 }
Remove-Item -LiteralPath $f -Force

'=== TEST 2: fallback to aria2-next ==='
Copy-Item -LiteralPath 'D:\Scoop\apps\aria2-next\current\aria2-next.exe' `
    -Destination (Join-Path $PSScriptRoot 'aria2c-next.exe') -Force
$env:GHD_CLI = 'C:\nonexistent\ghd.exe'
& $shim @scoopArgs
"exit=$LASTEXITCODE"
if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $f)) {
    "PASS: fallback downloaded, $((Get-Item -LiteralPath $f).Length) bytes"
} else { 'FAIL'; exit 1 }

'ALL TESTS PASSED'