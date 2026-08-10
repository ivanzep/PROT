# Affinity Scripts

Small JavaScript scripts for Affinity's built-in scripting engine (Affinity Photo / Designer / Publisher 3.x — File > Scripts, or the **Scripts** panel).

## relink-images.js

Scans the active document for **linked** (not embedded) images and, for any whose file is missing or has moved, lets you point at the corrected file and relinks it.

- Walks every spread/layer in the active document and collects linked image nodes.
- Checks each linked image's recorded path with `FileSystemApi.exists`.
- For each missing one, first tries the folder you picked for the previous missing image (matched by file name) — handy when a whole folder of assets moved together — then falls back to a native file picker (`FileSystemApi.getOpenFileName`) for anything it can't guess.
- Shows a summary dialog (relinked / skipped / failed) when done.

### Install

1. Open Affinity Photo, Designer, or Publisher.
2. Open the **Scripts** panel (or your installed script library folder).
3. Add `relink-images.js` to your script library, or run it directly if the panel supports "run from file."
4. With the document you want to fix active, run **Relink Images**.

### Known limitation

The scripting SDK confirms `imageResourceInterface.imageFilePath` as a *readable* property (used by community scripts to report linked image paths), but there's no published API reference for writing it back — this script tries a direct assignment and reports per-file if a given Affinity build rejects it. If a file shows up as "Failed" in the summary, relink it manually via **Resource Manager > Relink** (Affinity's built-in dialog also supports pointing at a whole folder to auto-relink everything inside it by file name, which covers the same case).
