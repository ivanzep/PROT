<#
.SYNOPSIS
    Registers (or removes) a Scheduled Task that starts the win-monitor tray
    icon at logon, with no console window.

.DESCRIPTION
    This is how the prototype "runs in the background": a per-user Scheduled Task
    triggered at logon, running in the interactive session, launching
    win-monitor-tray.ps1 - which in turn starts win-monitor.ps1 itself as a
    hidden child process and shows a system tray icon over it (right-click for
    the log folder, the log viewer, or Exit). The task's action is the tray
    script, not the logger directly, so there's always a visible, clickable way
    to stop logging without going through Task Manager.

    The interactive part is not optional. A task configured to "run whether the
    user is logged on or not" executes in session 0, where there is no desktop and
    GetForegroundWindow always returns nothing - the log would be empty. So the
    task is registered with an Interactive logon type, at normal (non-elevated)
    privilege, which also means no admin rights are needed to install it.

.PARAMETER TaskName
    Name under which the task is registered. Default: win-monitor.

.PARAMETER IdleThresholdSeconds
    Passed through to win-monitor-tray.ps1 as the starting idle threshold - but
    only until it's changed from the tray icon's own menu, after which the
    saved choice in tray-settings.json takes over on every future logon and
    this parameter is ignored. Default 300.

.PARAMETER LogDirectory
    Passed through to win-monitor-tray.ps1, which passes it on to win-monitor.ps1.
    Defaults to the scripts' own default.

.PARAMETER StartNow
    Also start the task immediately instead of waiting for the next logon.

.PARAMETER Unregister
    Remove the task instead of creating it. Only removes the scheduled task
    itself - if the tray icon is currently running, use its Exit menu item (or
    Stop-ScheduledTask, which force-kills it without flushing the in-progress
    session) to stop that instance.

.EXAMPLE
    .\Register-WinMonitorTask.ps1 -StartNow

.EXAMPLE
    .\Register-WinMonitorTask.ps1 -Unregister
#>

[CmdletBinding()]
param(
    [string] $TaskName = 'win-monitor',
    [int]    $IdleThresholdSeconds = 300,
    [string] $LogDirectory = '',
    [switch] $StartNow,
    [switch] $Unregister
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Unregister) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed scheduled task '$TaskName'. Existing logs are untouched."
    } else {
        Write-Host "No scheduled task named '$TaskName'."
    }
    return
}

$trayPath = Join-Path $PSScriptRoot 'win-monitor-tray.ps1'
if (-not (Test-Path -LiteralPath $trayPath)) {
    throw "win-monitor-tray.ps1 not found next to this script (looked in $PSScriptRoot)."
}

$arguments = @(
    '-NoProfile'
    '-WindowStyle Hidden'
    '-ExecutionPolicy Bypass'
    '-File "{0}"' -f $trayPath
    '-IdleThresholdSeconds {0}' -f $IdleThresholdSeconds
)
if ($LogDirectory) { $arguments += '-LogDirectory "{0}"' -f $LogDirectory }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ($arguments -join ' ')
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

# Interactive + Limited: runs on the user's desktop, needs no admin rights.
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

# The default settings stop a task after 3 days and refuse to start it on
# battery, neither of which suits something meant to just keep running.
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description 'Tray icon for win-monitor: logs the active window, its open file, and idle periods to a local file.' `
    -Force | Out-Null

Write-Host "Registered scheduled task '$TaskName' (starts at logon, tray icon only - no console window)."

if ($StartNow) {
    Start-ScheduledTask -TaskName $TaskName
    Write-Host 'Started it now as well - look for the tray icon.'
}

Write-Host ''
Write-Host ('Check it:   Get-ScheduledTask -TaskName ''{0}''' -f $TaskName)
Write-Host 'Stop it:    right-click the tray icon and choose Exit (flushes the session in progress)'
Write-Host ('            or Stop-ScheduledTask -TaskName ''{0}'' (force-kills it, nothing flushed)' -f $TaskName)
Write-Host 'Remove it:  .\Register-WinMonitorTask.ps1 -Unregister'
