/**
 * name: Split Text by Words
 * description: Splits the text in the selected text frame(s) into one text object per word, keeping the original formatting.
 * version: 1.0.0
 */

'use strict';

const { app } = require('/application');

const TITLE = 'Split Text by Words';

// Fraction of a word's own width used as the gap between words when
// laying them out in a row (and of its height, between rows in a column).
const GAP_RATIO = 0.25;

/* ------------------------------------------------------------------ *
 * Undocumented-API probing helpers.
 *
 * Affinity's scripting reference is served from inside the app itself
 * and isn't published, so the exact spelling of the text/duplicate/move
 * calls varies by build and can't be checked from here. Every SDK call
 * below therefore goes through `attempt`, which tries a list of
 * candidate spellings and reports which one (if any) worked - so a build
 * mismatch shows up as a clear message in the summary dialog instead of
 * a silent no-op or a dead script.
 * ------------------------------------------------------------------ */

// Runs each thunk in order, returning the first result that is neither
// a thrown error nor undefined/null. Returns `undefined` if all fail.
function attempt(thunks) {
  for (const fn of thunks) {
    let value;
    try {
      value = fn();
    } catch (e) {
      continue;
    }
    if (value !== undefined && value !== null) return value;
  }
  return undefined;
}

// Same as `attempt`, but for calls whose useful result is the side
// effect rather than a return value. Returns true on the first thunk
// that doesn't throw.
function attemptVoid(thunks) {
  for (const fn of thunks) {
    try {
      fn();
      return true;
    } catch (e) {
      continue;
    }
  }
  return false;
}

function isTextNode(node) {
  if (!node) return false;
  if (node.isTextNode === true) return true;
  if (node.isTextFrame === true) return true;
  const type = String(node.type || node.nodeType || '').toLowerCase();
  return type.indexOf('text') >= 0;
}

// A text node's string lives behind a different property on different
// builds (and sometimes behind a text-range object rather than directly
// on the node), so unwrap whatever we find down to a plain string.
function readText(node) {
  const raw = attempt([
    () => node.text,
    () => node.textRange,
    () => node.story,
    () => node.contents,
  ]);
  if (raw === undefined) return undefined;
  if (typeof raw === 'string') return raw;
  const unwrapped = attempt([
    () => (typeof raw.getText === 'function' ? raw.getText() : undefined),
    () => (typeof raw.text === 'string' ? raw.text : undefined),
    () => (typeof raw.value === 'string' ? raw.value : undefined),
    () => (typeof raw.toString === 'function' ? raw.toString() : undefined),
  ]);
  return typeof unwrapped === 'string' ? unwrapped : undefined;
}

// Writing is verified by reading the text straight back: several of the
// candidate spellings below will happily create a brand-new property on
// the node instead of throwing, which would leave the duplicate showing
// the original full sentence while the script reported success.
function setText(node, value) {
  const writes = [
    () => {
      node.text = value;
    },
    () => {
      node.textRange.text = value;
    },
    () => {
      node.text.value = value;
    },
    () => node.textRange.setText(value),
    () => node.setText(value),
    () => {
      node.contents = value;
    },
  ];
  for (const write of writes) {
    try {
      write();
    } catch (e) {
      continue;
    }
    if (readText(node) === value) return true;
  }
  return false;
}

// Duplicating the original node (rather than creating a fresh text
// object) is what preserves font, size, colour, and every other
// attribute of the frame being split.
function duplicateNode(doc, node) {
  return attempt([
    () => node.duplicate(),
    () => node.clone(),
    () => doc.duplicate(node),
    () => doc.clone(node),
  ]);
}

// Normalises whichever bounds shape a build exposes into {x, y, w, h}.
function readBounds(node) {
  const b = attempt([
    () => node.boundsInParent,
    () => node.bounds,
    () => node.boundingBox,
    () => (typeof node.getBounds === 'function' ? node.getBounds() : undefined),
  ]);
  if (!b) return undefined;
  const x = attempt([() => b.x, () => b.left]);
  const y = attempt([() => b.y, () => b.top]);
  const w = attempt([() => b.width, () => b.w, () => b.right - b.left]);
  const h = attempt([() => b.height, () => b.h, () => b.bottom - b.top]);
  if ([x, y, w, h].some((n) => typeof n !== 'number')) return undefined;
  return { x, y, w, h };
}

function translateNode(node, dx, dy) {
  if (dx === 0 && dy === 0) return true;
  return attemptVoid([
    () => node.translate(dx, dy),
    () => node.move(dx, dy),
    () => node.moveBy(dx, dy),
    () => {
      node.position = { x: node.position.x + dx, y: node.position.y + dy };
    },
    () => {
      node.x = node.x + dx;
      node.y = node.y + dy;
    },
  ]);
}

