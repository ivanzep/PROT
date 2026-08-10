<#
.SYNOPSIS
    Runs win-monitor.ps1 as a hidden background process with a system tray icon,
    so there is no console window to keep open and a visible way to stop it.

.DESCRIPTION
    win-monitor.ps1 on its own is a console app: closing its window kills it, and
    running it fully headless (as the old Scheduled Task setup did, with
    -WindowStyle Hidden and no window at all) leaves no visible sign it's running
    and no UI to stop it short of Task Manager.

    This script is the middle ground. It launches win-monitor.ps1 as a separate,
    hidden child process - the logger itself is completely unchanged and still
    runs standalone if you want it to - and shows a tray icon with a right-click
    menu (open the log folder, open the log viewer, exit) so it's both invisible
    day-to-day and reachable when you need it.

    Stopping is graceful: "Exit" drops a stop-flag file that win-monitor.ps1
    checks once per poll (see its -StopFlagPath parameter) and exits on, the
    same way Ctrl+C does in a console - the session in progress is flushed, not
    dropped. There is no console here to send Ctrl+C to, which is why the
    logger needed that flag in the first place.

.PARAMETER LogDirectory
    Passed through to win-monitor.ps1. Default: %LOCALAPPDATA%\win-monitor.

.PARAMETER IdleThresholdSeconds
    Passed through to win-monitor.ps1. Default 300.

.EXAMPLE
    .\win-monitor-tray.ps1
    Start the tray icon (and the hidden logger behind it) with defaults.

.EXAMPLE
    powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File .\win-monitor-tray.ps1
    How Register-WinMonitorTask.ps1 launches this at logon - no window at all,
    just the tray icon.

.NOTES
    Windows only. PowerShell 5.1 (in-box) or PowerShell 7+.
    Requires no admin rights and no installed modules - System.Windows.Forms and
    System.Drawing ship with Windows.
#>

[CmdletBinding()]
param(
    [string] $LogDirectory = (Join-Path $env:LOCALAPPDATA 'win-monitor'),
    [ValidateRange(5, 86400)]
    [int]    $IdleThresholdSeconds = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('WinMonitor.Tray.NativeIcon' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace WinMonitor.Tray {
    public static class NativeIcon {
        // Bitmap.GetHicon() hands back an HICON the caller owns; .NET's Icon
        // wrapper does not destroy it for you, so a long-running tray app that
        // never calls this leaks one GDI handle per icon it ever creates.
        [DllImport("user32.dll")]
        public static extern bool DestroyIcon(IntPtr handle);
    }
}
'@
}

$monitorPath = Join-Path $PSScriptRoot 'win-monitor.ps1'
$viewerPath = Join-Path $PSScriptRoot 'index.html'
$stopFlagPath = Join-Path $LogDirectory '.stop-requested'

if (-not (Test-Path -LiteralPath $monitorPath)) {
    [System.Windows.Forms.MessageBox]::Show(
        "win-monitor.ps1 not found next to this script (looked in $PSScriptRoot).",
        'win-monitor', 'OK', 'Error') | Out-Null
    exit 1
}

New-Item -ItemType Directory -Path $LogDirectory -Force -ErrorAction SilentlyContinue | Out-Null
# A stop flag left over from an unclean previous exit (crash, log off) would
# otherwise make the logger we're about to start immediately exit on its
# first poll.
Remove-Item -LiteralPath $stopFlagPath -Force -ErrorAction SilentlyContinue

# --------------------------------------------------------------------------
# Launch the logger as its own hidden, independent process. Built as one
# pre-quoted command-line string (matching Register-WinMonitorTask.ps1)
# rather than an -ArgumentList array, since Start-Process's array handling
# does not quote embedded spaces consistently between Windows PowerShell 5.1
# and PowerShell 7.
# --------------------------------------------------------------------------

$monitorArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -LogDirectory "{1}" -IdleThresholdSeconds {2} -StopFlagPath "{3}" -Quiet' `
    -f $monitorPath, $LogDirectory, $IdleThresholdSeconds, $stopFlagPath

try {
    $monitorProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $monitorArgs -WindowStyle Hidden -PassThru
} catch {
    [System.Windows.Forms.MessageBox]::Show(
        "win-monitor.ps1 failed to start: $($_.Exception.Message)",
        'win-monitor', 'OK', 'Error') | Out-Null
    exit 1
}

# --------------------------------------------------------------------------
# Tray icon - a small filled circle drawn at runtime (no .ico asset to ship),
# in the same blue used for the first series/accent color in index.html.
# --------------------------------------------------------------------------

$bitmap = New-Object System.Drawing.Bitmap 32, 32
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.Clear([System.Drawing.Color]::Transparent)
$fill = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 42, 120, 214))   # #2a78d6
$ring = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 24, 90, 188)), 2.5       # #185abc
$graphics.FillEllipse($fill, 3, 3, 26, 26)
$graphics.DrawEllipse($ring, 3, 3, 26, 26)
$graphics.Dispose()
$fill.Dispose()
$ring.Dispose()

