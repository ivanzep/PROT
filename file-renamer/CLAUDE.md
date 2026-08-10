# CLAUDE.md — file-renamer

Guidance for working on the Batch File Renamer prototype. Scoped to this folder;
the repo root `CLAUDE.md` covers the other prototypes and does not need to be
consulted for work that stays inside `file-renamer/`.

## What this is

A single self-contained file: `index.html`, with all markup, CSS (`<style>`, lines
7–326), and JavaScript (`<script>`, lines 499–1160) inline. No build system, no
package manager, no dependencies, no tests, no imports. Editing this one file is
the entire development workflow.

Critically, the app is a rename **planner**, not a renamer. Browser JS cannot
rename files on disk, so the tool builds a plan in memory and exports it as a CSV
(for review) or a PowerShell script of `Rename-Item` commands (to actually run the
renames on Windows). Never add code that implies files are being modified in
place — nothing in this app touches the filesystem.

## Running and verifying

- Open `index.html` directly in a browser (`file://` works for most manual testing).
- Serve it (`python3 -m http.server` from this directory) only when testing
  drag-and-drop or the folder picker, which behave more consistently over HTTP.
- Verify in a Chromium-based browser: `webkitdirectory` folder selection and
  `webkitGetAsEntry` directory traversal are Chromium-only. Other browsers fall
  back to multi-file selection.
- **Click "Load Sample" for quick verification** — it seeds four canned CSV rows
  (two JPEGs with dates taken, two MP4s with recorded dates) through the path-list
  importer, so you get a populated table without needing real files on disk.
- Media-date parsing (EXIF/MP4) cannot be exercised by Load Sample. It only runs
  on dropped or picked real files; sample and path-list rows get their dates from
  CSV columns instead.

## Architecture

One `<script>` block, organized as a linear pipeline. Every input change calls
`refresh()`, which recomputes everything from scratch.

### 1. Ingest → `state.records`

Three input paths, all normalized to a common record shape:

- `addFiles` → `fileToRecord` (`index.html:638`) — drag-and-drop and the
  file/folder pickers. Also awaits `readMediaDates`. Deduplicates against existing
  records by `id` (`` `${relativePath}|${file.size}|${file.lastModified}` ``).
- `importPathList` (`index.html:669`) — parses the textarea as one path per line,
  optionally CSV: `path,created_at,date_taken,date_recorded`. Does **not**
  deduplicate; re-importing appends duplicates.
- `loadSample` (`index.html:695`) — fills the textarea with canned rows and calls
  `importPathList`.

Record shape (the canonical fields, used throughout):

```
id, source ('file' | 'path'), file?, path, directory, folder, name, base, ext,
modifiedDate, createdDate, takenDate, recordedDate, mediaNote
```

`path`/`directory`/`folder`/`name`/`base`/`ext` are always derived by
`splitPath`/`splitName` — reuse those rather than re-deriving from a raw string.

### 2. Read media metadata (`readMediaDates`, `index.html:888`)

Dropped/picked files only. Raw byte parsing, hand-rolled, no libraries:

- **JPEG/TIFF** — `readExifDate` (reads the first 512 KB) walks JPEG markers to the
  APP1 segment, checks for the `Exif\0\0` header, then `parseTiffForExifDate` reads
  the TIFF endianness/magic and uses `findTiffTag` to locate the Exif IFD pointer
  (`0x8769`) and from it `DateTimeOriginal` (`0x9003`), falling back to `DateTime`
  (`0x0132`) in IFD0.
- **MP4/MOV/M4V** — `readMp4CreationDate` (reads the first 4 MB) hands off to
  `findMp4Date`, which walks the box structure, recurses into `moov`/`trak`/`mdia`
  (max depth 6), and reads the creation timestamp from `mvhd`/`tkhd`/`mdhd`,
  handling both 32-bit (version 0) and 64-bit (version 1) layouts.
  `mp4EpochToDate` converts from the 1904 epoch by subtracting 2082844800.

Both are wrapped in a try/catch that degrades to a `mediaNote` string rather than
throwing. Preserve that — a malformed file must never break the whole batch.

### 3. Build the plan (`buildPlan`, `index.html:706`)

Pure function of `state.records` + `getOptions()`. In order:

