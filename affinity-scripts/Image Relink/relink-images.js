/**
 * name: Relink Images
 * description: Finds linked images in the active document that are missing or moved, and relinks them to their current location on disk.
 * version: 1.0.0
 */

'use strict';

const { app } = require('/application');
const { FileSystemApi } = require('/fs');

// imageResourceInterface.imagePlacement.value === 1 means the image is
// linked (as opposed to embedded) - see the "RGB Finder" community script.
const LINKED = 1;

function collectLinkedImages(doc) {
  const images = [];
  for (const spread of doc.spreads) {
    for (const node of spread.layers.all) {
      if (!node.isImageNode) continue;
      let iri;
      try {
        iri = node.imageResourceInterface;
      } catch (e) {
        continue;
      }
      if (!iri || iri.imagePlacement.value !== LINKED) continue;
      images.push({ node, iri, path: iri.imageFilePath });
    }
  }
  return images;
}

function fileName(path) {
  return String(path || '').split(/[\\/]/).pop();
}

function folderOf(path) {
  const i = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
  return i >= 0 ? path.slice(0, i) : '';
}

function extensionFilter(path) {
  const ext = fileName(path).split('.').pop();
  if (!ext) return 'All Files|*.*';
  return 'Matching Files|*.' + ext + '|All Files|*.*';
}

// FileSystemApi.exists() throws PERMISSION_DENIED for paths the script
// hasn't been granted access to - which includes every path read straight
// out of the document's link metadata, since the user never chose it via
// a native dialog. Treat "can't tell" the same as "missing" (true only on
// a confirmed, permitted check) rather than letting it crash the script.
function canConfirmExists(path) {
  try {
    return FileSystemApi.exists(path);
  } catch (e) {
    return false;
  }
}

// Best-effort write-back: the scripting SDK confirms imageFilePath as a
// readable property (used by community scripts) but does not document a
// public setter. Try the direct assignment and fail gracefully so a
// version where this is read-only doesn't crash the whole batch - the
// user falls back to Resource Manager > Relink for those files.
function tryRelink(iri, newPath) {
  try {
    iri.imageFilePath = newPath;
    return true;
  } catch (e) {
    return false;
  }
}

function main() {
  const doc = app.documents.current;
  if (!doc) {
    app.alert('Open a document first.', 'Relink Images');
    return;
  }

  const images = collectLinkedImages(doc);
  if (images.length === 0) {
    app.alert('This document has no linked images.', 'Relink Images');
    return;
  }

  const missing = images.filter((img) => !canConfirmExists(img.path));
  if (missing.length === 0) {
    app.alert(
      'All ' + images.length + ' linked image(s) already point to a valid file.',
      'Relink Images',
    );
    return;
  }

  app.alert(
    "Affinity's scripting sandbox won't let this script silently check " +
      'whether a linked file still exists at its recorded path, so it ' +
      "can't tell which of the " + missing.length + ' linked image(s) below ' +
      'actually need fixing. You will be asked to locate each one - click ' +
      'Cancel in the file picker for any that are already fine.',
    'Relink Images',
  );

  // Once the user picks a corrected folder for one missing file, try that
  // same folder (matched by file name) for the rest before asking again.
  let knownFolder = null;
  const relinked = [];
  const skipped = [];
  const failed = [];

  for (const img of missing) {
    const name = fileName(img.path);
    let candidate = null;

    if (knownFolder) {
      const guess = knownFolder + '/' + name;
      if (canConfirmExists(guess)) candidate = guess;
    }

    if (!candidate) {
      const picked = FileSystemApi.getOpenFileName(extensionFilter(img.path));
      if (!picked) {
        skipped.push(name);
        continue;
      }
      candidate = picked;
      knownFolder = folderOf(candidate);
    }

    if (tryRelink(img.iri, candidate)) {
      relinked.push(name + '  ->  ' + candidate);
    } else {
      failed.push(name + '  (this Affinity build would not accept the new path - use Resource Manager > Relink)');
    }
  }

  const lines = [
    'Linked images checked: ' + images.length,
    "Couldn't confirm (offered for review): " + missing.length,
    'Relinked: ' + relinked.length,
    'Skipped: ' + skipped.length,
    'Failed: ' + failed.length,
    '',
  ];
  if (relinked.length) lines.push('Relinked:', ...relinked.map((l) => ' ✓ ' + l), '');
  if (skipped.length) lines.push('Skipped (no file chosen):', ...skipped.map((l) => ' - ' + l), '');
  if (failed.length) lines.push('Could not relink:', ...failed.map((l) => ' ✗ ' + l));

  app.alert(lines.join('\n'), 'Relink Images');
}

try {
  main();
} catch (e) {
  // Surface failures instead of letting them fail silently - this API is
  // undocumented, so if a call doesn't match your Affinity version this
  // is the fastest way to see which one.
  app.alert(
    'Relink Images hit an error:\n\n' + (e && e.stack ? e.stack : String(e)),
    'Relink Images - Error',
  );
}
