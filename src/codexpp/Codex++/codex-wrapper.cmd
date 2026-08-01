@echo off
setlocal
set ELECTRON_DEFAULT_LOCALE=zh-CN
set LANG=zh-CN
pwsh.exe -NoLogo -NoProfile -File "C:\Users\ma dao\.headroom\codexpp-headroom\ensure-headroom.ps1"
if errorlevel 1 exit /b 1
start "" "D:\program\Codex++\codex-plus-plus.exe" %*
exit /b %ERRORLEVEL%
