'use strict';
const assert = require('assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { createIndex } = require('../server/workspace-index');
(async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fpr-index-'));
  let scans = 0, notices = 0;
  const analyze = (_uri, text) => { scans++; return { decls: [{ name: text.trim(), kind: 13, line: 0 }] }; };
  try {
    const a = path.join(dir, 'one'), b = path.join(dir, 'two'); fs.mkdirSync(a); fs.mkdirSync(b);
    const f = path.join(a, 'space🙂.fpr'); fs.writeFileSync(f, 'alpha'); fs.writeFileSync(path.join(b, 'b.sol'), 'beta');
    fs.mkdirSync(path.join(a, 'node_modules')); fs.writeFileSync(path.join(a, 'node_modules', 'skip.fpr'), 'hidden');
    fs.symlinkSync(a, path.join(a, 'cycle'));
    const index = createIndex({ analyze }); await index.setRoots([a, b]);
    const first = await index.symbols(''); assert.deepEqual(first.map(s => s.name).sort(), ['alpha', 'beta']);
    assert(first.some(s => s.location.uri.includes('%F0%9F%99%82')));
    const initial = scans; for (let i = 0; i < 25; i++) await index.symbols('a');
    assert.equal(scans, initial, 'queries do not rescan or reparse the workspace');
    const stat = fs.statSync(f); fs.writeFileSync(f, 'gamma'); fs.utimesSync(f, stat.atime, stat.mtime); index.update(f);
    assert.equal((await index.symbols('gamma')).length, 1, 'events invalidate even with restored mtime');
    index.overlay(f, 'dirty'); index.update(f); assert.equal((await index.symbols('dirty')).length, 1);
    index.overlay(f, null); assert.equal((await index.symbols('gamma')).length, 1);
    fs.unlinkSync(f); index.update(f); assert.equal((await index.symbols('gamma')).length, 0);
    fs.writeFileSync(f, 'created'); index.update(f); assert.equal((await index.symbols('created')).length, 1);
    await index.setRoots([b]); assert.deepEqual((await index.symbols('')).map(s => s.name), ['beta']);
    const bounded = createIndex({ analyze, limit: 1, onLimit: () => notices++ }); await bounded.setRoots([a, b]);
    assert.equal((await bounded.symbols('')).length, 1); assert.equal(notices, 1);
    console.log(`workspace index: multi-root, encoded URIs, unsaved overlays, create/change/delete, same-mtime refresh, symlink/ignored dirs, cap; 25 queries -> 0 additional parses PASS`);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
})().catch(e => { console.error(e); process.exitCode = 1; });
