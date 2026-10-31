'use strict';
const assert = require('assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn, spawnSync } = require('child_process');
const { pathToFileURL } = require('url');
const { readReport, digest } = require('../server/editor-report');
const home = path.resolve(__dirname, '../..');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fpr-editor-features-'));
const file = name => path.join(dir, name), uri = name => pathToFileURL(file(name)).href;
const write = (name, text) => fs.writeFileSync(file(name), text);
const sleep = ms => new Promise(r => setTimeout(r, ms));
const disk = p => { try { return fs.readFileSync(p, 'utf8'); } catch (_) { return null; } };
function compile(name, editor = true) {
  const sol = name.endsWith('.sol');
  const args = ['compile', ...(sol ? ['--target=bytecode'] : ['--system=posix', '--check-only']),
    ...(editor ? ['--editor-json'] : []), file(name), ...(sol ? [] : [file('must-not-exist.s')])];
  return spawnSync(path.join(home, 'fpr'), args, { encoding: 'utf8', env: { ...process.env, FPR_HOME: home }, timeout: 15000 });
}
function report(result) { return readReport(result.stdout + '\n' + result.stderr, { readText: disk, readOpen: () => null, failed: result.status !== 0 }); }
let srv;
(async () => {
  for (const ext of ['fpr', 'sol']) {
    write('dep.' + ext, 'value = 41.\n');
    write('root.' + ext, 'M = use "./dep".\nanswer = M.value + 1.\nidentity x = x.\n' + (ext === 'sol' ? '> print "MUST NOT EXECUTE".\n' : ''));
    const checked = compile('root.' + ext), parsed = report(checked);
    assert.equal(checked.status, 0, checked.stderr + checked.stdout);
    assert(parsed.report.ok);
    assert(parsed.report.inputs.some(i => i.file.endsWith('/dep.' + ext)));
    assert(parsed.report.types.some(t => t.name === 'answer' && t.type === 'Int'));
    assert(parsed.report.types.some(t => t.name === 'identity' && t.type.includes('->')));
    assert(!checked.stdout.includes('MUST NOT EXECUTE'));
    assert(!fs.existsSync(file('must-not-exist.s')));
    for (const source of ['broken = missing.\n', 'loop x = loop (x + 1).\n', 'broken = (1 + ).\n', 'broken = ?todo.\n']) {
      write('bad.' + ext, source);
      const a = compile('bad.' + ext), b = compile('bad.' + ext, false), r = report(a).report;
      assert.equal(a.status, b.status, 'editor checking preserves failure behavior');
      assert.notEqual(a.status, 0); assert(r.diagnostics.length); assert.deepEqual(r.types, []);
    }
    write('dep.' + ext, 'value = 42.\n');
    assert.equal(report(checked).stale, true, 'consumed-source change rejects old report');
  }
  write('arguments.sol', '> print "SCRIPT DID EXECUTE".\n');
  const argumentRun = spawnSync(path.join(home, 'fpr'), ['sol', file('arguments.sol'), '--editor-json'], { encoding: 'utf8', timeout: 15000 });
  assert.equal(argumentRun.status, 0, argumentRun.stderr);
  assert(argumentRun.stdout.includes('SCRIPT DID EXECUTE'), 'editor option after script path remains a script argument');
  assert(!argumentRun.stderr.includes('"editorVersion"'));
  assert.throws(() => readReport('{"editorVersion":9}', { readText: disk, readOpen: () => null, failed: false }), /Unsupported/);
  console.log('editor report: native/Sol diagnostics, actual dependencies, inferred types, no execution/output, stale rejection PASS');

  const pending = new Map(), diagnostics = new Map(); let buffer = Buffer.alloc(0), id = 0;
  srv = spawn(process.execPath, [path.join(__dirname, '../server/server.js')], { stdio: ['pipe', 'pipe', 'inherit'] });
  srv.stdout.on('data', chunk => {
    buffer = Buffer.concat([buffer, chunk]);
    for (;;) {
      const end = buffer.indexOf('\r\n\r\n'); if (end < 0) return;
      const size = +/Content-Length:\s*(\d+)/i.exec(buffer.subarray(0, end).toString())[1];
      if (buffer.length < end + 4 + size) return;
      const msg = JSON.parse(buffer.subarray(end + 4, end + 4 + size)); buffer = buffer.subarray(end + 4 + size);
      if (pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
      if (msg.method === 'textDocument/publishDiagnostics') diagnostics.set(msg.params.uri, msg.params.diagnostics);
    }
  });
  const send = (method, params, requestId) => { const b = Buffer.from(JSON.stringify({ jsonrpc: '2.0', id: requestId, method, params })); srv.stdin.write(`Content-Length: ${b.length}\r\n\r\n`); srv.stdin.write(b); };
  const request = (method, params) => new Promise((resolve, reject) => { const n = ++id, timer = setTimeout(() => reject(new Error('timeout: ' + method)), 10000); pending.set(n, msg => { clearTimeout(timer); msg.error ? reject(new Error(msg.error.message)) : resolve(msg.result); }); send(method, params, n); });
  const ask = (method, name, line, character) => request('textDocument/' + method, { textDocument: { uri: uri(name) }, position: { line, character } });
  const open = name => send('textDocument/didOpen', { textDocument: { uri: uri(name), version: 1, languageId: name.endsWith('.sol') ? 'sol' : 'fpr', text: disk(file(name)) } });
  const change = (name, text) => send('textDocument/didChange', { textDocument: { uri: uri(name), version: 2 }, contentChanges: [{ text }] });
  const hover = async (name, line, character) => ((await ask('hover', name, line, character)) || {}).contents?.value || '';
  async function until(pred, label) { const deadline = Date.now() + 10000; while (!await pred()) { if (Date.now() > deadline) throw new Error(label); await sleep(30); } }
  await request('initialize', { rootUri: pathToFileURL(dir).href, initializationOptions: { home, check: true } });
  for (const ext of ['fpr', 'sol']) {
    const name = 'root.' + ext;
    open(name);
    await until(async () => (await hover(name, 1, 2)).includes('answer : Int'), ext + ' inferred hover');
    assert((await hover(name, 1, 13)).includes('M.value : Int'), ext + ' imported inferred hover');
    change(name, disk(file(name)) + '\n# edit\n');
    assert(!(await hover(name, 1, 2)).includes('answer : Int'), 'dirty buffer clears inferred type');
    change(name, disk(file(name))); send('textDocument/didSave', { textDocument: { uri: uri(name) } });
    await until(async () => (await hover(name, 1, 2)).includes('answer : Int'), ext + ' fresh hover returns');
    open('dep.' + ext); change('dep.' + ext, 'value = "changed".\n');
    assert(!(await hover(name, 1, 2)).includes('answer : Int'), 'dirty dependency clears importer types');
    send('textDocument/didClose', { textDocument: { uri: uri('dep.' + ext) } });
  }
  // The source scanner must retain complete names even while a file is being
  // edited into a definition the selected toolchain may not yet support.
  send('workspace/didChangeConfiguration', { settings: { fpr: { home, check: false } } });
  write('dotted.fpr', 'mymod.x = 1.\nmymod.deep.id x = x.\ncopy = mymod.x.\nother = mymod.deep.id 2.\n'); open('dotted.fpr');
  assert.equal((await ask('definition', 'dotted.fpr', 2, 13)).range.start.line, 0);
  assert((await hover('dotted.fpr', 2, 13)).includes('mymod.x = 1'));
  write('shadow.fpr', 'value = 1.\nuseValue value = value.\nmymod.x = 2.\nrecord mymod = mymod.x.\n'); open('shadow.fpr');
  assert.equal(await hover('shadow.fpr', 1, 18), '', 'a parameter must not borrow a global type');
  assert.equal(await hover('shadow.fpr', 3, 22), '', 'a local record must not borrow a namespace member');
  assert((await ask('completion', 'dotted.fpr', 3, 19)).some(c => c.label === 'id'));
  assert.equal((await ask('definition', 'dotted.fpr', 3, 20)).range.start.line, 1);
  assert(!(diagnostics.get(uri('dotted.fpr')) || []).some(d => d.code === 'unresolved-name' && /mymod|deep|\bx\b|\bid\b/.test(d.message)));
  const indexed = await request('workspace/symbol', { query: 'mymod' });
  assert(indexed.some(s => s.name === 'mymod.deep.id'));
  change('dotted.fpr', 'unsavedSymbol = 2.\n');
  assert((await request('workspace/symbol', { query: 'unsavedSymbol' })).length === 1);
  assert(!(await request('workspace/symbol', { query: 'mymod' })).some(s => s.location.uri === uri('dotted.fpr')));
  await request('shutdown', null); send('exit', null);
  console.log('editor LSP: inferred native/Sol and imported hovers, dirty source/dependency suppression, dotted definitions/navigation/completion, unsaved workspace symbols PASS');
})().catch(e => { console.error(e); process.exitCode = 1; }).finally(async () => { if (srv && srv.exitCode === null) { srv.stdin.end(); await sleep(200); if (srv.exitCode === null) srv.kill(); } fs.rmSync(dir, { recursive: true, force: true }); });
