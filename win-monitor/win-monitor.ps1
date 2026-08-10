<#
.SYNOPSIS
    Logs which window is in focus, which file it has open, and how long it stayed
    that way - plus every stretch where the machine was left unattended.

.DESCRIPTION
    Polls the foreground window once a second. A "session" runs from the moment a
    window takes focus until focus moves elsewhere, the title changes (which is how
    a document switch shows up), or the user stops touching the machine.

    When there has been no keyboard or mouse input for -IdleThresholdSeconds
    (default 300 = 5 minutes), the active session is closed at the moment input
    actually stopped - not at the moment the threshold tripped - and an "idle"
    session is opened in its place, carrying the window that was left on screen.
    Locking the workstation records a "locked" session the same way.

    Nothing leaves the machine. The log is a local JSONL file (plus a CSV mirror);
    there is no network code anywhere in this script.

.PARAMETER LogDirectory
    Where the daily log files are written. Default: %LOCALAPPDATA%\win-monitor.

.PARAMETER IdleThresholdSeconds
    No input for this long counts as the user having walked away. Default 300.

.PARAMETER PollSeconds
    How often the foreground window and idle timer are sampled. Default 1.

.PARAMETER MinSessionSeconds
    Active sessions shorter than this are dropped as alt-tab noise. Idle and
    locked sessions are always kept. Default 3. Use 0 to keep everything.

.PARAMETER DurationMinutes
    Stop automatically after this many minutes. Default 0 = run until stopped.

.PARAMETER DryRun
    Print sessions to the console and write no files.

.PARAMETER NoCsv
    Write only the JSONL log, skipping the CSV mirror.

.PARAMETER Quiet
    Suppress the per-session console output.

.EXAMPLE
    .\win-monitor.ps1
    Run in the foreground with defaults. Ctrl+C stops it and flushes the open session.

.EXAMPLE
    .\win-monitor.ps1 -IdleThresholdSeconds 120 -DryRun
    Watch what it would log, with a 2-minute idle threshold, writing nothing.

.EXAMPLE
    powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File .\win-monitor.ps1
    Run in the background with no console window.

.NOTES
    Windows only. PowerShell 5.1 (in-box) or PowerShell 7+.
    Requires no admin rights and no installed modules.
#>

