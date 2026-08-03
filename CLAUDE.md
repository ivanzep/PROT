# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository overview

This repo is a collection of independent browser prototypes, one per folder. They share no code and no tooling: there is no build system, package manager, dependency manifest, or test suite anywhere in the repo, and no prototype has external dependencies.

- `file-renamer/` — a self-contained, single-file "Batch File Renamer" web app (`index.html` with inline `<style>` and `<script>`).
- `inbox-digests/` — dated inbox digest reports (`YYYY-MM-DD-inbox-digest.html`) plus an `index.html` archive that browses them.
- `F1/` — a race weekend dashboard (`index.html`, `data.json`, `README.md`). The only prototype that is more than one file, and the only one that needs a local HTTP server rather than `file://`.

Treat each folder as its own project. The sections below cover them individually; don't carry conventions from one into another.

## file-renamer

### Development workflow

There is no build/lint/test tooling in this repo. To work on the app:

- Edit `file-renamer/index.html` directly (HTML, CSS, and JS all live in this one file).
- Open the file directly in a browser to try it (e.g. `open file-renamer/index.html` on macOS, or serve it with any static server such as `python3 -m http.server` from the `file-renamer/` directory). A local server is only needed to test drag-and-drop or folder-picker behavior consistently — plain `file://` access works for most manual testing.
- There is no automated test suite. Verify changes manually in a Chromium-based browser (folder selection via `webkitdirectory` is Chromium-only; other browsers only support multi-file selection).
- Click "Load Sample" in the UI to populate a sample dataset for quick manual verification without needing real files.

### Architecture

The app is a client-side rename **planner**, not a renamer. Plain HTML/JS cannot rename files on disk, so the tool builds a rename plan in memory and lets the user export it as either a CSV (for review) or a PowerShell script (`Rename-Item` commands) to actually execute the renames on Windows.

Everything lives in one `<script>` block in `file-renamer/index.html`, structured as a straightforward pipeline:

1. **Ingest records** — Files come from three input paths, all normalized into a common `record` shape (`fileToRecord`, `importPathList`, `loadSample`):
   - Drag-and-drop or file/folder pickers (`addFiles` → `fileToRecord`), which also read embedded media dates.
   - A pasted plain-text/CSV path list (`importPathList`), useful for testing Windows-style paths without native file access.
   - `loadSample`, which seeds the path-list importer with canned CSV rows.
   - All records are pushed into `state.records`.

2. **Read media metadata** (`readMediaDates`) — For dropped/picked files only, the app extracts real capture dates by parsing raw bytes itself (no libraries):
   - JPEG/TIFF: minimal hand-rolled EXIF parser (`readExifDate` → `parseTiffForExifDate` → `findTiffTag`) that walks the JPEG APP1/TIFF/IFD structure to find `DateTimeOriginal` (tag `0x9003`) or fallback `DateTime` (`0x0132`).
   - MP4/MOV/M4V: minimal MP4 box walker (`readMp4CreationDate` → `findMp4Date`) that recurses into `moov`/`trak`/`mdia` atoms to find `mvhd`/`tkhd`/`mdhd` creation timestamps, converting from the MP4 epoch (1904) via `mp4EpochToDate`.

3. **Build the rename plan** (`buildPlan`, triggered by `refresh` on every input change) — Pure function over `state.records` and the current form options (`getOptions`):
   - Sorts records per `sortMode` (`compareRecords`).
   - Assigns sequence numbers/letters (`formatSequence`, `numberToLetters`).
   - Picks the date to use per record based on `dateSource` (`chooseDate`, with precedence: taken → recorded → created → modified when source is `media`).
   - Renders the name pattern (tokens like `{date}`, `{folder}`, `{base}`, `{seq}`, etc.) via `renderPattern` and `getTokenContext`.
   - Cleans up the result (case, separator, invalid characters) via `cleanupName`/`sanitizeFileName`.
   - Detects and resolves collisions by appending a sequence suffix when enabled, otherwise flags status as `conflict`.
   - Produces `state.plan`, an array of `{record, newName, dateUsed, status, ...}` used purely for rendering — nothing is written to disk here.

4. **Render** (`renderStatus`, `renderTable`) — Reflects `state.plan` into the status pills and preview table. All UI state is driven by re-running `refresh()` (`buildPlan` + both render functions) on any input change; there is no incremental diffing.

5. **Export** (`exportCsv`, `exportPowerShell`) — Turns the current `state.plan` into a downloadable file via an in-memory `Blob` and a synthetic `<a download>` click (`downloadText`). The PowerShell export excludes `unchanged`/`conflict` rows and quotes paths/names with `psString` for safe `Rename-Item -LiteralPath` usage.

### Key conventions

- Paths are normalized to forward slashes internally (`splitPath`) regardless of source OS, and converted back to backslashes only when generating the PowerShell script.
- `record.path`/`record.directory`/`record.folder`/`record.base`/`record.ext` are the canonical decomposed-path fields used throughout the pipeline — reuse `splitPath`/`splitName` rather than re-deriving these from a raw path.
- `state.records` is raw input data (immutable per session, only appended/cleared); `state.plan` is always a derived, disposable recomputation from `state.records` + current options — never mutate `state.plan` directly or hand-patch it, just call `refresh()`.
- All user-supplied/file-derived text rendered into the DOM goes through `escapeHtml`; anything written into the generated `.ps1` goes through `psString`. Keep using these when adding new rendered/exported fields.

## F1

A race weekend dashboard: track map with per-sector highlighting, race distance, historic results, tire compounds, pit stop time loss, and a parked placeholder for live timing.

- Serve it over HTTP — `cd F1 && python3 -m http.server` — because it fetches `data.json`. Opening `index.html` over `file://` deliberately renders a "serve over HTTP" message instead of a blank page.
- `F1/data.json` holds the circuit dataset; adding a circuit needs no code changes. `F1/index.html` holds all markup, styles, and logic.
- Historic results are fetched live from the Ergast-compatible API configured under `meta.api` in `data.json`; the seeded `history` arrays are the offline fallback and render until (or instead of) a successful response. A pill above the table always says whether the data is live or sample.
- `F1/README.md` is the detailed reference — data shape, API behaviour, layout, and what is parked. Read it before changing the data layer.
