<#
.SYNOPSIS
    Runs win-monitor.ps1 as a hidden background process with a system tray icon,
    so there is no console window to keep open and a visible way to stop it or
    change the idle threshold and minimum active time.

.DESCRIPTION
    win-monitor.ps1 on its own is a console app: closing its window kills it, and
    running it fully headless (as the old Scheduled Task setup did, with
    -WindowStyle Hidden and no window at all) leaves no visible sign it's running
    and no UI to stop it short of Task Manager.

    This script is the middle ground. It launches win-monitor.ps1 as a separate,
    hidden child process - the logger itself is completely unchanged and still
    runs standalone if you want it to - and shows a tray icon with a right-click
    menu (open the log folder, open the log viewer, change the idle threshold or
    minimum active time, exit) so it's both invisible day-to-day and reachable
    when you need it.

    Stopping - whether via Exit or a settings change - is graceful: a stop-flag
    file that win-monitor.ps1 checks once per poll (see its -StopFlagPath
    parameter) and exits on, the same way Ctrl+C does in a console - the session
    in progress is flushed, not dropped. There is no console here to send
    Ctrl+C to, which is why the logger needed that flag in the first place.

    Settings picked from the tray menu are saved to tray-settings.json in
    -LogDirectory and reused on every future launch, including ones started by
    the Scheduled Task at logon - so they only need setting once.
    -IdleThresholdSeconds and -MinSessionSeconds below are just the seed values
    for a fresh install, before any such file exists.

.PARAMETER LogDirectory
    Passed through to win-monitor.ps1. Default: %LOCALAPPDATA%\win-monitor.

.PARAMETER IdleThresholdSeconds
    Starting idle threshold, passed through to win-monitor.ps1 - but only on
    the very first run. Once changed from the tray menu, the saved value in
    tray-settings.json takes over and this parameter is ignored. Default 300.

.PARAMETER MinSessionSeconds
    Starting minimum active time, passed through to win-monitor.ps1 as
    -MinSessionSeconds - focus sessions shorter than this are dropped as
    alt-tab/window-switching noise rather than logged. Same first-run-only
    caveat as -IdleThresholdSeconds: the tray menu's saved choice wins after
    that. Default 3.

.EXAMPLE
    .\win-monitor-tray.ps1
    Start the tray icon (and the hidden logger behind it) with defaults.

.EXAMPLE
    powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File .\win-monitor-tray.ps1
    How Register-WinMonitorTask.ps1 launches this at logon - no window at all,
    just the tray icon.

.NOTES
    Windows only. PowerShell 5.1 (in-box) or PowerShell 7+.
    Requires no admin rights and no installed modules - System.Windows.Forms,
    System.Drawing, and Microsoft.VisualBasic (for the "Custom..." prompt) all
    ship with Windows.
#>

