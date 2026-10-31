'use strict';
const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');
const { digest, parseRemarks, diagnostics, createRemarkRunner } = require('../server/optimization-remarks');
const ROOT = path.resolve(__dirname, '..');
const FPR = path.resolve(ROOT, '..');
function until(dir, predicate, timeout = 10000) {
  return new Promise((resolve, reject) => {
    const finish = () => { if (predicate()) { watcher.close(); clearTimeout(timer); resolve(); } };
    const watcher = fs.watch(dir, finish);
    const timer = setTimeout(() => { watcher.close(); reject(new Error('Timed out waiting for compiler/watch event')); }, timeout);
    finish();
  });
}
(async () => {
  const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'fpr-remark-tests-')));
  const root = path.join(tmp, 'module.fpr'), dep = path.join(tmp, 'dep.fpr');
  const runners = [];
  const buffers = new Map(); let published = new Map(), invalidations = 0;
  const make = compilerPath => { const runner = createRemarkRunner({ settings: () => ({ home: FPR, compilerPath, checkArgs: ['--system=posix'] }),
    workspaceRoot: () => tmp, readOpen: f => buffers.has(f) ? buffers.get(f) : null,
    onResult: value => { published = value; }, onInvalidated: () => { invalidations++; } }); runners.push(runner); return runner; };
  try {
    fs.writeFileSync(root, '🙂call\n'); fs.writeFileSync(dep, 'value = 1.\n');
    const record = { remarkVersion: 1, positionEncoding: 'utf-32', kind: 'inline', outcome: 'declined', owner: 'run',
      file: root, start: { line: 0, character: 1 }, end: { line: 0, character: 5 }, precision: 'span', message: 'not inlined' };
    const manifest = { remarkInputsVersion: 1, algorithm: 'fnv1a-64-utf8', files: [{ file: root, digest: digest(fs.readFileSync(root)) }] };
    const parsed = parseRemarks(JSON.stringify(manifest) + '\n' + JSON.stringify(record), tmp);
    const d = diagnostics(parsed.records, f => fs.readFileSync(f, 'utf8')).get(root)[0];
    assert.deepStrictEqual(d.range, { start: { line: 0, character: 2 }, end: { line: 0, character: 6 } });
    assert.strictEqual(d.severity, 3);
    assert.throws(() => parseRemarks(JSON.stringify(record), tmp), /source snapshots/);
    assert.throws(() => parseRemarks(JSON.stringify({ ...manifest, remarkInputsVersion: 2 }), tmp), /Unsupported/);
    console.log('remark parser: versioned inputs, UTF-32 to UTF-16 and information severity PASS');

    const fake = path.join(tmp, 'compiler'), ready = path.join(tmp, 'ready'), release = path.join(tmp, 'release');
    fs.writeFileSync(fake, `#!${process.execPath}\nconst fs=require('fs');const {digest}=require(${JSON.stringify(path.join(ROOT, 'server/optimization-remarks'))});
const files=${JSON.stringify([root, dep])};const records=files.map(file=>({file,digest:digest(fs.readFileSync(file))}));
const output=process.argv.at(-1);const watcher=fs.watch(${JSON.stringify(tmp)},()=>{if(fs.existsSync(${JSON.stringify(release)})){
 watcher.close();console.error(JSON.stringify({remarkInputsVersion:1,algorithm:'fnv1a-64-utf8',files:records}));
 console.error(JSON.stringify(${JSON.stringify({ ...record, start: { line: 0, character: 0 }, end: null, precision: 'definition' })}));process.exit(0);}});
fs.writeFileSync(${JSON.stringify(ready)},output);\n`);
    fs.chmodSync(fake, 0o755);
    const runner = make(fake);
    const start = () => {
      for (const f of [ready, release]) { try { fs.unlinkSync(f); } catch (_) { /* absent */ } }
      return runner.run(root);
    };
    buffers.set(root, 'unsaved');
    assert.strictEqual((await runner.run(root)).status, 'error'); buffers.clear();
    const first = start(); await until(tmp, () => fs.existsSync(ready));
    const second = start(); assert.strictEqual((await first).status, 'cancelled');
    await until(tmp, () => fs.existsSync(ready)); fs.writeFileSync(release, 'ok');
    assert.strictEqual((await second).status, 'ok'); assert(published.has(root));
    const outputDirectory = path.dirname(fs.readFileSync(ready, 'utf8'));
    const invalidated = until(tmp, () => invalidations > 0);
    fs.writeFileSync(dep, 'value = 2.\n'); await invalidated;
    assert.strictEqual(published.size, 0);
    const stale = start(); await until(tmp, () => fs.existsSync(ready));
    fs.writeFileSync(dep, 'value = 3.\n'); fs.writeFileSync(release, 'ok');
    assert.strictEqual((await stale).status, 'stale'); assert.strictEqual(published.size, 0);
    const dirty = start(); await until(tmp, () => fs.existsSync(ready)); buffers.set(dep, 'unsaved dependency');
    fs.writeFileSync(release, 'ok'); assert.strictEqual((await dirty).status, 'stale'); buffers.clear();
    const cancelled = start(); await until(tmp, () => fs.existsSync(ready)); runner.invalidate('editor changed');
    assert.strictEqual((await cancelled).status, 'cancelled');
    await runner.dispose(); assert(!fs.existsSync(outputDirectory));
    console.log('remark runner: supersession, cancellation, dirty buffers, changing dependencies, external invalidation and scratch cleanup PASS');

    // Exercise the actual LSP dispatch, with automatic checks disabled.
    const srv = spawn(process.execPath, [path.join(ROOT, 'server/server.js')], { stdio: ['pipe', 'pipe', 'inherit'] });
    let wire = Buffer.alloc(0), nextId = 1; const pending = new Map(), seen = new Map();
    srv.stdout.on('data', chunk => {
      wire = Buffer.concat([wire, chunk]);
      while (true) {
        const header = wire.indexOf('\r\n\r\n'); if (header < 0) return;
        const length = +wire.subarray(0, header).toString().match(/Content-Length: (\d+)/i)[1];
        if (wire.length < header + 4 + length) return;
        const msg = JSON.parse(wire.subarray(header + 4, header + 4 + length)); wire = wire.subarray(header + 4 + length);
        if (pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
        if (msg.method === 'textDocument/publishDiagnostics') seen.set(msg.params.uri, msg.params.diagnostics);
      }
    });
    const send = message => { const body = Buffer.from(JSON.stringify({ jsonrpc: '2.0', ...message })); srv.stdin.write(`Content-Length: ${body.length}\r\n\r\n`); srv.stdin.write(body); };
    const request = (method, params) => new Promise(resolve => { const id = nextId++; pending.set(id, resolve); send({ id, method, params }); });
    const notify = (method, params) => send({ method, params });
    const uri = require('url').pathToFileURL(root).href;
    try {
      for (const file of [ready, release]) { try { fs.unlinkSync(file); } catch (_) {} }
      await request('initialize', { rootUri: require('url').pathToFileURL(tmp).href,
        initializationOptions: { home: FPR, compilerPath: fake, check: false } });
      notify('textDocument/didOpen', { textDocument: { uri, languageId: 'fpr', version: 1, text: fs.readFileSync(root, 'utf8') } });
      await request('textDocument/documentSymbol', { textDocument: { uri } });
      assert(!fs.existsSync(ready), 'opening a file started remark compilation');
      const response = request('fpr/optimizationRemarks', { uri });
      await until(tmp, () => fs.existsSync(ready)); fs.writeFileSync(release, 'ok');
      assert.strictEqual((await response).result.status, 'ok');
      assert(seen.get(uri).some(d => d.source === 'fpr optimization' && d.severity === 3));
      notify('textDocument/didChange', { textDocument: { uri, version: 2 }, contentChanges: [{ text: 'changed buffer' }] });
      await request('textDocument/documentSymbol', { textDocument: { uri } });
      assert(!seen.get(uri).some(d => d.source === 'fpr optimization'));
      await request('shutdown', null); notify('exit', null);
      console.log('remark LSP: explicit request, no automatic emission, information diagnostics and edit invalidation PASS');
    } finally { srv.kill(); }

    fs.writeFileSync(root, 'unsafe base.\napply f x = f x.\ninc x = x + 1.\nrun n = apply inc n.\n');
    const foreignDir = path.join(tmp, 'foreign'); fs.mkdirSync(foreignDir);
    const foreign = path.join(foreignDir, 'host.fpr'); fs.writeFileSync(foreign, 'Host.value : Int -> Int.\n');
    const previousForeign = process.env.FPR_FOREIGN; process.env.FPR_FOREIGN = foreign;
    const real = make(path.join(FPR, 'fpr'));
    const result = await real.run(root);
    assert.strictEqual(result.status, 'ok', result.message);
    assert(result.records.some(r => ['inline', 'generic-call'].includes(r.kind)));
    assert(published.has(root));
    const beforeForeignChange = invalidations;
    const changed = until(foreignDir, () => invalidations > beforeForeignChange);
    fs.writeFileSync(foreign, 'Host.value : Int -> Int.\n# changed declaration source\n'); await changed;
    assert.strictEqual(published.size, 0);
    if (previousForeign === undefined) delete process.env.FPR_FOREIGN; else process.env.FPR_FOREIGN = previousForeign;
    await real.dispose();
    console.log('remark runner: actual compiler, no-main native module, source fingerprints and located decisions PASS');
  } finally { await Promise.allSettled(runners.map(r => r.dispose())); fs.rmSync(tmp, { recursive: true, force: true }); }
})().catch(e => { console.error(e); process.exitCode = 1; });
