# Split Text by Words

Takes a text frame in Affinity Designer (or Photo / Publisher) and breaks it into **one text object per word**, each a duplicate of the original frame so font, size, colour, and every other attribute carry over.

Written for the case where each word has to be moved, animated, or styled on its own — something Affinity has no built-in command for.

## What it does

1. Uses the **current selection** (text frames only). With nothing selected it offers to split every text frame in the document instead, after warning you.
2. Asks how to lay the words out:
   - `row` — side by side, left to right, starting where the original frame was (default)
   - `column` — one per line, top to bottom
   - `stack` — all left at the original position, on top of each other, for when you want to place them by hand
3. For each frame: duplicates it once per word, writes a single word into each duplicate, spaces them out, and removes the original (hiding it if it can't be removed).
4. Reports what it did — frames split, word objects created, and anything it couldn't do — in a summary dialog.

Words are split on runs of whitespace, so punctuation stays attached to the word it touches (`"world,"` stays one object). A frame holding a single word or nothing is left alone rather than being needlessly rebuilt.

## Install

1. Open Affinity Photo, Designer, or Publisher.
2. Open the **Scripts** panel (or your installed script library folder).
3. Add `split-text-by-words.js` to your script library, or run it directly if the panel supports "run from file."
4. Select the text frame(s) you want to break up and run **Split Text by Words**.

`Edit > Undo` reverses the whole run if the result isn't what you wanted — check the result before saving.

## The API calls are probed, not assumed

Affinity's scripting reference is served from inside the app itself (an MCP server on `localhost:6767`) and isn't published on the web, so the exact spelling of the "read the text", "write the text", "duplicate this node", "move this node", and "delete this node" calls couldn't be verified against a reference while writing this. Every one of those goes through the `attempt` / `attemptVoid` helpers at the top of the script, which try a list of plausible spellings in order and move on when one throws.

That has two consequences worth knowing:

- **Failures are reported, not silent.** If your build doesn't expose any of the candidate spellings for a given operation, the summary dialog names the operation instead of the script quietly doing half a job. Nothing is left half-split: a frame whose words can't be written is abandoned before its duplicates are kept, so the document is unchanged for that frame.
- **Writing text is verified by reading it back.** Several of the candidate write spellings will happily create a new unused property on a node rather than throwing, which would leave every duplicate showing the full original sentence while the script claimed success. `setText` therefore only counts as a success when `readText` returns exactly the word that was just written.

If a whole operation turns out to be unsupported on your build, the fix is to add the right spelling to the relevant candidate list — they're short and each one is a single arrow function.

### Collections are unwrapped by probing too

`doc.spreads` reports a numeric `length` but does **not** answer to `spreads[i]` — indexing it yields `undefined`. The first version of this script read collections length-first and so built an array of `undefined` entries, then died one line later with `TypeError: Cannot read properties of undefined (reading 'layers')`. `toArray` now tries `.all`/`.items`, then iteration, then indexing (`[i]`, `.get(i)`, `.item(i)`, `.at(i)`) in that order, and only believes a strategy that yields a complete set of real entries — so a half-working collection API can't leak holes into the rest of the script. Keep that ordering if you touch it.

## Layout without a text measuring API

Word spacing uses each duplicate's own bounds *after* its text has been replaced, plus a 25% gap (`GAP_RATIO`), so words are spaced by what they actually render as rather than by a guessed character width. If a build doesn't expose readable bounds on the duplicates, the script falls back to spreading the words evenly across the space the original frame occupied. If neither is readable, the words end up stacked at the original position and the summary says so explicitly — that case is a fallback, not a layout mode you'd choose (`stack` exists for that).

## If the script "does nothing" when run

Affinity's script host doesn't reliably surface uncaught JS errors, so a script that appears in the Scripts panel but produces no dialog at all has usually thrown before reaching its first `app.alert`. The whole run is wrapped in a `try/catch` that reports the error in a dialog for exactly this reason — if you still see nothing, the failure happened before that block, i.e. in the `require('/application')` call at the top of the file, which would mean this build's scripting API doesn't expose that module under that name.