[CmdletBinding()]
param(
    [string] $LogDirectory = (Join-Path $env:LOCALAPPDATA 'win-monitor'),
    [ValidateRange(5, 86400)]
    [int]    $IdleThresholdSeconds = 300,
    [ValidateRange(0, 3600)]
    [int]    $MinSessionSeconds = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

if (-not ('WinMonitor.Tray.NativeIcon' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

namespace WinMonitor.Tray {
    public static class NativeIcon {
        // Bitmap.GetHicon() hands back an HICON the caller owns; .NET's Icon
        // wrapper does not destroy it for you, so a long-running tray app that
        // never calls this leaks one GDI handle per icon it ever creates.
        [DllImport("user32.dll")]
        public static extern bool DestroyIcon(IntPtr handle);
    }

    // A minimal, tray-side copy of the same "what's in the foreground right
    // now" calls win-monitor.ps1 itself uses - just enough to show a live
    // status line in the tooltip. Polling this independently, rather than
    // reading it back from the logger process, avoids needing any IPC
    // channel between the two.
    public static class NativeWindow {
        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowTextW(IntPtr hWnd, StringBuilder text, int count);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowTextLengthW(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        public static string GetTitle(IntPtr hWnd) {
            if (hWnd == IntPtr.Zero) return "";
            int length = GetWindowTextLengthW(hWnd);
            if (length <= 0) return "";
            StringBuilder sb = new StringBuilder(length + 1);
            GetWindowTextW(hWnd, sb, sb.Capacity);
            return sb.ToString();
        }

        // Wrapped so PowerShell callers don't need an [out]/[ref] parameter -
        // same shape as win-monitor.ps1's own GetWindowProcessId helper.
        public static uint GetProcessId(IntPtr hWnd) {
            uint processId = 0;
            GetWindowThreadProcessId(hWnd, out processId);
            return processId;
        }
    }
}
'@
}

$monitorPath = Join-Path $PSScriptRoot 'win-monitor.ps1'
$viewerPath = Join-Path $PSScriptRoot 'index.html'
$stopFlagPath = Join-Path $LogDirectory '.stop-requested'
$settingsPath = Join-Path $LogDirectory 'tray-settings.json'

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
# Settings - each seeded from its parameter, independently overridden by
# whatever was last saved from the tray menu. A corrupt or partially-missing
# settings file falls back to the parameter on a per-field basis, not as a
# whole, so a bad value in one field doesn't discard a good value in the other.
# --------------------------------------------------------------------------

$script:IdleThresholdSeconds = $IdleThresholdSeconds
$script:MinSessionSeconds = $MinSessionSeconds
if (Test-Path -LiteralPath $settingsPath) {
    $saved = $null
    try {
        $saved = Get-Content -LiteralPath $settingsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        # Corrupt or unreadable settings file - both fields fall back to
        # their parameters below, since $saved stays $null.
    }

    try {
        $idleCandidate = [int]$saved.IdleThresholdSeconds
        if ($idleCandidate -ge 5 -and $idleCandidate -le 86400) {
            $script:IdleThresholdSeconds = $idleCandidate
        }
    } catch {
        # Field missing or not a number - falls back to the parameter.
    }
    try {
        $minActiveCandidate = [int]$saved.MinSessionSeconds
        if ($minActiveCandidate -ge 0 -and $minActiveCandidate -le 3600) {
            $script:MinSessionSeconds = $minActiveCandidate
        }
    } catch {
        # Field missing or not a number - falls back to the parameter.
    }
}

function Save-Settings {
    try {
        [pscustomobject]@{
            IdleThresholdSeconds = $script:IdleThresholdSeconds
            MinSessionSeconds    = $script:MinSessionSeconds
        } | ConvertTo-Json | Set-Content -LiteralPath $settingsPath -Encoding UTF8
    } catch {
        # Non-fatal - the tray keeps running at the in-memory values even if
        # this particular save failed (e.g. a locked or read-only file).
    }
}

function Format-ThresholdLabel {
    param([int] $Seconds)
    if ($Seconds % 60 -eq 0) { return '{0} min' -f ($Seconds / 60) }
    return "${Seconds}s"
}

function Format-MinActiveLabel {
    param([int] $Seconds)
    if ($Seconds -eq 0) { return 'off' }
    if ($Seconds -ge 60 -and $Seconds % 60 -eq 0) { return '{0} min' -f ($Seconds / 60) }
    return "${Seconds}s"
}

# --------------------------------------------------------------------------
# Live status line - "Now: <app> - <title>" in the tray tooltip, refreshed on
# a timer. This reflects whatever currently has OS focus, independent of
# win-monitor.ps1's own idle/locked state machine: while active it's exactly
# what's being logged; during an idle or locked stretch it can only show
# what's in front of it right now, not that the logger has carried the
# earlier window forward as the away session's subject (see the log/viewer
# for that - the tooltip is a glance, not the record).
# --------------------------------------------------------------------------

$script:loggingActive = $true

function Get-ForegroundSummary {
    $handle = [WinMonitor.Tray.NativeWindow]::GetForegroundWindow()
    if ($handle -eq [IntPtr]::Zero) { return $null }

    $title = [WinMonitor.Tray.NativeWindow]::GetTitle($handle)
    $processId = [WinMonitor.Tray.NativeWindow]::GetProcessId($handle)

    $processName = ''
    try {
        $processName = (Get-Process -Id $processId -ErrorAction Stop).ProcessName
    } catch {
        # Process exited between the call and the lookup - not fatal for a tooltip.
    }

    return [pscustomobject]@{ Process = $processName; Title = $title }
}

function Update-TrayTooltip {
    if (-not $script:loggingActive) { return }

    $summary = Get-ForegroundSummary
    $label = '-'
    if ($summary -and $summary.Title) {
        $label = if ($summary.Process) { "$($summary.Process): $($summary.Title)" } else { $summary.Title }
    }

    # A short, fixed first line - not "win-monitor - idle after 5 min" - to
    # leave real room for the window label. NotifyIcon.Text's limit is
    # version-dependent: some .NET/Windows combinations accept up to 127
    # characters, others (seen in practice) throw ArgumentException past 63.
    # 63 is the one that's safe everywhere, so that's the budget, not 127.
    #
    # The "..." below is plain ASCII on purpose, not a single U+2026 ellipsis
    # character: this file has no BOM, and Windows PowerShell 5.1 reads a
    # BOM-less .ps1 using the system's ANSI code page rather than UTF-8, so a
    # literal multi-byte character here silently turns into several garbled
    # characters at runtime on non-Western-European locales - which quietly
    # blew this exact budget and crashed. ASCII has no encoding to get wrong.
    $ellipsis = '...'
    $baseLine = 'win-monitor'
    $overhead = $baseLine.Length + "`nNow: ".Length
    $budget = [Math]::Max($ellipsis.Length, 63 - $overhead)
    if ($label.Length -gt $budget) {
        $label = $label.Substring(0, $budget - $ellipsis.Length) + $ellipsis
    }

    $notifyIcon.Text = "$baseLine`nNow: $label"
}

# --------------------------------------------------------------------------
# The logger child process - started, stopped, and restarted (on a threshold
# change) independently of the tray icon itself.
# --------------------------------------------------------------------------

function Start-Monitor {
    param(
        [int] $IdleSeconds,
        [int] $MinActiveSeconds
    )

    $processArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -LogDirectory "{1}" -IdleThresholdSeconds {2} -MinSessionSeconds {3} -StopFlagPath "{4}" -Quiet' `
        -f $monitorPath, $LogDirectory, $IdleSeconds, $MinActiveSeconds, $stopFlagPath
    try {
        return Start-Process -FilePath 'powershell.exe' -ArgumentList $processArgs -WindowStyle Hidden -PassThru
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "win-monitor.ps1 failed to start: $($_.Exception.Message)",
            'win-monitor', 'OK', 'Error') | Out-Null
        return $null
    }
}

function Stop-Monitor {
    # Same graceful-stop mechanism Exit uses: the flag file is what lets a
    # process with no console ask win-monitor.ps1 to flush and exit on its
    # own, instead of being killed mid-session.
    if (-not $script:monitorProcess) { return }
    New-Item -ItemType File -Path $stopFlagPath -Force -ErrorAction SilentlyContinue | Out-Null
    if (-not $script:monitorProcess.HasExited) { $script:monitorProcess.WaitForExit(5000) | Out-Null }
    if (-not $script:monitorProcess.HasExited) { Stop-Process -Id $script:monitorProcess.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $stopFlagPath -Force -ErrorAction SilentlyContinue
}

$script:monitorProcess = Start-Monitor -IdleSeconds $script:IdleThresholdSeconds -MinActiveSeconds $script:MinSessionSeconds
if (-not $script:monitorProcess) { exit 1 }

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
# Menu
# --------------------------------------------------------------------------

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$itemOpenFolder = $menu.Items.Add('Open log folder')
$itemOpenViewer = $menu.Items.Add('Open log viewer')
# ContextMenuStrip is the modern ToolStrip-based menu API: unlike the legacy
# MainMenu/MenuItem classes, a literal "-" item here is not auto-converted
# into a separator, so it needs a real ToolStripSeparator.
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$thresholdMenu = New-Object System.Windows.Forms.ToolStripMenuItem 'Idle threshold'
[void]$menu.Items.Add($thresholdMenu)
$script:thresholdPresetItems = @()

$minActiveMenu = New-Object System.Windows.Forms.ToolStripMenuItem 'Minimum active time'
[void]$menu.Items.Add($minActiveMenu)
$script:minActivePresetItems = @()

function Update-ThresholdMenuChecks {
    foreach ($presetItem in $script:thresholdPresetItems) {
        $presetItem.Checked = ($presetItem.Tag -eq $script:IdleThresholdSeconds)
    }
}

function Update-MinActiveMenuChecks {
    foreach ($presetItem in $script:minActivePresetItems) {
        $presetItem.Checked = ($presetItem.Tag -eq $script:MinSessionSeconds)
    }
}

# Both submenus change through this one function, which restarts the child
# logger with whichever value changed plus whatever the other one currently
# is - win-monitor.ps1 has no way to reconfigure itself in place, so a
# restart is the only path either setting has.
function Set-LoggerSettings {
    param(
        [int] $IdleSeconds = $script:IdleThresholdSeconds,
        [int] $MinActiveSeconds = $script:MinSessionSeconds
    )
    if ($IdleSeconds -eq $script:IdleThresholdSeconds -and $MinActiveSeconds -eq $script:MinSessionSeconds) { return }

    Stop-Monitor
    $script:monitorProcess = Start-Monitor -IdleSeconds $IdleSeconds -MinActiveSeconds $MinActiveSeconds
    if (-not $script:monitorProcess) {
        # Start-Monitor already showed the error; logging is simply stopped
        # now, so say so rather than pretending the change took effect, and
        # stop the tooltip timer from overwriting that message.
        $script:loggingActive = $false
        $notifyIcon.Text = 'win-monitor - logging stopped (see error)'
        return
    }

    $script:IdleThresholdSeconds = $IdleSeconds
    $script:MinSessionSeconds = $MinActiveSeconds
    Save-Settings
    Update-ThresholdMenuChecks
    Update-MinActiveMenuChecks
    Update-TrayTooltip
    $notifyIcon.ShowBalloonTip(2500, 'win-monitor',
        "Idle threshold $(Format-ThresholdLabel -Seconds $IdleSeconds), minimum active time $(Format-MinActiveLabel -Seconds $MinActiveSeconds).",
        'Info')
}

# Each preset reads its target value from the clicked item's own Tag rather
# than closing over a loop variable, so one shared handler is safe to reuse
# across all of them.
foreach ($minutes in @(2, 5, 10, 15, 30, 60)) {
    $presetItem = New-Object System.Windows.Forms.ToolStripMenuItem "$minutes minutes"
    $presetItem.Tag = $minutes * 60
    $presetItem.Add_Click({
        param($eventSender, $eventArgs)
        Set-LoggerSettings -IdleSeconds $eventSender.Tag
    })
    [void]$thresholdMenu.DropDownItems.Add($presetItem)
    $script:thresholdPresetItems += $presetItem
}
Update-ThresholdMenuChecks

[void]$thresholdMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$itemCustomThreshold = $thresholdMenu.DropDownItems.Add('Custom...')
$itemCustomThreshold.Add_Click({
    $currentMinutes = [math]::Round($script:IdleThresholdSeconds / 60, 1)
    $response = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Minutes of no keyboard/mouse input before it's logged as idle (0.1-1440).",
        'win-monitor - idle threshold',
        "$currentMinutes")
    if ([string]::IsNullOrWhiteSpace($response)) { return }   # Cancelled

    $minutesValue = 0.0
    if (-not [double]::TryParse($response, [ref] $minutesValue)) {
        [System.Windows.Forms.MessageBox]::Show("'$response' isn't a number.", 'win-monitor') | Out-Null
        return
    }
    $secondsValue = [int][math]::Round($minutesValue * 60)
    if ($secondsValue -lt 5 -or $secondsValue -gt 86400) {
        [System.Windows.Forms.MessageBox]::Show('Enter a value between 5 seconds and 1440 minutes (24 hours).', 'win-monitor') | Out-Null
        return
    }
    Set-LoggerSettings -IdleSeconds $secondsValue
})

# Presets in seconds, not minutes - unlike the idle threshold, values here are
# normally single-digit seconds, where "0.05 min" would be a worse prompt
# than "3s".
foreach ($seconds in @(0, 2, 3, 5, 10, 30, 60)) {
    $label = if ($seconds -eq 0) { 'Off (log everything)' } else { "$seconds seconds" }
    $presetItem = New-Object System.Windows.Forms.ToolStripMenuItem $label
    $presetItem.Tag = $seconds
    $presetItem.Add_Click({
        param($eventSender, $eventArgs)
        Set-LoggerSettings -MinActiveSeconds $eventSender.Tag
    })
    [void]$minActiveMenu.DropDownItems.Add($presetItem)
    $script:minActivePresetItems += $presetItem
}
Update-MinActiveMenuChecks

[void]$minActiveMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$itemCustomMinActive = $minActiveMenu.DropDownItems.Add('Custom...')
$itemCustomMinActive.Add_Click({
    $response = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Seconds a window must hold focus before it's logged - shorter switches are dropped as alt-tab noise (0-3600). 0 logs everything.",
        'win-monitor - minimum active time',
        "$script:MinSessionSeconds")
    if ([string]::IsNullOrWhiteSpace($response)) { return }   # Cancelled

    $secondsValue = 0.0
    if (-not [double]::TryParse($response, [ref] $secondsValue)) {
        [System.Windows.Forms.MessageBox]::Show("'$response' isn't a number.", 'win-monitor') | Out-Null
        return
    }
    $secondsValue = [int][math]::Round($secondsValue)
    if ($secondsValue -lt 0 -or $secondsValue -gt 3600) {
        [System.Windows.Forms.MessageBox]::Show('Enter a value between 0 and 3600 seconds (1 hour).', 'win-monitor') | Out-Null
        return
    }
    Set-LoggerSettings -MinActiveSeconds $secondsValue
})

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$itemExit = $menu.Items.Add('Exit')

# --------------------------------------------------------------------------
# The icon itself
# --------------------------------------------------------------------------

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = $icon
$notifyIcon.ContextMenuStrip = $menu
$notifyIcon.Visible = $true
Update-TrayTooltip
$notifyIcon.ShowBalloonTip(4000, 'win-monitor', 'Running in the background. Right-click the tray icon for options.', 'Info')

$statusTimer = New-Object System.Windows.Forms.Timer
$statusTimer.Interval = 2000
$statusTimer.Add_Tick({ Update-TrayTooltip })
$statusTimer.Start()

$script:exiting = $false

function Stop-Tray {
    # Guards against a double-fire (e.g. the menu item clicked twice before
    # the process finishes exiting).
    if ($script:exiting) { return }
    $script:exiting = $true

    try {
        $statusTimer.Stop()
        $statusTimer.Dispose()
        Stop-Monitor
    } finally {
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