function removeNode(doc, node) {
  return attemptVoid([
    () => node.remove(),
    () => node.delete(),
    () => doc.remove(node),
    () => doc.delete(node),
  ]);
}

function hideNode(node) {
  return attemptVoid([
    () => {
      node.isVisible = false;
    },
    () => {
      node.visible = false;
    },
  ]);
}

/* ------------------------------------------------------------------ *
 * Selection / document walking
 * ------------------------------------------------------------------ */

// Collection shapes differ per build and per collection: a real array,
// something iterable, a wrapper exposing the real list as `.all` (which
// is how spread.layers is read), or an indexed collection.
//
// The order below matters. `doc.spreads` reports a numeric `length` but
// does NOT answer to `collection[i]` - indexing it yields undefined, so
// a length-first implementation silently produced an array of undefined
// entries and blew up one line later on `spread.layers`. Iteration and
// `.all` are tried before indexing for that reason, every strategy has
// to produce at least one real entry to be believed, and the result is
// filtered so a partially-indexable collection can't leak holes into
// the rest of the script.
function toArray(collection) {
  if (!collection) return [];
  if (Array.isArray(collection)) return collection;

  const nested = attempt([() => collection.all, () => collection.items]);
  if (nested && nested !== collection) {
    const unwrapped = toArray(nested);
    if (unwrapped.length) return unwrapped;
  }

  const iterated = [];
  try {
    for (const item of collection) iterated.push(item);
  } catch (e) {
    // not iterable - fall through to the indexed forms below
  }
  const cleanIterated = iterated.filter((item) => item !== undefined && item !== null);
  if (cleanIterated.length) return cleanIterated;

  const length = attempt([() => collection.length, () => collection.count]);
  if (typeof length === 'number') {
    for (const read of [
      (i) => collection[i],
      (i) => collection.get(i),
      (i) => collection.item(i),
      (i) => collection.at(i),
    ]) {
      const out = [];
      for (let i = 0; i < length; i++) {
        let item;
        try {
          item = read(i);
        } catch (e) {
          break;
        }
        if (item === undefined || item === null) break;
        out.push(item);
      }
      if (out.length === length) return out;
    }
  }

  return [];
}

function selectedNodes(doc) {
  const selection = attempt([
    () => doc.selection,
    () => doc.selectedLayers,
    () => doc.selectedNodes,
    () => app.selection,
  ]);
  return toArray(selection).filter((node) => node);
}

// spread.layers.all is the whole node tree of a spread, not just its top
// level - the same walk relink-images.js uses.
function allNodes(doc) {
  const nodes = [];
  for (const spread of toArray(doc.spreads)) {
    if (!spread) continue;
    const layers = attempt([() => spread.layers]);
    if (!layers) continue;
    for (const node of toArray(layers)) {
      if (node) nodes.push(node);
    }
  }
  return nodes;
}

/* ------------------------------------------------------------------ *
 * The split itself
 * ------------------------------------------------------------------ */

// Splits on any run of whitespace; punctuation stays attached to the
// word it's touching, which is what "separate by words" means for the
// kerning/animation work this is for.
function splitWords(text) {
  return String(text)
    .split(/\s+/)
    .filter((w) => w.length > 0);
}

function askLayout() {
  const answer = attempt([
    () =>
      app.prompt(
        'Lay the words out as a row, a column, or stacked in place?\n\n' +
          "row     - side by side, left to right (roughly where they already are)\n" +
          'column  - one per line, top to bottom\n' +
          'stack   - all at the original position, on top of each other',
        TITLE,
        'row',
      ),
  ]);
  const mode = String(answer === undefined ? 'row' : answer).trim().toLowerCase();
  if (mode === 'column' || mode === 'col') return 'column';
  if (mode === 'stack' || mode === 'none') return 'stack';
  return 'row';
}

// Places each word relative to the original frame's top-left corner.
// When a duplicate's own bounds are readable the layout advances by the
// real rendered width; otherwise it falls back to an even split of the
// original frame's width, which keeps things legible without measuring.
function layoutOffset(mode, cursor, wordBounds, fallbackStep) {
  if (mode === 'stack') return { dx: 0, dy: 0, advance: 0 };
  if (mode === 'column') {
    const step = wordBounds ? wordBounds.h * (1 + GAP_RATIO) : fallbackStep;
    return { dx: 0, dy: cursor, advance: step };
  }
  const step = wordBounds ? wordBounds.w * (1 + GAP_RATIO) : fallbackStep;
  return { dx: cursor, dy: 0, advance: step };
}

