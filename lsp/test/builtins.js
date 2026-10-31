'use strict';
// Exercise every bundled name over the actual LSP transport in each supported
// language. Nonempty JSON alone does not prove operators can be hovered.
const assert = require('assert/strict');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn, execFileSync, spawnSync } = require('child_process');
const { pathToFileURL } = require('url');
const root = path.resolve(__dirname, '..');
const home = path.resolve(process.argv[2] || path.join(root, '..'));
const db = require('../server/builtins.json');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fpr-hover-'));
const fresh = path.join(dir, 'builtins.json');
execFileSync(process.execPath, [path.join(root, 'tools/mkbuiltins.js'), home, fresh]);
assert.deepEqual(JSON.parse(fs.readFileSync(fresh)), db, 'regenerate the bundled reference after compiler changes');
// New undocumented primitives and unknown type constructors must fail generation,
// rather than quietly shipping another partial/stale hover database.
const fixture = path.join(dir, 'compiler-fixture');
for (const file of ['compiler/Infer.hs', 'compiler/Sol/Infer.hs', 'compiler/Sol/Preamble.hs', 'core/prelude.fpr']) {
  const target = path.join(fixture, file);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.copyFileSync(path.join(home, file), target);
}
fs.symlinkSync(path.join(home, 'docs'), path.join(fixture, 'docs'));
const inferFile = path.join(fixture, 'compiler/Infer.hs');
const originalInfer = fs.readFileSync(inferFile, 'utf8');
for (const [source, expected] of [
  [originalInfer.replace('("strcat",', '("hoverDocRegression",'), /Missing builtin documentation:.*hoverDocRegression/],
  [originalInfer.replace('("strcat", mono (TFn tStr', '("strcat", mono (TFn tFuture'), /Unknown compiler type atom: tFuture/],
]) {
  fs.writeFileSync(inferFile, source);
  const result = spawnSync(process.execPath, [path.join(root, 'tools/mkbuiltins.js'), fixture, path.join(dir, 'refused.json')], { encoding: 'utf8' });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, expected);
}