1. Sort a copy of the records per `sortMode` via `compareRecords` (all comparisons
   use `localeCompare` with `{numeric: true}`).
2. Assign `seqNumber = seqStart + index * seqStep` by sorted position, then format
   it via `formatSequence` (zero-padded number, or `numberToLetters` for A/B/C and
   a/b/c modes).
3. Pick the date via `chooseDate`. For the default `media` source the precedence is
   **taken → recorded → created → modified**; the other sources select exactly one
   field, and `manual` uses the parsed manual-date input.
4. Render the pattern with `renderPattern` + `getTokenContext`. The token regex is
   a fixed allowlist — **adding a token means updating both the regex in
   `renderPattern` (`index.html:823`) and the `tokens` array (`index.html:505`)**,
   plus supplying the value in `getTokenContext`.
5. Clean up via `cleanupName` (invalid chars → separator, whitespace collapse,
   separator run collapse, edge trim, case mode; falls back to `'untitled'`) and
   `sanitizeFileName` (strips `\/:*?"<>|`, trailing dots/spaces, truncates to 240).
6. Detect collisions on the case-insensitive key `` `${directory}/${newName}` ``.
   When `collisionSuffix` is on, append a padded counter and mark
   `'conflict fixed'`; otherwise mark `'conflict'`.

Statuses are `'unchanged'`, `'ready'`, `'conflict fixed'`, `'conflict'`.

Plan item shape: `{record, index, seq, newName, dateUsed, mediaDate, status}`.

### 4. Render (`renderStatus`, `renderTable`)

Both rebuild their `innerHTML` wholesale from `state.plan`. There is no incremental
diffing and no need for any — keep it that way.

### 5. Export

- `exportCsv` — every plan row, columns
  `source_path,current_name,new_name,folder,date_used,status`, escaped by
  `csvEscape`.
- `exportPowerShell` — filters out `unchanged` and `conflict` rows, converts
  forward slashes back to backslashes, and emits
  `Rename-Item -LiteralPath '…' -NewName '…'` with `$ErrorActionPreference = "Stop"`.
- Both go through `downloadText`, which builds a `Blob`, creates an object URL, and
  clicks a synthetic `<a download>`.

## Conventions

- **Paths are forward-slash internally**, always, regardless of source OS
  (`splitPath` normalizes). Convert to backslashes only when generating PowerShell.
- **`state.records` is input; `state.plan` is derived and disposable.** Records are
  only appended to or cleared. Never mutate or hand-patch `state.plan` — change an
  option or a record and call `refresh()`.
- **Escaping is not optional.** Anything file-derived or user-supplied goes through
  `escapeHtml` before hitting the DOM, `csvEscape` before the CSV, and `psString`
  (single-quoted, `'` doubled) before the `.ps1`. Any new rendered or exported field
  must use them too — file names are attacker-adjacent input here.
- Add new DOM references to the `els` map (`index.html:518`) rather than calling
  `getElementById` inline, and register new option inputs in the `refresh` listener
  array in `wireEvents` (`index.html:585`) so changes recompute the plan.
- Match the surrounding style: no semicolon-free lines, arrow functions, template
  literals, `const`/`let`, small named top-level functions, no classes.

## Known rough edges

Pre-existing behavior, documented so it isn't mistaken for a fresh regression.
Confirm with the user before "fixing" any of these — they may be intentional for a
prototype:

- Collision detection keys on the pre-suffix name (`index.html:719`), so a
  collision-fixed name is never itself re-checked and can still land on another
  planned or existing name.
- The `keepExtension: false` branch (`index.html:717`) re-renders the pattern a
  second time with `ext` injected into the context, even though `{ext}` is already
  available in the first render — the two paths can diverge.
- `importPathList` assigns CSV column 1 to both `modifiedDate` and `createdDate`
  (`index.html:684`), so `{created}` and `{modified}` are always identical for
  imported rows.
- Sequence numbers are assigned by sort position before collision handling, so the
  `{seq}` token and the collision suffix are independent counters that can disagree.
- `findMp4Date` assumes the same creation-time offset for `mvhd`, `tkhd`, and
  `mdhd`. That holds for the fields it reads, but it is an assumption, not a parse.