$hIcon = $bitmap.GetHicon()
$icon = [System.Drawing.Icon]::FromHandle($hIcon)
$bitmap.Dispose()

# --------------------------------------------------------------------------
# Menu + tray icon
# --------------------------------------------------------------------------

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$itemOpenFolder = $menu.Items.Add('Open log folder')
$itemOpenViewer = $menu.Items.Add('Open log viewer')
# ContextMenuStrip is the modern ToolStrip-based menu API: unlike the legacy
# MainMenu/MenuItem classes, a literal "-" item here is not auto-converted
# into a separator, so it needs a real ToolStripSeparator.
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$itemExit = $menu.Items.Add('Exit')

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = $icon
$notifyIcon.Text = "win-monitor - logging (idle after ${IdleThresholdSeconds}s)"
$notifyIcon.ContextMenuStrip = $menu
$notifyIcon.Visible = $true
$notifyIcon.ShowBalloonTip(4000, 'win-monitor', 'Running in the background. Right-click the tray icon for options.', 'Info')

$script:exiting = $false

function Stop-Tray {
    # Guards against a double-fire (e.g. the menu item clicked twice before
    # the process finishes exiting).
    if ($script:exiting) { return }
    $script:exiting = $true

    try {
        New-Item -ItemType File -Path $stopFlagPath -Force -ErrorAction SilentlyContinue | Out-Null
        if ($monitorProcess -and -not $monitorProcess.HasExited) {
            # Give the logger a chance to flush the in-progress session via its
            # own finally block before falling back to a hard kill.
            $monitorProcess.WaitForExit(5000) | Out-Null
        }
        if ($monitorProcess -and -not $monitorProcess.HasExited) {
            Stop-Process -Id $monitorProcess.Id -Force -ErrorAction SilentlyContinue
        }
    } finally {
        Remove-Item -LiteralPath $stopFlagPath -Force -ErrorAction SilentlyContinue
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
        [WinMonitor.Tray.NativeIcon]::DestroyIcon($hIcon) | Out-Null
        [System.Windows.Forms.Application]::Exit()
    }
}

function Open-LogFolder {
    try {
        Start-Process -FilePath $LogDirectory
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Couldn't open $LogDirectory`: $($_.Exception.Message)", 'win-monitor') | Out-Null
    }
}

function Open-Viewer {
    if (-not (Test-Path -LiteralPath $viewerPath)) {
        [System.Windows.Forms.MessageBox]::Show('index.html not found next to this script.', 'win-monitor') | Out-Null
        return
    }
    try {
        Start-Process -FilePath $viewerPath
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Couldn't open the viewer: $($_.Exception.Message)", 'win-monitor') | Out-Null
    }
}

$itemOpenFolder.Add_Click({ Open-LogFolder })
$itemOpenViewer.Add_Click({ Open-Viewer })
$itemExit.Add_Click({ Stop-Tray })
$notifyIcon.Add_MouseDoubleClick({
    param($eventSender, $eventArgs)
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Open-Viewer }
})

[System.Windows.Forms.Application]::Run((New-Object System.Windows.Forms.ApplicationContext))
