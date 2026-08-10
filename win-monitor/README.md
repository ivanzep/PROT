# win-monitor

A prototype for answering one question: **when did this computer get left alone
with windows open, and what was open?**

It logs the window in focus, the file that window has open (best-effort, parsed
from the title bar), and how long each window held focus. Any stretch with no
keyboard or mouse input for 5 minutes (configurable) is closed off as an "idle"
period instead, carrying whatever window was on screen when the user stopped
touching the machine - so idle time is attributed to what was left open, not to
whatever grabbed focus next.

Three pieces:

| File | Purpose |
| --- | --- |
| `win-monitor.ps1` | The logger. Windows only, runs standalone in the foreground, or as the hidden child process `win-monitor-tray.ps1` launches. |
| `win-monitor.cmd` | Double-click launcher for `win-monitor.ps1` on its own, in the foreground - no PowerShell prompt, no execution-policy prompt needed. For watching it log live or one-off testing, not for daily background use. |
| `win-monitor-tray.ps1` | Runs the logger as a hidden background process behind a system tray icon (open the log folder, open the viewer, Exit). This is what actually "runs in the background" day to day - see below. |
| `Register-WinMonitorTask.ps1` | Registers/removes a per-user Scheduled Task so `win-monitor-tray.ps1` starts at logon with no console window. |
| `index.html` | A local, offline log viewer: drop in the JSONL/CSV files the logger writes (or paste log lines, or click "Load sample") and get a timeline, an away-periods table, and time-by-app/file breakdowns. |

No installer, no runtime to add - PowerShell ships with Windows and nothing here needs admin rights. Copy the `win-monitor` folder anywhere (a USB stick works) and it runs as-is.

Nothing here talks to the network. The logger writes to a local file; the viewer
is a static page that only reads files you hand it.

## Running the logger

Easiest: double-click **`win-monitor.cmd`**. It unblocks and runs
`win-monitor.ps1` for you, with no PowerShell prompt and no "this script is
not digitally signed" interruption, and pauses at the end so the summary is
readable before the window closes.

From a PowerShell prompt instead:

```powershell
cd win-monitor
.\win-monitor.ps1
```

Either way it runs in the foreground, printing one line per session, until you
press Ctrl+C - which flushes whatever session is in progress before exiting.
Useful parameters (pass the same way to `win-monitor.cmd`):

```powershell
.\win-monitor.ps1 -IdleThresholdSeconds 120     # away after 2 minutes instead of 5
.\win-monitor.ps1 -DryRun                       # print sessions, write nothing
.\win-monitor.ps1 -LogDirectory D:\Logs\wm      # log somewhere other than %LOCALAPPDATA%\win-monitor
```

```
win-monitor.cmd -IdleThresholdSeconds 120
```

`Get-Help .\win-monitor.ps1 -Full` documents every parameter.

### Running it in the background

Running `win-monitor.ps1` directly (or via `win-monitor.cmd`) is a console app:
close its window and it dies. `win-monitor-tray.ps1` is the background-friendly
wrapper - it starts `win-monitor.ps1` as a separate hidden process and puts a
small blue dot in the system tray over it. Right-click it for **Open log
folder**, **Open log viewer**, and **Exit**; double-click opens the viewer.

```powershell
.\win-monitor-tray.ps1
```

**Exit** is a graceful stop, not a kill: it drops a stop-flag file that
`win-monitor.ps1` checks once per poll and exits on - same as Ctrl+C in a
console - so the session in progress gets flushed to the log rather than lost.
There's no console for the tray to send Ctrl+C to, which is why the logger
gained a `-StopFlagPath` parameter for exactly this.

To have it start automatically at logon, with no window at all - not even the
tray one's console:

```powershell
.\Register-WinMonitorTask.ps1 -StartNow
```

This registers a Scheduled Task whose action is `win-monitor-tray.ps1`, no
admin rights required. It deliberately runs as an **interactive** logon task,
not a "whether the user is logged on or not" one - that second kind runs in
Session 0, where there is no desktop and `GetForegroundWindow` always returns
nothing, so the log would be empty. Interactive is also why no elevation is
needed: it runs at the user's own privilege level, same as any app they open.

```powershell
Get-ScheduledTask -TaskName win-monitor      # check it's registered
.\Register-WinMonitorTask.ps1 -Unregister    # remove the task (logs are untouched)
```

