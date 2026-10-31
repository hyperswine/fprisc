'use strict';
const fs = require('fs');
const path = require('path');
const { pathToFileURL } = require('url');
const SKIP = new Set(['node_modules', 'build', 'dist', 'dist-newstyle', 'out']);
const inside = (root, file) => { const rel = path.relative(root, file); return !rel.startsWith('..' + path.sep) && rel !== '..' && !path.isAbsolute(rel); };
function createIndex({ analyze, limit = 5000, maxBytes = 1024 * 1024, onLimit = () => {} }) {
  let roots = [], generation = 0, ready = Promise.resolve(), truncated = false;
  const entries = new Map(), overlays = new Map();
  const eligible = file => /\.(fpr|sol)$/.test(file) && roots.some(root => inside(root, file) &&
    !path.relative(root, file).split(path.sep).some(p => p.startsWith('.') || SKIP.has(p)));
  const decls = (file, text) => analyze(pathToFileURL(file).href, text).decls.filter(d => d.name !== '>');
  function update(file) {
    if (!eligible(file)) return;
    try {
      const st = fs.lstatSync(file);
      if (!st.isFile() || st.size > maxBytes) { entries.delete(file); return; }
      if (!entries.has(file) && entries.size >= limit) { if (!truncated) onLimit(limit); truncated = true; return; }
      entries.set(file, decls(file, fs.readFileSync(file, 'utf8')));
    } catch (_) { entries.delete(file); }
  }
  function setRoots(next) {
    roots = [...new Set(next.filter(Boolean).map(r => path.resolve(r)))];
    const mine = ++generation; entries.clear(); truncated = false;
    ready = (async () => {
      let visited = 0;
      const walk = async dir => {
        if (mine !== generation || truncated) return;
        let children;
        try { children = await fs.promises.readdir(dir, { withFileTypes: true }); } catch (_) { return; }
        for (const child of children.sort((a, b) => a.name.localeCompare(b.name))) {
          if (mine !== generation || truncated) return;
          if (child.name.startsWith('.') || SKIP.has(child.name)) continue;
          const file = path.join(dir, child.name);
          if (child.isDirectory()) await walk(file);
          else if (child.isFile() && eligible(file)) update(file);
          if (++visited % 64 === 0) await new Promise(r => setImmediate(r));
        }
      };
      for (const root of roots) await walk(root);
    })();
    return ready;
  }
  function overlay(file, text) { if (text === null) { overlays.delete(file); update(file); } else overlays.set(file, decls(file, text)); }
  async function symbols(query) {
    // Await the current generation even if roots change during the scan.
    for (;;) { const pending = ready; await pending; if (pending === ready) break; }
    const q = (query || '').toLowerCase(), out = [];
    for (const [file, ds] of new Map([...entries, ...overlays])) {
      if (!eligible(file)) continue;
      for (const d of ds) {
        if (q && !d.name.toLowerCase().includes(q)) continue;
        const col = d.col || 0;
        out.push({ name: d.name, kind: d.kind, containerName: path.relative(roots.find(r => inside(r, file)), file),
          location: { uri: pathToFileURL(file).href, range: { start: { line: d.line, character: col }, end: { line: d.line, character: col + d.name.length } } } });
        if (out.length >= 500) return out;
      }
    }
    return out;
  }
  return { setRoots, update, overlay, symbols };
}
module.exports = { createIndex };
