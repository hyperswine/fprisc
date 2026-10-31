'use strict';
const assert = require('assert/strict');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { createChecker } = require('../server/compiler-check');
const { digest } = require('../server/editor-report');
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function until(pred, label) { const end = Date.now() + 7000; while (!pred()) { if (Date.now() > end) throw new Error(label); await sleep(15); } }
(async () => {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'fpr-metadata-')));
  const file = name => path.join(dir, name), write = (name, body) => fs.writeFileSync(file(name), body);
  const open = new Map(); let result, events = 0, checker;
  try {
    fs.mkdirSync(file('core')); write('core/prelude.fpr', ''); write('root.fpr', 'value = 1.\n'); write('hidden.fpr', 'metadataOnly = 1.\n');
    write('compiler', `#!${process.execPath}
const fs=require('fs'),path=require('path');
const digest=${digest.toString()};
fs.appendFileSync('calls','run\\n');
const inputs=['root.fpr','hidden.fpr'].map(n=>({file:path.resolve(n),digest:digest(fs.readFileSync(n,'utf8'))}));
console.error(JSON.stringify({editorVersion:1,positionEncoding:'utf-32',algorithm:'fnv1a-64-utf8',root:path.resolve('root.fpr'),ok:true,inputs,diagnostics:[],types:[{file:path.resolve('root.fpr'),name:'value',type:'Int',start:{line:0,character:0}}]}));
`); fs.chmodSync(file('compiler'), 0o755);
    const count = () => fs.existsSync(file('calls')) ? fs.readFileSync(file('calls'), 'utf8').trim().split('\n').length : 0;
    checker = createChecker({ settings: () => ({ home: dir, compilerPath: file('compiler') }), workspaceRoot: () => dir,
      readText: p => { try { return fs.readFileSync(p, 'utf8'); } catch (_) { return null; } }, readOpen: p => open.get(p) ?? null,
      onMissing: (_c, e) => { throw e; }, onResult: (_f, r) => { result = r; if (r) events++; }, delay: 0 });
    checker.check(file('root.fpr')); await until(() => events === 1, 'first report');
    assert(result.editor.types.length); assert(checker.affected(file('hidden.fpr')).includes(file('root.fpr')));
    checker.check(file('root.fpr')); await until(() => events === 2, 'cached report'); assert.equal(count(), 1);
    const old = fs.statSync(file('hidden.fpr')); write('hidden.fpr', 'metadataOnly = 2.\n'); fs.utimesSync(file('hidden.fpr'), old.atime, old.mtime);
    checker.invalidate(file('hidden.fpr')); checker.check(file('root.fpr')); await until(() => events === 3, 'manifest dependency invalidated'); assert.equal(count(), 2);
    open.set(file('hidden.fpr'), 'dirty'); checker.invalidate(file('hidden.fpr')); checker.check(file('root.fpr')); await sleep(80); assert.equal(result, null); assert.equal(count(), 2);
    await checker.dispose(); open.clear(); events = 0;
    write('calls', '');
    write('compiler', `#!${process.execPath}
const fs=require('fs');fs.appendFileSync('calls','run\\n');
if(process.argv.includes('--editor-json')) {console.log('usage: fprc <in.fpr> <out.s>');process.exitCode=1;}
else console.log('=== TYPE ERRORS ===\\n  * root.fpr:1: in value: legacy error');
`); fs.chmodSync(file('compiler'), 0o755);
    checker = createChecker({ settings: () => ({ home: dir, compilerPath: file('compiler') }), workspaceRoot: () => dir,
      readText: p => { try { return fs.readFileSync(p, 'utf8'); } catch (_) { return null; } },
      onMissing: (_c, e) => { throw e; }, onResult: (_f, r) => { result = r; if (r) events++; }, delay: 0 });
    checker.check(file('root.fpr')); await until(() => events === 1, 'legacy fallback');
    assert(result.get(file('root.fpr')).some(d => d.message.includes('legacy error'))); assert.equal(count(), 2);
    console.log('editor metadata: compiler-only dependencies, reuse, restored-mtime invalidation, dirty dependency suppression, older-compiler fallback PASS');
  } finally { if (checker) await checker.dispose(); fs.rmSync(dir, { recursive: true, force: true }); }
})().catch(e => { console.error(e); process.exitCode = 1; });
