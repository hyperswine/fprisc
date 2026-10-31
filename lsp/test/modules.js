#!/usr/bin/env node
// modules.js [fp-risc-dir] -- module resolution as the compiler does it.
//
//   node test/modules.js ..
//
// Builds a project with a module committed by the real `fpr commit` (so the
// store and hash are the compiler's own) and asserts, over LSP:
//   * a pinned `use "path#hash"` resolves (the hash is not part of the path)
//   * a pinned use whose working file differs only in comments/layout opens
//     the working file; one whose code changed, or that is missing, opens the
//     committed copy in the store -- the version the compiler uses
//   * an unpinned use opens the working file
//   * the compiler check runs from the project root, so a file in a
//     subdirectory whose pinned import resolves only from the store is clean
//   * a pinned .sol import (Sol has no store) resolves by name
//   * with no fpr.home and no FPR_HOME, `use "std/..."` finds the std beside
//     the compiler, as the compiler does
'use strict';
const { spawn, execFileSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const FPRISC = path.resolve(process.argv[2] || path.join(ROOT, '..'));
const FPR = path.join(FPRISC, 'fpr');
let fails = 0;
function ok(cond, what, detail) {
  if (cond) console.log(`  ok   ${what}`);
  else { fails++; console.log(`  FAIL ${what}${detail ? ' -- ' + detail : ''}`); }
}
if (!fs.existsSync(FPR)) {
  console.log(`modules: FAIL (no fpr executable in ${FPRISC})`);
  process.exit(1);
}

function server(initializationOptions, env) {
  const srv = spawn(process.execPath, [path.join(ROOT, 'server', 'server.js')], { stdio: ['pipe', 'pipe', 'inherit'], env });
  let buf = Buffer.alloc(0);
  const pending = new Map();
  const waiters = [];
  const diags = new Map();
  let nextId = 1;
  srv.stdout.on('data', (c) => {
    buf = Buffer.concat([buf, c]);
    while (true) {
      const he = buf.indexOf('\r\n\r\n');
      if (he === -1) return;
      const len = +buf.slice(0, he).toString().match(/Content-Length:\s*(\d+)/i)[1];
      if (buf.length < he + 4 + len) return;
      const body = JSON.parse(buf.slice(he + 4, he + 4 + len).toString('utf8'));
      buf = buf.slice(he + 4 + len);
      if (body.id !== undefined && pending.has(body.id)) { pending.get(body.id)(body); pending.delete(body.id); }
      else if (body.method === 'textDocument/publishDiagnostics') diags.set(body.params.uri, body.params.diagnostics);
      for (const w of waiters.splice(0)) w();
    }
  });
  const send = (o) => { const b = Buffer.from(JSON.stringify(o)); srv.stdin.write(`Content-Length: ${b.length}\r\n\r\n`); srv.stdin.write(b); };
  const request = (method, params) => new Promise((res) => { const id = nextId++; pending.set(id, res); send({ jsonrpc: '2.0', id, method, params }); });
  const notify = (method, params) => send({ jsonrpc: '2.0', method, params });
  const until = (pred, ms) => new Promise((res) => {
    const t = setTimeout(() => res(false), ms);
    const test = () => { if (pred()) { clearTimeout(t); res(true); } else waiters.push(test); };
    test();
  });
  return {
    diags, until,
    async start(rootUri) { await request('initialize', { capabilities: {}, rootUri, initializationOptions }); notify('initialized', {}); },
    open(p) {
      const uri = 'file://' + p;
      notify('textDocument/didOpen', { textDocument: { uri, languageId: p.endsWith('.sol') ? 'sol' : 'fpr', version: 1, text: fs.readFileSync(p, 'utf8') } });
      return uri;
    },
    close(uri) { notify('textDocument/didClose', { textDocument: { uri } }); },
    // where definition of the word at the first `needle` in file p lands
    async defAt(p, needle, offset) {
      const lines = fs.readFileSync(p, 'utf8').split('\n');
      const line = lines.findIndex((l) => l.includes(needle));
      const character = lines[line].indexOf(needle) + (offset || 0);
      const r = (await request('textDocument/definition', { textDocument: { uri: 'file://' + p }, position: { line, character } })).result;
      const loc = Array.isArray(r) ? r[0] : r;
      return loc ? decodeURIComponent(loc.uri.slice('file://'.length)) : null;
    },
    async stop() { await request('shutdown', null); notify('exit', null); },
  };
}

(async () => {
  const proj = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'fpr-modules-')));
  fs.mkdirSync(path.join(proj, 'lib'));
  fs.mkdirSync(path.join(proj, 'app'));
  const lib = path.join(proj, 'lib', 'm.fpr');
  fs.writeFileSync(lib, '# a library\ndouble : Int -> Int.\ndouble x = x * 2.\nlabel = "a  b".\n');
  execFileSync(FPR, ['commit', 'lib/m.fpr'], { cwd: proj, stdio: 'ignore' });
  const hash = fs.readdirSync(path.join(proj, '.fpr', 'store'))[0].replace(/\.fpr$/, '');
  const blob = path.join(proj, '.fpr', 'store', hash + '.fpr');
  const pinned = path.join(proj, 'app', 'main.fpr');
  fs.writeFileSync(pinned, `M = use "../lib/m#${hash}".\nmain = print (M.double 21).\n`);
  const loose = path.join(proj, 'app', 'loose.fpr');
  fs.writeFileSync(loose, 'M = use "../lib/m".\nmain = print (M.double 21).\n');
  fs.writeFileSync(path.join(proj, 'lib', 's.sol'), 'twice x = x + x.\n');
  const solApp = path.join(proj, 'app', 'app.sol');
  fs.writeFileSync(solApp, 'S = use "../lib/s#0123456789abcdef".\n> print (S.twice 2).\n');

  const env = { ...process.env };
  delete env.FPR_HOME; delete env.FPR_PATH;
  const s = server({ compilerPath: FPR, check: true }, env);
  await s.start('file://' + proj);

  console.log('== pinned and unpinned imports ==');
  s.open(pinned);
  ok(await s.defAt(pinned, 'M.double', 2) === lib, 'a pinned use resolves by its path, not path#hash');
  fs.writeFileSync(lib, '# a library, reworded\n\ndouble : Int -> Int.\ndouble x = x * 2.  # same code\nlabel = "a  b".\n');
  ok(await s.defAt(pinned, 'M.double', 2) === lib, 'comments and layout changed: still the working file');
  fs.writeFileSync(lib, 'double : Int -> Int.\ndouble x = x * 2.\nlabel = "a b".\n');
  ok(await s.defAt(pinned, 'M.double', 2) === blob, 'literal whitespace changed: the committed copy, not normalized working code');
  fs.writeFileSync(lib, 'double : Int -> Int.\ndouble x = x * 3.\n');
  ok(await s.defAt(pinned, 'M.double', 2) === blob, 'code changed: the committed copy in the store');
  s.open(loose);
  ok(await s.defAt(loose, 'M.double', 2) === lib, 'an unpinned use opens the working file');

  console.log('== the compiler check runs from the project root ==');
  const uri = 'file://' + pinned;
  const fromCompiler = () => (s.diags.get(uri) || []).filter((d) => d.source === 'fpr compile');
  s.close(uri);
  s.diags.delete(uri);
  s.open(pinned);
  await s.until(() => s.diags.has(uri) && false, 8000); // let the check finish
  ok(s.diags.has(uri) && fromCompiler().length === 0,
    'a subdirectory file whose pin resolves only from the store has no compiler errors',
    JSON.stringify(fromCompiler().map((d) => d.message)));

  fs.unlinkSync(lib);
  ok(await s.defAt(pinned, 'M.double', 2) === blob, 'working file missing: the committed copy');

  console.log('== .sol and the default home ==');
  s.open(solApp);
  ok(await s.defAt(solApp, 'S.twice', 2) === path.join(proj, 'lib', 's.sol'), 'a pinned .sol use resolves by name');
  const stdUser = path.join(proj, 'app', 'std.fpr');
  fs.writeFileSync(stdUser, 'L = use "std/list".\nmain = print (L.sum [1, 2]).\n');
  s.open(stdUser);
  const target = await s.defAt(stdUser, 'L.sum', 2);
  ok(target === path.join(fs.realpathSync(FPRISC), 'std', 'list.fpr'),
    'with no fpr.home or FPR_HOME, std resolves beside the compiler', target);
  await s.stop();

  fs.rmSync(proj, { recursive: true, force: true });
  console.log(fails ? `modules: ${fails} FAILED` : 'modules: all ok');
  process.exit(fails ? 1 : 0);
})();
