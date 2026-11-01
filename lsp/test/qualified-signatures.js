'use strict';
const assert = require('assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { pathToFileURL } = require('url');
const { spawn, spawnSync } = require('child_process');
const home = path.resolve(__dirname, '../..');
const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'fpr-qualified-')));
const file = name => path.join(dir, name), uri = name => pathToFileURL(file(name)).href;
const write = (name, text) => fs.writeFileSync(file(name), text);
let server;
(async () => {
  // Check the language contract with the real compiler, without needing a
  // runtime implementation of these deliberately external symbols.
  for (const ext of ['fpr', 'sol']) {
    write('foreign.' + ext, '# Host value\nMyMod.x : I64.\n# Host operation\nMyMod.deep.get :\n  I64 -> I64.\n');
    write('bridge.' + ext, 'Foreign = use "./foreign".\n');
    const ref = ext === 'fpr' ? 'MyMod' : 'Bridge.Foreign.MyMod';
    write('consumer.' + ext, `Bridge = use "./bridge".\ncopy = ${ref}.x.\ncall = ${ref}.deep.get ${ref}.x.\n`);
    const args = ['compile', '--editor-json', ...(ext === 'sol' ? ['--target=bytecode'] : ['--system=posix']), file('consumer.' + ext), ...(ext === 'sol' ? [] : [file('out.s')])];
    const r = spawnSync(path.join(home, 'fpr'), args, { encoding: 'utf8', env: { ...process.env, FPR_HOME: home }, timeout: 15000 });
    assert.equal(r.status, 0, r.stdout + r.stderr);
    const report = JSON.parse(r.stderr.split('\n').find(l => l.startsWith('{"editorVersion"')));
    assert(report.types.some(t => t.name === 'copy' && t.type === 'I64'));
  }
  const pending = new Map(), diagnostics = new Map(); let buffer = Buffer.alloc(0), next = 0;
  server = spawn(process.execPath, [path.join(__dirname, '../server/server.js')], { stdio: ['pipe', 'pipe', 'inherit'] });
  server.stdout.on('data', chunk => {
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
  const send = (method, params, id) => { const body = Buffer.from(JSON.stringify({ jsonrpc: '2.0', id, method, params })); server.stdin.write(`Content-Length: ${body.length}\r\n\r\n`); server.stdin.write(body); };
  const request = (method, params) => new Promise((resolve, reject) => { const id = ++next, timer = setTimeout(() => reject(new Error(method + ' timed out')), 10000); pending.set(id, msg => { clearTimeout(timer); msg.error ? reject(new Error(msg.error.message)) : resolve(msg.result); }); send(method, params, id); });
  const ask = (method, name, line = 0, character = 0) => request('textDocument/' + method, { textDocument: { uri: uri(name) }, position: { line, character } });
  const open = name => send('textDocument/didOpen', { textDocument: { uri: uri(name), languageId: name.endsWith('.sol') ? 'sol' : 'fpr', version: 1, text: fs.readFileSync(file(name), 'utf8') } });
  const change = (name, text) => send('textDocument/didChange', { textDocument: { uri: uri(name), version: 2 }, contentChanges: [{ text }] });
  await request('initialize', { rootUri: pathToFileURL(dir).href, initializationOptions: { home, check: false } });
  for (const ext of ['fpr', 'sol']) {
    const own = 'local.' + ext;
    write(own, '# Host value\nMyMod.x : I64.\nMyMod.deep.get :\n  I64 -> I64.\ncopy = MyMod.x.\ncall = MyMod.deep.get MyMod.x.\nSys.memInfo : I64.\ninfo = Sys.memInfo.\nx = 123.\nwrong = Unknown.x.\n'); open(own);
    let hover = await ask('hover', own, 4, 13); assert(hover.contents.value.includes('MyMod.x : I64.')); assert(hover.contents.value.includes('Host value'));
    const definition = await ask('definition', own, 4, 13), declaration = await ask('declaration', own, 4, 13);
    assert.equal(definition.uri, uri(own)); assert.equal(definition.range.start.line, 1); assert.deepEqual(declaration, definition);
    hover = await ask('hover', own, 5, 19); assert(hover.contents.value.includes('I64 -> I64'), 'multiline signature is complete in hover');
    const outline = await ask('documentSymbol', own), sig = outline.find(s => s.name === 'MyMod.deep.get');
    assert.equal(sig.kind, 12, 'multiline arrow signature is a function'); assert.equal(sig.range.end.line, 3);
    let completion = await ask('completion', own, 5, 18); assert(completion.some(c => c.label === 'get' && c.detail.includes('I64 -> I64')));
    completion = await ask('completion', own, 7, 11); assert.equal(completion.find(c => c.label === 'memInfo').detail, 'Sys.memInfo : I64.', 'declared signature takes precedence over builtin completion');
    assert.equal(await ask('definition', own, 9, 16), null, 'unknown qualifier cannot jump to unrelated x');
    assert.equal(await ask('hover', own, 9, 16), null);
    const tokens = (await ask('semanticTokens/full', own)).data; let line = 0, col = 0, declarationToken;
    for (let i = 0; i < tokens.length; i += 5) { line += tokens[i]; col = tokens[i] ? tokens[i + 1] : col + tokens[i + 1]; if (line === 1 && col === 6) declarationToken = tokens.slice(i + 2, i + 5); }
    assert.deepEqual(declarationToken, [1, 5, 2], 'qualified value signature is a variable declaration token');
    assert(!(diagnostics.get(uri(own)) || []).some(d => /MyMod|deep|Sys/.test(d.message)), 'qualified signatures do not produce unresolved namespace diagnostics');

    const consumer = 'consumer.' + ext, lines = fs.readFileSync(file(consumer), 'utf8').split('\n'); open(consumer);
    const x = lines[1].lastIndexOf('x');
    assert.equal((await ask('definition', consumer, 1, x)).uri, uri('foreign.' + ext));
    assert((await ask('hover', consumer, 1, x)).contents.value.includes('MyMod.x : I64.'));
    const get = lines[2].indexOf('.get') + 2;
    assert((await ask('hover', consumer, 2, get)).contents.value.includes('I64 -> I64'));
    assert((await ask('completion', consumer, 2, get - 1)).some(c => c.label === 'get'));
    assert(!(diagnostics.get(uri(consumer)) || []).some(d => /MyMod|Foreign/.test(d.message)), 'imported signature namespace is recognized');
    open('foreign.' + ext); change('foreign.' + ext, 'MyMod.x : I32.\n');
    assert((await ask('hover', consumer, 1, x)).contents.value.includes('I32'), 'unsaved imported declaration refreshes hover');
    send('textDocument/didClose', { textDocument: { uri: uri('foreign.' + ext) } });
    assert((await ask('hover', consumer, 1, x)).contents.value.includes('I64'), 'closing restores disk signature');
    const other = 'unrelated.' + ext; write(other, 'Elsewhere.x : I64.\n'); open(other);
    change(consumer, 'copy = Elsewhere.x.\n'); assert.equal(await ask('hover', consumer, 0, 18), null, 'unrelated workspace foreign declarations do not leak into scope');
  }
  await request('shutdown', null); send('exit', null);
  console.log('qualified signatures: native/Sol compiler contract, local/nested/multiline/imported declarations, hover/completion/navigation/tokens, builtin precedence, dirty imports and scope isolation PASS');
})().catch(e => { console.error(e); process.exitCode = 1; }).finally(async () => { if (server && server.exitCode === null) { server.stdin.end(); await new Promise(r => setTimeout(r, 200)); if (server.exitCode === null) server.kill(); } fs.rmSync(dir, { recursive: true, force: true }); });
