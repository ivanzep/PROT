@echo off
rem Double-click launcher for win-monitor.ps1 - no PowerShell prompt needed.
rem
rem Windows opens .ps1 files in Notepad on double-click and blocks running
rem scripts that arrived from elsewhere ("this script is not digitally
rem signed") unless the execution policy is relaxed for the call. Both are
rem worked around here rather than requiring any change to the machine's
rem default policy.
rem
rem Any arguments passed to this .cmd are forwarded to win-monitor.ps1, e.g.:
rem   win-monitor.cmd -IdleThresholdSeconds 120 -DryRun

setlocal
set "HERE=%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Unblock-File -LiteralPath '%HERE%win-monitor.ps1' -ErrorAction SilentlyContinue" >nul 2>&1

powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%win-monitor.ps1" %*

echo.
echo Press any key to close this window...
pause >nul
