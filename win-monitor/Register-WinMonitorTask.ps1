<#
.SYNOPSIS
    Registers (or removes) a Scheduled Task that starts win-monitor at logon,
    with no console window.

.DESCRIPTION
    This is how the prototype "runs in the background": a per-user Scheduled Task
    triggered at logon, running in the interactive session.

    The interactive part is not optional. A task configured to "run whether the
    user is logged on or not" executes in session 0, where there is no desktop and
    GetForegroundWindow always returns nothing - the log would be empty. So the
    task is registered with an Interactive logon type, at normal (non-elevated)
    privilege, which also means no admin rights are needed to install it.

.PARAMETER TaskName
    Name under which the task is registered. Default: win-monitor.

.PARAMETER IdleThresholdSeconds
    Passed through to win-monitor.ps1. Default 300.

.PARAMETER LogDirectory
    Passed through to win-monitor.ps1. Defaults to the script's own default.

.PARAMETER StartNow
    Also start the task immediately instead of waiting for the next logon.

.PARAMETER Unregister
    Remove the task instead of creating it.

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

$monitorPath = Join-Path $PSScriptRoot 'win-monitor.ps1'
if (-not (Test-Path -LiteralPath $monitorPath)) {
    throw "win-monitor.ps1 not found next to this script (looked in $PSScriptRoot)."
}

$arguments = @(
    '-NoProfile'
    '-WindowStyle Hidden'
    '-ExecutionPolicy Bypass'
    '-File "{0}"' -f $monitorPath
    '-IdleThresholdSeconds {0}' -f $IdleThresholdSeconds
    '-Quiet'
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
    -Description 'Logs the active window, its open file, and idle periods to a local file.' `
    -Force | Out-Null

Write-Host "Registered scheduled task '$TaskName' (starts at logon, runs hidden)."

if ($StartNow) {
    Start-ScheduledTask -TaskName $TaskName
    Write-Host 'Started it now as well.'
}

Write-Host ''
Write-Host ('Check it:   Get-ScheduledTask -TaskName ''{0}''' -f $TaskName)
Write-Host ('Stop it:    Stop-ScheduledTask -TaskName ''{0}''' -f $TaskName)
Write-Host 'Remove it:  .\Register-WinMonitorTask.ps1 -Unregister'
