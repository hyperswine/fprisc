'use strict';
// Real stdio protocol, deterministic compiler: prove save/edit/watch wiring,
// not only the scheduler's API. No test-only methods in the language server.
const assert = require('assert/strict');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn } = require('child_process');
const { pathToFileURL } = require('url');
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function until(pred, label) { const end = Date.now() + 6000; while (!pred()) { if (Date.now() > end) throw new Error(label); await sleep(20); } }

(async () => {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'fpr-lsp-saves-')));
  const file = name => path.join(dir, name), uri = name => pathToFileURL(file(name)).href;
  const write = (name, text) => { fs.mkdirSync(path.dirname(file(name)), { recursive: true }); fs.writeFileSync(file(name), text); };
  const diags = new Map(), pending = new Map(); let wire = Buffer.alloc(0), id = 0;
  let srv;
  try {
    write('core/prelude.fpr', ''); write('fpr.toml', 'manifest = 1\n');
    write('a.fpr', 'B = use "./b".\nmain = B.value.\n');
    write('b.fpr', 'C = use "./c space🙂".\nvalue = C.value.\n');
    write('c space🙂.fpr', 'value = bad.\n');
    write('u.fpr', 'V = use "./v".\nmain = V.value.\n'); write('v.fpr', 'value = 1.\n');
    write('fpr', `#!${process.execPath}
const fs=require('fs');const name=process.argv.find(a=>a.endsWith('.fpr'));
fs.appendFileSync('starts',name+'\\n');
setTimeout(()=>{if(name!=='u.fpr'&&fs.readFileSync('c space🙂.fpr','utf8').includes('bad')){
console.log('=== TYPE ERRORS ===\\n  * c space🙂.fpr:1: in value: unbound name: bad');process.exitCode=1;
}},40);
`); fs.chmodSync(file('fpr'), 0o755);
    const starts = name => fs.existsSync(file('starts')) ? fs.readFileSync(file('starts'), 'utf8').split('\n').filter(x => x === name).length : 0;
    srv = spawn(process.execPath, [path.join(__dirname, '../server/server.js')], { stdio: ['pipe', 'pipe', 'inherit'] });
    srv.stdout.on('data', chunk => {
      wire = Buffer.concat([wire, chunk]);
      for (;;) {
        const end = wire.indexOf('\r\n\r\n'); if (end < 0) return;
        const len = +/Content-Length:\s*(\d+)/i.exec(wire.subarray(0, end).toString())[1];
        if (wire.length < end + 4 + len) return;
        const message = JSON.parse(wire.subarray(end + 4, end + 4 + len)); wire = wire.subarray(end + 4 + len);
        if (message.id !== undefined && pending.has(message.id)) { pending.get(message.id)(message); pending.delete(message.id); }
        if (message.method === 'textDocument/publishDiagnostics') diags.set(message.params.uri, message.params.diagnostics);
      }
    });
    const send = obj => { const body = Buffer.from(JSON.stringify(obj)); srv.stdin.write(`Content-Length: ${body.length}\r\n\r\n`); srv.stdin.write(body); };
    const notify = (method, params) => send({ jsonrpc: '2.0', method, params });
    const request = (method, params) => new Promise((resolve, reject) => {
      const n = ++id, timer = setTimeout(() => { pending.delete(n); reject(new Error('request timeout: ' + method)); }, 6000);
      pending.set(n, m => { clearTimeout(timer); m.error ? reject(new Error(m.error.message)) : resolve(m.result); });
      send({ jsonrpc: '2.0', id: n, method, params });
    });
    const open = name => notify('textDocument/didOpen', { textDocument: { uri: uri(name), languageId: 'fpr', version: 1, text: fs.readFileSync(file(name), 'utf8') } });
    const change = (name, text) => notify('textDocument/didChange', { textDocument: { uri: uri(name), version: 2 }, contentChanges: [{ text }] });
    const save = name => notify('textDocument/didSave', { textDocument: { uri: uri(name) } });
    const compilerDiags = name => (diags.get(uri(name)) || []).filter(d => d.source === 'fpr compile');
    const init = await request('initialize', { rootUri: pathToFileURL(dir).href,
      initializationOptions: { home: dir, compilerPath: file('fpr'), check: true, unresolvedNames: false } });
    assert.equal(init.serverInfo.version, require('../package.json').version);
    for (const name of ['a.fpr', 'u.fpr', 'c space🙂.fpr']) open(name);
    await until(() => compilerDiags('c space🙂.fpr').length > 0 && starts('u.fpr') === 1, 'initial imported error');
    await sleep(200); assert.equal(compilerDiags('c space🙂.fpr').length, 1, 'duplicate reports from root/importer deduplicated');
    change('c space🙂.fpr', 'value = 2.\n');
    await until(() => compilerDiags('c space🙂.fpr').length === 0, 'unsaved edit clears imported errors');
    const count = starts('a.fpr');
    save('a.fpr'); await sleep(250); assert.equal(starts('a.fpr'), count, 'dirty transitive buffer prevents disk-only check');
    write('c space🙂.fpr', 'value = 2.\n'); save('c space🙂.fpr');
    await until(() => starts('a.fpr') === count + 1, 'transitive importer rechecked'); await sleep(200);
    assert.equal(starts('u.fpr'), 1, 'unrelated importer was not rechecked');
    for (let n = 0; n < 12; n++) save('a.fpr');
    await sleep(300); assert.equal(starts('a.fpr'), count + 1, 'unchanged saves reuse completed check');
    notify('textDocument/didClose', { textDocument: { uri: uri('c space🙂.fpr') } });
    await sleep(250); const before = starts('a.fpr');
    write('c space🙂.fpr', 'value = bad.\n');
    notify('workspace/didChangeWatchedFiles', { changes: [{ uri: uri('c space🙂.fpr'), type: 2 }] });
    await until(() => starts('a.fpr') === before + 1, 'external transitive edit'); await sleep(150);
    assert.equal(compilerDiags('c space🙂.fpr').length, 0, 'closed dependency does not retain squiggles');
    assert.equal(starts('u.fpr'), 1);
    open('c space🙂.fpr'); await until(() => compilerDiags('c space🙂.fpr').length === 1, 'reopened dependency has current diagnostics');
    await request('shutdown', null); notify('exit', null);
    await new Promise(resolve => srv.once('exit', resolve));
    console.log('check LSP: transitive save/watch selection, dirty buffers, deduplication, cached saves, close/reopen and clean shutdown PASS');
  } finally {
    if (srv && srv.exitCode === null) { srv.stdin.end(); await sleep(1200); if (srv.exitCode === null) srv.kill(); }
    fs.rmSync(dir, { recursive: true, force: true });
  }
})().catch(e => { console.error(e); process.exitCode = 1; });
