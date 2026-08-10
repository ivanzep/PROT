# Affinity Scripts

Small JavaScript scripts for Affinity's built-in scripting engine (Affinity Photo / Designer / Publisher 3.x — File > Scripts, or the **Scripts** panel).

## relink-images.js

Scans the active document for **linked** (not embedded) images and, for any whose file is missing or has moved, lets you point at the corrected file and relinks it.

- Walks every spread/layer in the active document and collects linked image nodes.
- Tries each linked image's recorded path with `FileSystemApi.exists` — see the sandbox note below for why this can't reliably tell "missing" from "fine."
- For each one it can't confirm, first tries the folder you picked for the previous image (matched by file name) — handy when a whole folder of assets moved together — then asks you to locate it: via a native file picker (`FileSystemApi.getOpenFileName`) where that's available, or a plain text prompt for the full path where it isn't (see below). Leave it blank/Cancel to leave an image as-is.
- Shows a summary dialog (relinked / skipped / failed) when done.

### Sandbox limitation: it can't silently tell what's actually missing

Affinity's scripting sandbox only grants file-system access to paths the user has explicitly picked through a native dialog — not to arbitrary paths a script reads out of a document's own metadata. `FileSystemApi.exists()` throws `PERMISSION_DENIED` when checked against a linked image's recorded path for exactly this reason. The script catches that and treats "can't confirm" the same as "needs a look," which means **every** linked image will be offered for relinking, not just the genuinely broken ones — click Cancel in the file picker for any that are already fine. This is a real constraint of the platform, not a bug to chase further; the built-in **Resource Manager** panel can do this silently only because it's part of Affinity itself, not a sandboxed script.

### Not every build has a native file picker

`FileSystemApi.getOpenFileName` isn't present on every Affinity 3.x build even though some community scripts rely on it — confirmed missing (`TypeError: ... is not a function`) on at least one release. When it's not available, the script falls back to `app.prompt`, a plain text box, pre-filled with its best guess at the corrected path. That also means the "reuse the last folder" shortcut rarely helps in text-prompt mode, since typing a path doesn't grant the sandbox access the way picking one through a native dialog does — expect one prompt per linked image on those builds.

### Install

1. Open Affinity Photo, Designer, or Publisher.
2. Open the **Scripts** panel (or your installed script library folder).
3. Add `relink-images.js` to your script library, or run it directly if the panel supports "run from file."
4. With the document you want to fix active, run **Relink Images**.

### Known limitation

The scripting SDK confirms `imageResourceInterface.imageFilePath` as a *readable* property (used by community scripts to report linked image paths), but there's no published API reference for writing it back — this script tries a direct assignment and reports per-file if a given Affinity build rejects it. If a file shows up as "Failed" in the summary, relink it manually via **Resource Manager > Relink** (Affinity's built-in dialog also supports pointing at a whole folder to auto-relink everything inside it by file name, which covers the same case).

### If the script "does nothing" when run

Affinity's script host doesn't reliably surface uncaught JS errors, so a script that appears in the Scripts panel but produces no dialog at all when run has usually thrown before reaching its first `app.alert`. The script wraps its whole run in a `try/catch` that reports the error via a dialog for exactly this reason — if you still see nothing, check the console/log the Scripts panel exposes (if any) for output, since that means the failure happened even before that `try` block (e.g. in the `require('/application')` / `require('/fs')` calls at the top of the file, which would mean this build's scripting API doesn't expose those modules under those names).