[CmdletBinding()]
param(
    [string] $LogDirectory = (Join-Path $env:LOCALAPPDATA 'win-monitor'),
    [ValidateRange(5, 86400)]
    [int]    $IdleThresholdSeconds = 300,
    [ValidateRange(0.2, 60)]
    [double] $PollSeconds = 1,
    [ValidateRange(0, 3600)]
    [int]    $MinSessionSeconds = 3,
    [ValidateRange(0, 100000)]
    [int]    $DurationMinutes = 0,
    [switch] $DryRun,
    [switch] $NoCsv,
    [switch] $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------
# Win32 interop
# --------------------------------------------------------------------------

if (-not ('WinMonitor.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

namespace WinMonitor {
    public static class Native {
        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowTextW(IntPtr hWnd, StringBuilder text, int count);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowTextLengthW(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        [StructLayout(LayoutKind.Sequential)]
        private struct LASTINPUTINFO {
            public uint cbSize;
            public uint dwTime;
        }

        [DllImport("user32.dll")]
        private static extern bool GetLastInputInfo(ref LASTINPUTINFO info);

        [DllImport("kernel32.dll")]
        private static extern uint GetTickCount();

        [DllImport("user32.dll")]
        private static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint desiredAccess);

        [DllImport("user32.dll")]
        private static extern bool CloseDesktop(IntPtr desktop);

        public static string GetWindowTitle(IntPtr hWnd) {
            if (hWnd == IntPtr.Zero) return "";
            int length = GetWindowTextLengthW(hWnd);
            if (length <= 0) return "";
            StringBuilder sb = new StringBuilder(length + 1);
            GetWindowTextW(hWnd, sb, sb.Capacity);
            return sb.ToString();
        }

        public static uint GetWindowProcessId(IntPtr hWnd) {
            uint processId = 0;
            GetWindowThreadProcessId(hWnd, out processId);
            return processId;
        }

        /// <summary>Seconds since the last keyboard or mouse input, system wide.</summary>
        public static double GetIdleSeconds() {
            LASTINPUTINFO info = new LASTINPUTINFO();
            info.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
            if (!GetLastInputInfo(ref info)) return 0;
            // Unsigned subtraction so the 49.7-day GetTickCount wrap stays correct.
            uint elapsed = unchecked(GetTickCount() - info.dwTime);
            return elapsed / 1000.0;
        }

        /// <summary>
        /// True when the input desktop cannot be opened, which is what a locked
        /// workstation (or an active secure screen saver) looks like from here.
        /// </summary>
        public static bool IsWorkstationLocked() {
            const uint DESKTOP_SWITCHDESKTOP = 0x0100;
            IntPtr desktop = OpenInputDesktop(0, false, DESKTOP_SWITCHDESKTOP);
            if (desktop == IntPtr.Zero) return true;
            CloseDesktop(desktop);
            return false;
        }
    }
}
'@
}

# --------------------------------------------------------------------------
# Title parsing - pulling the active file out of a window title
# --------------------------------------------------------------------------

# Titles are the only file information a plain user-mode poller can see, so the
# extraction is a set of heuristics. Everything it finds also stays in `title`,
# so a wrong guess is always recoverable from the log.

$script:BrowserProcesses = @(
    'chrome', 'msedge', 'firefox', 'brave', 'opera', 'vivaldi', 'arc', 'iexplore'
)

# In a browser title, "example.com - Google Chrome" must not read as a file named
# "example". Only genuine document extensions count there.
$script:BrowserFileExtensions = @(
    'pdf', 'docx', 'doc', 'xlsx', 'xls', 'csv', 'pptx', 'ppt', 'txt', 'md',
    'json', 'xml', 'zip', 'png', 'jpg', 'jpeg', 'svg', 'mp4', 'dwg'
)

# Segments that are the application announcing itself, not a document.
$script:TitleNoise = @(
    'Google Chrome', 'Microsoft Edge', 'Mozilla Firefox', 'Visual Studio Code',
    'Visual Studio', 'Word', 'Excel', 'PowerPoint', 'Outlook', 'OneNote',
    'Notepad', 'Notepad++', 'File Explorer', 'Adobe Acrobat', 'Acrobat Reader',
    'Photoshop', 'Illustrator', 'Autodesk Revit', 'AutoCAD', 'Slack', 'Teams',
    'Windows PowerShell', 'Command Prompt', 'Personal', 'Work'
)

function Split-TitleSegments {
    param([string] $Title)

    # Apps separate title parts with a hyphen, an em/en dash, or a pipe.
    $parts = [regex]::Split($Title, '\s+[-\u2013\u2014|]\s+')
    return @($parts | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Remove-DirtyMarker {
    param([string] $Segment)

    # Unsaved-changes markers: Notepad's "*", VS Code's bullet, Office's tail.
    $clean = $Segment -replace '^[\*\u25CF\u2022\u26AB]\s*', ''
    $clean = $clean -replace '\s*[\*\u25CF\u2022]$', ''
    return $clean.Trim()
}

function Get-ActiveDocument {
    <#
        Returns @{ File = 'report.docx'; Path = 'C:\x\report.docx' }.
        Either field may be empty - plenty of windows have no document at all.
    #>
    param(
        [string] $Title,
        [string] $ProcessName
    )

    $result = @{ File = ''; Path = '' }
    if ([string]::IsNullOrWhiteSpace($Title)) { return $result }

    $isBrowser = $script:BrowserProcesses -contains $ProcessName.ToLowerInvariant()
    # @() re-wraps the result as an array at the call site: a function's `return
    # @(...)` still unwinds a single-element array to a bare scalar across the
    # return boundary, and a title with no " - "/"|" separator (e.g. an Explorer
    # window titled just "win-monitor") is exactly that one-element case. Without
    # this, $segments.Count below throws PropertyNotFoundException under
    # Set-StrictMode, because a scalar [string] has .Length, not .Count.
    $segments = @(Split-TitleSegments -Title $Title)

    foreach ($segment in $segments) {
        $candidate = Remove-DirtyMarker -Segment $segment
        if (-not $candidate) { continue }
        if ($script:TitleNoise -contains $candidate) { continue }
        # An email address always contains '@' and never appears as a real
        # filename here, but "user@domain.tld" otherwise matches the file
        # regex below (extension = the TLD) in every app, not just browsers -
        # mail and chat clients put addresses in the title constantly.
        if ($candidate -match '@') { continue }

        $match = [regex]::Match($candidate, '^(?<full>.*?[^\\/:*?"<>|]+\.(?<ext>[A-Za-z0-9]{1,8}))$')
        if (-not $match.Success) { continue }

        $extension = $match.Groups['ext'].Value.ToLowerInvariant()
        if ($isBrowser -and ($script:BrowserFileExtensions -notcontains $extension)) { continue }

        $full = $match.Groups['full'].Value
        if ($full -match '[\\/]') {
            $result.Path = $full
            $result.File = ($full -split '[\\/]')[-1]
        } else {
            $result.File = $full
        }
        return $result
    }

    # Explorer titles are a folder name with no extension, which is still the
    # subject of the window and worth keeping.
    if ($ProcessName.ToLowerInvariant() -eq 'explorer' -and $segments.Count -gt 0) {
        $result.File = Remove-DirtyMarker -Segment $segments[0]
    }

    return $result
}

function Get-ExplorerPath {
    <#
        Explorer knows its real folder path even though the title only shows the
        leaf name. Ask the shell for it; failure here is never fatal.
    #>
    param([IntPtr] $Handle)

    try {
        $shell = New-Object -ComObject Shell.Application
        foreach ($window in $shell.Windows()) {
            if ($null -eq $window) { continue }
            if ([IntPtr]$window.HWND -ne $Handle) { continue }
            return [string]$window.Document.Folder.Self.Path
        }
    } catch {
        # COM unavailable, window closed mid-query, or a non-filesystem folder.
    }
    return ''
}

# --------------------------------------------------------------------------
# Sampling
# --------------------------------------------------------------------------

$script:ProcessCache = @{}

function Get-ProcessInfo {
    param([uint32] $ProcessId)

    if ($script:ProcessCache.ContainsKey($ProcessId)) {
        return $script:ProcessCache[$ProcessId]
    }

    $info = @{ Name = ''; Product = ''; Executable = '' }
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        $info.Name = $process.ProcessName
        try {
            $info.Executable = $process.Path
            if ($process.Description) { $info.Product = $process.Description }
        } catch {
            # Protected or elevated process: the name is all we get.
        }
    } catch {
        # Process exited between the poll and the lookup.
    }

    # The cache is only worth keeping while the process lives; cap it so a long
    # run does not accumulate every PID the machine ever used.
    if ($script:ProcessCache.Count -gt 512) { $script:ProcessCache.Clear() }
    $script:ProcessCache[$ProcessId] = $info
    return $info
}

function Get-ForegroundSnapshot {
    $handle = [WinMonitor.Native]::GetForegroundWindow()
    $snapshot = @{
        Handle    = $handle
        Title     = ''
        Process   = ''
        AppName   = ''
        Executable = ''
        ProcessId = [uint32]0
        File      = ''
        Path      = ''
    }
    if ($handle -eq [IntPtr]::Zero) { return $snapshot }

    $snapshot.Title = [WinMonitor.Native]::GetWindowTitle($handle)
    $snapshot.ProcessId = [WinMonitor.Native]::GetWindowProcessId($handle)

    $process = Get-ProcessInfo -ProcessId $snapshot.ProcessId
    $snapshot.Process = $process.Name
    $snapshot.AppName = $process.Product
    $snapshot.Executable = $process.Executable

    $document = Get-ActiveDocument -Title $snapshot.Title -ProcessName $snapshot.Process
    $snapshot.File = $document.File
    $snapshot.Path = $document.Path

    if (-not $snapshot.Path -and $snapshot.Process.ToLowerInvariant() -eq 'explorer') {
        $snapshot.Path = Get-ExplorerPath -Handle $handle
    }

    return $snapshot
}

# --------------------------------------------------------------------------
# Writing
# --------------------------------------------------------------------------

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$script:CsvColumns = @(
    'start', 'end', 'seconds', 'type', 'app', 'appName', 'file', 'path',
    'title', 'processId', 'locked'
)

function ConvertTo-CsvField {
    param($Value)

    $text = if ($null -eq $Value) { '' } else { [string]$Value }
    if ($text -match '[",\r\n]') {
        return '"' + $text.Replace('"', '""') + '"'
    }
    return $text
}

function Get-LogPath {
    param(
        [datetime] $Date,
        [string]   $Extension
    )
    return Join-Path $LogDirectory ('activity-{0:yyyy-MM-dd}.{1}' -f $Date, $Extension)
}

function Write-LogEntry {
    param([hashtable] $Entry)

    $object = [pscustomobject]$Entry

    if (-not $Quiet) {
        $label = switch ($Entry.type) {
            'idle'    { 'IDLE  ' }
            'locked'  { 'LOCKED' }
            'monitor' { 'MONITOR' }
            default   { 'ACTIVE' }
        }
        $subject = if ($Entry.file) { $Entry.file } elseif ($Entry.title) { $Entry.title } else { $Entry.app }
        Write-Host ('{0}  {1,6}s  {2,-16} {3}' -f $label, [int]$Entry.seconds, $Entry.app, $subject)
    }

    if ($DryRun) { return }

    $date = [datetime]::Parse($Entry.start)
    $jsonPath = Get-LogPath -Date $date -Extension 'jsonl'
    $line = ($object | ConvertTo-Json -Compress -Depth 3)
    [System.IO.File]::AppendAllText($jsonPath, $line + [Environment]::NewLine, $script:Utf8NoBom)

    if ($NoCsv) { return }

    $csvPath = Get-LogPath -Date $date -Extension 'csv'
    if (-not (Test-Path -LiteralPath $csvPath)) {
        $header = ($script:CsvColumns -join ',')
        [System.IO.File]::AppendAllText($csvPath, $header + [Environment]::NewLine, $script:Utf8NoBom)
    }
    $fields = foreach ($column in $script:CsvColumns) { ConvertTo-CsvField -Value $Entry[$column] }
    [System.IO.File]::AppendAllText($csvPath, ($fields -join ',') + [Environment]::NewLine, $script:Utf8NoBom)
}

function Format-Stamp {
    param([datetimeoffset] $Moment)
    return $Moment.ToString('yyyy-MM-ddTHH:mm:sszzz')
}

function Close-Session {
    param(
        [hashtable]      $Session,
        [datetimeoffset] $EndsAt
    )

    if ($null -eq $Session) { return }

    # An end derived from the idle timer can land before the session started
    # (a window focused during an already-idle stretch); never emit negative time.
    if ($EndsAt -lt $Session.Start) { $EndsAt = $Session.Start }
    $seconds = [math]::Round(($EndsAt - $Session.Start).TotalSeconds, 1)

    if ($Session.Type -eq 'active' -and $seconds -lt $MinSessionSeconds) {
        $script:DroppedSessions++
        $script:DroppedSeconds += $seconds
        return
    }

    Write-LogEntry -Entry @{
        start     = Format-Stamp -Moment $Session.Start
        end       = Format-Stamp -Moment $EndsAt
        seconds   = $seconds
        type      = $Session.Type
        app       = $Session.Snapshot.Process
        appName   = $Session.Snapshot.AppName
        file      = $Session.Snapshot.File
        path      = $Session.Snapshot.Path
        title     = $Session.Snapshot.Title
        processId = [int]$Session.Snapshot.ProcessId
        locked    = ($Session.Type -eq 'locked')
    }
}

function Step-Session {
    <#
        One poll's worth of decision making: given the session in progress and
        what the machine looks like now, close whatever ended and return the
        session that is current afterwards.

        $InputStopped is the instant input actually ceased. Using it - rather
        than "now" - as both the end of an active session and the start of the
        away session means the away stretch covers the whole time the user was
        gone, not just the part after the threshold tripped, and the two
        sessions meet exactly with no gap.
    #>
    param(
        [hashtable]      $Current,
        [ValidateSet('active', 'idle', 'locked')]
        [string]         $State,
        [hashtable]      $Snapshot,
        [datetimeoffset] $Now,
        [datetimeoffset] $InputStopped
    )

    if ($State -eq 'active') {
        $key = '{0}|{1}|{2}' -f $Snapshot.Handle, $Snapshot.ProcessId, $Snapshot.Title
        if ($null -ne $Current -and $Current.Type -eq 'active' -and $Current.Key -eq $key) {
            return $Current
        }
        # Returning from away: the away session ended when input resumed.
        $endsAt = $Now
        if ($null -ne $Current -and $Current.Type -ne 'active') { $endsAt = $InputStopped }
        Close-Session -Session $Current -EndsAt $endsAt
        return @{ Type = 'active'; Key = $key; Start = $endsAt; Snapshot = $Snapshot }
    }

    if ($null -ne $Current -and $Current.Type -eq $State) {
        return $Current
    }

    # Keep whichever window was on screen when the user walked away - that is
    # the thing left open, which is the point of the log.
    $carried = $Snapshot
    if ($null -ne $Current) { $carried = $Current.Snapshot }
    Close-Session -Session $Current -EndsAt $InputStopped
    return @{ Type = $State; Key = $State; Start = $InputStopped; Snapshot = $carried }
}

function Write-MonitorEvent {
    param(
        [string]         $Event,
        [datetimeoffset] $Moment
    )

    Write-LogEntry -Entry @{
        start     = Format-Stamp -Moment $Moment
        end       = Format-Stamp -Moment $Moment
        seconds   = 0
        type      = 'monitor'
        app       = $Event
        appName   = ''
        file      = ''
        path      = ''
        title     = "win-monitor $Event (idle threshold ${IdleThresholdSeconds}s)"
        processId = $PID
        locked    = $false
    }
}

# --------------------------------------------------------------------------
# Main loop
# --------------------------------------------------------------------------

$script:DroppedSessions = 0
$script:DroppedSeconds = 0

if (-not $DryRun -and -not (Test-Path -LiteralPath $LogDirectory)) {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
}

Write-Host ''
Write-Host 'win-monitor' -ForegroundColor Cyan
Write-Host ('  log       : {0}' -f $(if ($DryRun) { 'dry run - nothing is written' } else { $LogDirectory }))
Write-Host ('  idle after: {0}s' -f $IdleThresholdSeconds)
Write-Host ('  poll      : {0}s, dropping active sessions under {1}s' -f $PollSeconds, $MinSessionSeconds)
if ($DurationMinutes -gt 0) { Write-Host ('  stops in  : {0} min' -f $DurationMinutes) }
Write-Host '  Ctrl+C to stop.'
Write-Host ''

$startedAt = [datetimeoffset]::Now
Write-MonitorEvent -Event 'start' -Moment $startedAt

$current = $null
$pollMs = [int]($PollSeconds * 1000)

try {
    while ($true) {
        if ($DurationMinutes -gt 0 -and ([datetimeoffset]::Now - $startedAt).TotalMinutes -ge $DurationMinutes) {
            break
        }

        $now = [datetimeoffset]::Now
        $idleSeconds = [WinMonitor.Native]::GetIdleSeconds()
        $isLocked = [WinMonitor.Native]::IsWorkstationLocked()

        $state = 'active'
        if ($isLocked) {
            $state = 'locked'
        } elseif ($idleSeconds -ge $IdleThresholdSeconds) {
            $state = 'idle'
        }

        $inputStopped = $now.AddSeconds(-$idleSeconds)

        # Away polls reuse the session's own snapshot, so the foreground window
        # is only queried when it can actually have changed.
        $snapshot = $null
        if ($state -eq 'active' -or $null -eq $current) { $snapshot = Get-ForegroundSnapshot }
        else { $snapshot = $current.Snapshot }

        $current = Step-Session -Current $current -State $state -Snapshot $snapshot `
            -Now $now -InputStopped $inputStopped

        Start-Sleep -Milliseconds $pollMs
    }
} finally {
    # Ctrl+C lands here too, so the session in flight is never lost.
    $stoppedAt = [datetimeoffset]::Now
    Close-Session -Session $current -EndsAt $stoppedAt
    Write-MonitorEvent -Event 'stop' -Moment $stoppedAt

    Write-Host ''
    Write-Host ('Stopped after {0:hh\:mm\:ss}.' -f ($stoppedAt - $startedAt))
    if ($script:DroppedSessions -gt 0) {
        Write-Host ('Dropped {0} session(s) under {1}s ({2}s total).' -f `
            $script:DroppedSessions, $MinSessionSeconds, [math]::Round($script:DroppedSeconds, 1))
    }
    if (-not $DryRun) {
        Write-Host ('Log: {0}' -f (Get-LogPath -Date (Get-Date) -Extension 'jsonl'))
    }
}
