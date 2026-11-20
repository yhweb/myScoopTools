@echo off
rem scoop-aria2ghost wrapper: prefer pwsh 7, fallback to Windows PowerShell
where pwsh >nul 2>nul
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0scoop-aria2ghost.ps1" %*
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scoop-aria2ghost.ps1" %*
)