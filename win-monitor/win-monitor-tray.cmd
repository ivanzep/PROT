@echo off
rem Double-click launcher for win-monitor-tray.ps1 - starts the tray icon and
rem the hidden logger behind it with no PowerShell prompt, no "this script is
rem not digitally signed" interruption, and no lingering console window.
rem
rem Unlike win-monitor.cmd (which runs the plain logger in the foreground so
rem you can watch it), this one launches detached and returns immediately -
rem the tray icon is the UI from here on, so there is nothing for a console
rem window to usefully stay open for.
rem
rem Any arguments passed to this .cmd are forwarded to win-monitor-tray.ps1, e.g.:
rem   win-monitor-tray.cmd -IdleThresholdSeconds 120

setlocal
set "HERE=%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Unblock-File -LiteralPath '%HERE%win-monitor-tray.ps1' -ErrorAction SilentlyContinue; Unblock-File -LiteralPath '%HERE%win-monitor.ps1' -ErrorAction SilentlyContinue" >nul 2>&1

start "" powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%HERE%win-monitor-tray.ps1" %*