To stop a running instance, right-click the tray icon and choose **Exit** -
that's the flush-first, graceful path. `Stop-ScheduledTask -TaskName
win-monitor` also works but force-kills both the tray host and the logger
without flushing whatever session was in progress.

## What gets logged

One file per day, written as both JSON Lines and a CSV mirror:
`%LOCALAPPDATA%\win-monitor\activity-2026-08-10.jsonl` /
`activity-2026-08-10.csv`. Each line is one finished session:

```json
{"start":"2026-08-10T09:04:31+02:00","end":"2026-08-10T09:31:12+02:00","seconds":1601,
 "type":"active","app":"Code","appName":"Visual Studio Code","file":"index.html",
 "path":"","title":"index.html - win-monitor - Visual Studio Code","processId":18420,"locked":false}
```

`type` is one of:

- **`active`** - a window had focus and the user was providing input.
- **`idle`** - no keyboard/mouse input for `IdleThresholdSeconds`; `app`/`file`/`title`
  describe whatever window was left on screen.
- **`locked`** - same idea, but the workstation was locked (or a secure screen
  saver was active) rather than just idle. `locked: true` on these rows.
- **`monitor`** - not a session at all, a `start`/`stop` marker bracketing a run of
  the logger, so the viewer can tell "nothing happened here" apart from "the
  logger wasn't running here."

Active sessions shorter than `MinSessionSeconds` (default 3) are dropped as
alt-tab noise; idle and locked sessions are always kept regardless of length,
since a short one is still evidence of a gap.

### How the file name is found

There is no API for "what file does this window have open" available to a
plain user-mode script - so the logger reads it out of the window title, the
same text you'd see in the taskbar. That means:

- It's a best guess. A weirdly-titled app, or a browser tab with a generic
  page title, won't yield a file name - `file` is just empty in that case, and
  `title` still has the raw text for you to judge by.
- Browser windows are filtered against a list of document extensions
  (`.pdf`, `.docx`, `.xlsx`, ...) so `example.com - Google Chrome` isn't
  misread as a file called `example`.
- Explorer windows show a folder name, not an extension - that's captured too.
- Anything that looks like an email address is skipped outright (mail and
  chat apps put addresses in the title constantly, and `user@domain.tld`
  otherwise looks exactly like `document.tld` to the same regex).

## Using the viewer

Open `index.html` directly - no server needed, everything runs client-side.

1. Drag the day's log file(s) onto the drop zone (or click it to browse), or
   paste raw JSONL/CSV into the text box and hit **Import pasted log**.
2. Click **Load sample** for a two-day example dataset without needing a real
   log - useful for seeing the layout before running the logger for real.
3. The **Timeline** shows two lanes per day - what had focus, and when the
   machine was unattended - hoverable for exact times. Stretches where the
   monitor itself wasn't running are shown as a hatched gap, distinct from an
   idle period, so "no data" is never mistaken for "no activity."
4. **Away periods** lists every idle/locked stretch past the "Away over"
   threshold, with the window that was left open - this is the "did they
   leave the computer on with something open" answer.
5. **Time by app** / **Time by file** and the **Sessions** table give the
   same data as totals and as raw rows. Both CSV export buttons write exactly
   what the current filters are showing.

Filters (date range, session type, per-app and per-file checklists, minimum
length, away threshold, text search) apply across every panel at once. Apps and
files hidden via their checklists (in the sidebar) stay hidden until re-checked
or reset with **All**. Durations default to decimal hours (`1.50h`); toggle
**Decimal hours** off under Display for `1h 30m` instead.

## Design notes / limits

- **Poll-based, not event-based.** The logger samples the foreground window
  once a second (`PollSeconds`); a session's end time is accurate to that
  interval, except for idle/locked transitions, which use the OS's own
  last-input timestamp (`GetLastInputInfo`) so the away period's start is
  exact rather than rounded to the next poll.
- **No process elevation, no drivers, no hooks.** Everything is a couple of
  `user32.dll`/`kernel32.dll` calls a normal user can make: foreground window,
  window title, last input time, and whether the input desktop can be opened
  (the locked-workstation check). This keeps the prototype deployable without
  IT involvement, at the cost of not seeing anything a plain user-mode process
  can't see (elevated windows report only their title, for instance).
- **The file name is inferred, not verified.** Treat it as a strong hint for a
  human reviewing the log, not as ground truth for anything automated.
