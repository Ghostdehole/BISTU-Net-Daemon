@echo off
setlocal DisableDelayedExpansion
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-from-windows.ps1"
set "bistu_result=%ERRORLEVEL%"
pause
exit /b %bistu_result%