function splitFrame(doc, node, mode, report) {
  const text = readText(node);
  if (text === undefined) {
    report.failed.push("Could not read the text out of one frame (this build doesn't expose a text property this script recognises).");
    return;
  }

  const words = splitWords(text);
  if (words.length === 0) {
    report.empty += 1;
    return;
  }
  if (words.length === 1) {
    report.singleWord += 1;
    return;
  }

  const origin = readBounds(node);
  // Used only when a duplicate's own bounds can't be measured: spread
  // the words evenly across the space the original frame occupied.
  const fallbackStep = origin
    ? (mode === 'column' ? origin.h : origin.w) / words.length
    : 0;

  let cursor = 0;
  let placed = 0;

  for (const word of words) {
    const copy = duplicateNode(doc, node);
    if (!copy) {
      report.failed.push('Could not duplicate a text frame - stopped after ' + placed + ' of ' + words.length + ' word(s).');
      return;
    }
    if (!setText(copy, word)) {
      // Leave the stray duplicate out of the document rather than
      // littering it with copies of the full original text.
      removeNode(doc, copy);
      report.failed.push("Could not write the word \"" + word + "\" into a duplicated frame (this build doesn't expose a writable text property).");
      return;
    }

    const bounds = readBounds(copy);
    const step = layoutOffset(mode, cursor, bounds, fallbackStep);
    if (step.dx !== 0 || step.dy !== 0) {
      if (!translateNode(copy, step.dx, step.dy)) report.unmoved += 1;
    }
    cursor += step.advance;
    placed += 1;
  }

  // Every word landed on the same spot despite a row/column layout being
  // asked for: neither the duplicates' own bounds nor the original
  // frame's were readable, so there was no distance to advance by.
  if (mode !== 'stack' && placed > 1 && cursor === 0) report.unmeasured += placed;

  report.wordsCreated += placed;
  report.framesSplit += 1;

  // The original would otherwise sit underneath its own words.
  if (removeNode(doc, node)) report.originalsRemoved += 1;
  else if (hideNode(node)) report.originalsHidden += 1;
  else report.originalsLeft += 1;
}

function main() {
  const doc = app.documents.current;
  if (!doc) {
    app.alert('Open a document first.', TITLE);
    return;
  }

  let targets = selectedNodes(doc).filter(isTextNode);
  let usedSelection = true;
  if (targets.length === 0) {
    usedSelection = false;
    targets = allNodes(doc).filter(isTextNode);
    if (targets.length === 0) {
      app.alert(
        'Select the text frame(s) you want to split first.\n\n' +
          "Nothing is selected and this document doesn't appear to contain " +
          'any text frames this script can recognise.',
        TITLE,
      );
      return;
    }
    app.alert(
      'Nothing is selected, so all ' + targets.length + ' text frame(s) in this ' +
        'document will be split. Cancel the next dialog to stop.',
      TITLE,
    );
  }

  const mode = askLayout();

  const report = {
    framesSplit: 0,
    wordsCreated: 0,
    empty: 0,
    singleWord: 0,
    unmoved: 0,
    unmeasured: 0,
    originalsRemoved: 0,
    originalsHidden: 0,
    originalsLeft: 0,
    failed: [],
  };

  for (const node of targets) splitFrame(doc, node, mode, report);

  const lines = [
    'Text frames considered: ' + targets.length + (usedSelection ? ' (from the selection)' : ' (whole document)'),
    'Frames split: ' + report.framesSplit,
    'Word objects created: ' + report.wordsCreated,
    'Layout: ' + mode,
  ];
  if (report.singleWord) lines.push('Left alone (already a single word): ' + report.singleWord);
  if (report.empty) lines.push('Left alone (no text): ' + report.empty);
  if (report.originalsHidden) lines.push('Originals hidden (could not be deleted): ' + report.originalsHidden);
  if (report.originalsLeft) lines.push('Originals left in place (could not be deleted or hidden): ' + report.originalsLeft);
  if (report.unmoved) {
    lines.push(
      '',
      report.unmoved + ' word(s) could not be moved, so they are stacked at the ' +
        "original position - this build doesn't expose a move call this script " +
        'recognises. Use Undo if that is not what you wanted.',
    );
  }
  if (report.unmeasured) {
    lines.push(
      '',
      report.unmeasured + ' word(s) are stacked at the original position because ' +
        "this build doesn't expose readable bounds, so there was no width or " +
        'height to space them by. Use Undo if that is not what you wanted.',
    );
  }
  if (report.failed.length) lines.push('', 'Problems:', ...report.failed.map((l) => ' ✗ ' + l));

  app.alert(lines.join('\n'), TITLE);
}

try {
  main();
} catch (e) {
  // Affinity's script host doesn't reliably surface uncaught JS errors,
  // so report them ourselves - otherwise a build mismatch looks like the
  // script simply doing nothing at all.
  app.alert(
    'Split Text by Words hit an error:\n\n' + (e && e.stack ? e.stack : String(e)),
    TITLE + ' - Error',
  );
}