for (const [file, table, profile] of [['compiler/Infer.hs', 'builtinEnv', 'fpr'], ['compiler/Infer.hs', "builtinCons'", 'fpr'], ['compiler/Sol/Infer.hs', 'solBuiltins', 'sol']]) {
  const source = fs.readFileSync(path.join(home, file), 'utf8').split(`\n${table} =`)[1].split('\n    ]')[0];
  assert(source);
  const names = [...source.matchAll(/\("([^"]+)"\s*,/g)].map(m => m[1]).filter(n => !n.startsWith('$'));
  assert(names.length > 10);
  for (const name of names) {
    assert(db[name], `${name}: compiler entry missing`);
    assert(db[name].variants?.[profile]?.doc, `${name}: ${profile} documentation missing`);
  }
}
for (const [name, entry] of Object.entries(db)) {
  assert(entry.doc.trim(), `${name}: empty docs`);
  for (const [profile, v] of Object.entries(entry.variants || { [entry.profile]: entry })) {
    assert(v.doc.trim(), `${name} (${profile}): empty docs`);
    assert(!/\bt(?:I32|I64|Vector)\b|\bTFn\b|\bTAp\b/.test(v.sig), `${name}: leaked Haskell type syntax`);
  }
}
assert.equal(db['Vec.map'].variants.fpr.sig, 'Vec.map : (a -> b) -> (Vector a) -> Vector b');
assert.equal(db['Vec.zipAdd'].variants.fpr.sig, 'Vec.zipAdd : (Vector Int) -> (Vector Int) -> Vector Int');
assert.equal(db['I32.toInt'].sig, 'I32.toInt : I32 -> Result Int String');
assert.match(db['Vec.range'].doc, /inclusive/);
assert.match(db['spawnHeap'].variants.sol.doc, /not enforced/);
assert.match(db['receiveFromRes'].doc, /died/);
assert(db.Path && db.WInt && db.GitStatus && db['Int.(==)'], 'prelude types, constructors and operators');

const srv = spawn(process.execPath, [path.join(root, 'server/server.js')]);
let buf = Buffer.alloc(0), serial = 0;
const pending = new Map();
let stderr = '';
srv.stderr.on('data', c => { stderr += c; });
const timer = setTimeout(() => { console.error('hover coverage timed out', stderr); srv.kill(); process.exitCode = 1; }, 30000);
srv.stdout.on('data', chunk => {
  buf = Buffer.concat([buf, chunk]);
  for (;;) {
    const end = buf.indexOf('\r\n\r\n'); if (end < 0) return;
    const len = +buf.subarray(0, end).toString().match(/Content-Length:\s*(\d+)/i)[1];
    if (buf.length < end + 4 + len) return;
    const response = JSON.parse(buf.subarray(end + 4, end + 4 + len));
    buf = buf.subarray(end + 4 + len);
    const resolve = pending.get(response.id);
    if (resolve) { pending.delete(response.id); resolve(response); }
  }
});
function send(method, params, id) {
  const body = Buffer.from(JSON.stringify({ jsonrpc: '2.0', id, method, params }));
  srv.stdin.write(`Content-Length: ${body.length}\r\n\r\n`); srv.stdin.write(body);
}
async function request(method, params) {
  const id = ++serial;
  const r = await new Promise(resolve => { pending.set(id, resolve); send(method, params, id); });
  assert(!r.error, JSON.stringify(r.error)); return r.result;
}
(async () => {
  await request('initialize', { rootUri: pathToFileURL(dir).href, initializationOptions: { home, check: false, unresolvedNames: false } });
  let count = 0;
  for (const profile of ['fpr', 'sol']) {
    const names = Object.keys(db).filter(n => db[n].profile === profile || db[n].profile === 'both');
    const lines = names.map((n, i) => n === '#:' ? '#: expect hello' : n === '>' ? '> print 1.' : `probe${i} = ${n === '@' ? '@Message' : n === '!' ? 'xs ! 0' : n}.`);
    const uri = pathToFileURL(path.join(dir, `all.${profile}`)).href;
    send('textDocument/didOpen', { textDocument: { uri, languageId: profile, version: 1, text: lines.join('\n') } });
    for (let line = 0; line < names.length; line++) {
      const name = names[line];
      const start = lines[line].indexOf(name === '@' ? '@Message' : name, name === '#:' || name === '>' ? 0 : lines[line].indexOf('=') + 1);
      // Hit the member/operator itself, not the qualifier.
      const character = start + (name.includes('.') ? name.lastIndexOf('.') + 1 : 0);
      const hover = await request('textDocument/hover', { textDocument: { uri }, position: { line, character } });
      assert(hover?.contents?.value, `${profile}: no hover for ${name}`);
      const variant = db[name].variants?.[profile] || db[name];
      assert(hover.contents.value.includes(variant.doc), `${profile}: wrong/missing docs for ${name}`);
      assert(hover.contents.value.includes(variant.sig), `${profile}: wrong signature for ${name}`);
      count++;
    }
    const complete = await request('textDocument/completion', { textDocument: { uri }, position: { line: 0, character: 0 } });
    assert.equal(complete.some(x => x.label === 'I32.toInt'), profile === 'fpr');
    assert.equal(complete.some(x => x.label === 'timeNow'), profile === 'sol');
  }
  const operatorUri = pathToFileURL(path.join(dir, 'operators.fpr')).href;
  send('textDocument/didOpen', { textDocument: { uri: operatorUri, languageId: 'fpr', version: 1, text: 'x = I32.(+).\ny = Int.==.' } });
  for (const [line, character, name] of [[0,9,'I32.+'], [1,8,'Int.(==)']]) {
    const hover = await request('textDocument/hover', { textDocument: { uri: operatorUri }, position: { line, character } });
    assert(hover?.contents.value.includes(db[name].variants.fpr.doc), 'qualified operator spelling aliases');
  }
  const negativeUri = pathToFileURL(path.join(dir, 'negative.fpr')).href;
  const negative = 'compare = 1 != 2.\ntext = "I32.toInt".\n# receiveFromRes\nI32 = Struct { other = 1 }.\nmissing = I32.toInt.';
  send('textDocument/didOpen', { textDocument: { uri: negativeUri, languageId: 'fpr', version: 1, text: negative } });
  for (const [line, character] of [[0,12], [1,12], [2,5], [4,16]]) {
    assert.equal(await request('textDocument/hover', { textDocument: { uri: negativeUri }, position: { line, character } }), null, 'no builtin docs in strings/comments, unrelated operators, or shadowed namespaces');
  }
  // Profile-specific signatures do not bleed across shared builtin names.
  assert.equal(db.read.variants.fpr.sig, 'read : Int -> Int');
  assert.equal(db.read.variants.sol.sig, 'read : a -> b');
  console.log(`builtin hover coverage: ${count} LSP hovers, both profiles, all compiler names and docs passed`);
})().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => {
  clearTimeout(timer); srv.kill(); fs.rmSync(dir, { recursive: true, force: true });
});
