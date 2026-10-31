#!/usr/bin/env node
// compiler-check.js [fp-risc-dir] -- compiler diagnostics, end to end.
//
//   node test/compiler-check.js ..
//
// Writes small broken programs to a temp directory, opens each in the real
// server (over LSP, like the editor) with fpr.home pointing at the compiler
// tree, and asserts the compiler's errors arrive at the right place: located
// type errors, parse errors with a column, unresolved imports on the `use`,
// clause-anchored safety errors, typed holes, .sol type errors, a clean file
// that reports nothing, and a compiler that cannot be found.
'use strict';
const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { parseReport } = require('../server/compiler-check');

const ROOT = path.resolve(__dirname, '..');
const FPRISC = path.resolve(process.argv[2] || path.join(ROOT, '..'));
let fails = 0;
function ok(cond, what, detail) {
  if (cond) console.log(`  ok   ${what}`);
  else { fails++; console.log(`  FAIL ${what}${detail ? ' -- ' + detail : ''}`); }
}
if (!fs.existsSync(path.join(FPRISC, 'fpr'))) {
  console.log(`compiler-check: FAIL (no fpr executable in ${FPRISC}; build it, or pass the tree as argv[1])`);
  process.exit(1);
}

// ---- 1. the report parser, on the compiler's actual shapes -----------------
console.log('== report parser ==');
{
  const src = { '/w/a.fpr': 'f : Int -> Int.\nf x = x + 1.\nloop x = loop (x + 1).\nh x = ?todo.\nM = use "./nosuch".\n' };
  const report = [
    'use: List resolves to "std/list#1c3c48ae30d789e9"  (pin it to freeze this exact code)',
    'precond: 4 obligations: 2 discharged, 0 runtime-checked, 2 builtin traps',
    '=== TYPE ERRORS ===',
    '  * a.fpr:2: in f: (+): cannot unify String with Int',
    '  * a.fpr:2:7: in f: application of x: cannot unify Unit with Int',
    '  * in loop: unbound name: z',
    '=== SAFETY: the safe/unsafe line ===',
    '  * loop is unsafe (recursive) but has no explicit `loop : unsafe ...` signature',
    '=== TYPED HOLES ===',
    '  * got into a typed hole, ?todo : x33',
    'use: no such module file: ././nosuch.fpr  (nor $FPR_HOME/./nosuch.fpr)',
    'a.fpr:4:9:',
    '  |',
    '4 | h x = ?todo.',
    '  |         ^^',
    'unexpected ")"',
    'expecting digit',
    '',
  ].join('\n');
  const got = parseReport(report, { cwd: '/w', mainPath: '/w/a.fpr', readText: (p) => src[p] || null, failed: true });
  const d = got.get('/w/a.fpr') || [];
  const at = (i) => d[i] && `${d[i].range.start.line + 1}:${d[i].range.start.character + 1}-${d[i].range.end.character + 1}`;
  ok(d.length === 7, `seven diagnostics, all on the checked file (${d.length})`);
  ok(at(0) === '2:1-2' && d[0].code === 'type-error', `located error underlines the clause name 'f' (${at(0)})`);
  ok(at(1) === '2:7-8', `a column underlines the token there (${at(1)})`);
  ok(at(2) === '3:1-5', `an unlocated 'in loop:' goes to loop's first line (${at(2)})`);
  ok(at(3) === '3:1-5' && d[3].code === 'safety', `a safety item names its function (${at(3)})`);
  ok(at(4) === '4:7-12' && d[4].severity === 2, `a typed hole is a warning on the hole (${at(4)})`);
  ok(d[5] && d[5].code === 'import' && at(5) === '5:9-19', `a missing module is reported on its use string (${at(5)})`);
  ok(d[6] && d[6].code === 'parse' && at(6) === '4:9-12' && d[6].message === 'unexpected ")"\nexpecting digit', `a parse error keeps its message, drops the excerpt (${at(6)})`);
  ok(!d.some((x) => /resolves to|precond/.test(x.message)), 'informational lines are not errors');

  const silent = parseReport('something unexpected\n', { cwd: '/w', mainPath: '/w/a.fpr', readText: (p) => src[p] || null, failed: true });
  const s = silent.get('/w/a.fpr') || [];
  ok(s.length === 1 && s[0].code === 'check-failed' && s[0].message === 'something unexpected', 'an unrecognized failure is still reported, in its own words');
  ok(parseReport('precond: 1 obligations\n', { cwd: '/w', mainPath: '/w/a.fpr', readText: () => null, failed: false }).size === 0, 'a passing check reports nothing');
}

// ---- 2. the server, against the real compiler -------------------------------
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fpr-check-'));
const FILES = {
  'clean.fpr': 'main = print (1 + 2).\n',
  'unbound.fpr': '# a use of a name nobody defined\nmain = print (foo 1).\n',
  'parse.fpr': 'main = print (1 +).\n',
  'import.fpr': 'M = use "./nosuch".\nmain = print 1.\n',
  'safety.fpr': 'loop x = loop (x + 1).\nmain = print (loop 1).\n',
  'module.fpr': 'next : Int -> Int.\nnext x = x + 1.\n',
  'module-user.fpr': 'M = use "./module".\nmain = print (M.next 1).\n',
  'module-type.fpr': 'value : Int.\nvalue = "wrong".\n',
  'module-safety.fpr': 'loop x = loop (x + 1).\n',
  'module-import.fpr': 'M = use "./nosuch".\nvalue = 1.\n',
  'module-dependent.fpr': 'M = use "./module-type".\nmain = print M.value.\n',
  'script.sol': 'f x = x + 1.\n> print (f "x").\n',
};
for (const [n, t] of Object.entries(FILES)) fs.writeFileSync(path.join(dir, n), t);

function server(initializationOptions) {
  const srv = spawn(process.execPath, [path.join(ROOT, 'server', 'server.js')], { stdio: ['pipe', 'pipe', 'inherit'] });
  let buf = Buffer.alloc(0);
  const pending = new Map();
  const waiters = [];
  const diags = new Map();
  const messages = [];
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
      else if (body.method === 'window/showMessage') messages.push(body.params.message);
      for (const w of waiters.splice(0)) w();
    }
  });
  const send = (o) => { const b = Buffer.from(JSON.stringify(o)); srv.stdin.write(`Content-Length: ${b.length}\r\n\r\n`); srv.stdin.write(b); };
  const request = (method, params) => new Promise((res) => { const id = nextId++; pending.set(id, res); send({ jsonrpc: '2.0', id, method, params }); });
  const notify = (method, params) => send({ jsonrpc: '2.0', method, params });
  // resolve when pred() holds, re-tested on every message; fail after a while
  const until = (pred, ms) => new Promise((res) => {
    const t = setTimeout(() => res(false), ms);
    const test = () => { if (pred()) { clearTimeout(t); res(true); } else waiters.push(test); };
    test();
  });
  return {
    diags, messages, until,
    async start() { await request('initialize', { capabilities: {}, initializationOptions }); notify('initialized', {}); },
    open(name) {
      const p = path.join(dir, name);
      notify('textDocument/didOpen', { textDocument: { uri: 'file://' + p, languageId: name.endsWith('.sol') ? 'sol' : 'fpr', version: 1, text: fs.readFileSync(p, 'utf8') } });
      return 'file://' + p;
    },
    save(uri) {
      notify('textDocument/didChange', { textDocument: { uri, version: 2 }, contentChanges: [{ text: fs.readFileSync(uri.slice(7), 'utf8') }] });
      notify('textDocument/didSave', { textDocument: { uri } });
    },
    async stop() { await request('shutdown', null); notify('exit', null); },
  };
}

const fromCompiler = (list) => (list || []).filter((d) => d.source === 'fpr compile');
const span = (d) => d && `${d.range.start.line + 1}:${d.range.start.character + 1}-${d.range.end.character + 1}`;

(async () => {
  console.log('== server + compiler ==');
  const s = server({ home: FPRISC, check: true });
  await s.start();
  const uris = Object.fromEntries(Object.keys(FILES).map((n) => [n, s.open(n)]));
  // every file that should fail has its compiler diagnostic; clean has a publish
  const want = ['unbound.fpr', 'parse.fpr', 'import.fpr', 'safety.fpr', 'script.sol',
    'module-type.fpr', 'module-safety.fpr', 'module-import.fpr'];
  const arrived = await s.until(() => want.every((n) => fromCompiler(s.diags.get(uris[n])).length)
    && fromCompiler(s.diags.get(uris['module-type.fpr'])).some((x) => x.message.startsWith('in value:')), 60000);
  ok(arrived, 'every broken file got a compiler diagnostic', want.filter((n) => !fromCompiler(s.diags.get(uris[n])).length).join(' '));

  const one = (n) => fromCompiler(s.diags.get(uris[n]))[0];
  let d = one('unbound.fpr');
  ok(d && span(d) === '2:1-5' && /unbound name: foo/.test(d.message) && d.severity === 1, `unbound name: error on 'main', line 2 (${span(d)} ${d && d.message})`);
  d = one('parse.fpr');
  ok(d && d.code === 'parse' && span(d) === '1:18-19' && /unexpected/.test(d.message), `parse error at its column (${span(d)})`);
  d = one('import.fpr');
  ok(d && d.code === 'import' && span(d) === '1:9-19', `missing module on its use string (${span(d)})`);
  d = one('safety.fpr');
  ok(d && d.code === 'safety' && span(d) === '1:1-5', `unsafe recursion on 'loop' (${span(d)})`);
  d = one('script.sol');
  ok(d && span(d) === '2:10-11' && /cannot unify/.test(d.message), `.sol type error on the call it names (${span(d)} ${d && d.message})`);
  d = fromCompiler(s.diags.get(uris['module-type.fpr'])).find((x) => x.message.startsWith('in value:'));
  ok(d && d.code === 'type-error' && span(d) === '1:1-6' && /cannot unify/.test(d.message),
    `mainless module: declared type error on its signature (${span(d)} ${d && d.message})`);
  d = one('module-safety.fpr');
  ok(d && d.code === 'safety' && span(d) === '1:1-5', `mainless module: unsafe recursion on 'loop' (${span(d)})`);
  d = one('module-import.fpr');
  ok(d && d.code === 'import' && span(d) === '1:9-19', `mainless module: missing import on its use string (${span(d)})`);
  ok(!want.some((name) => fromCompiler(s.diags.get(uris[name])).some((x) => /has no `main`/.test(x.message))),
    'missing main never masks module diagnostics');

  // a clean file: the check runs and reports nothing
  await s.until(() => false, 3000);
  ok(fromCompiler(s.diags.get(uris['clean.fpr'])).length === 0, 'a clean file has no compiler diagnostics');
  ok(fromCompiler(s.diags.get(uris['module.fpr'])).length === 0, 'a valid module needs no main');
  ok(fromCompiler(s.diags.get(uris['module-user.fpr'])).length === 0, 'a program importing a valid mainless module stays clean');
  ok(fromCompiler(s.diags.get(uris['module-dependent.fpr'])).length === 0,
    'an imported type error is reported on the module, not its consumer');

  // Both the direct module check and its consumer must clear the old report.
  fs.writeFileSync(path.join(dir, 'module-type.fpr'), 'value : Int.\nvalue = 42.\n');
  s.save(uris['module-type.fpr']);
  ok(await s.until(() => fromCompiler(s.diags.get(uris['module-type.fpr'])).length === 0, 30000),
    'saving a corrected mainless module clears direct and importing checks');

  // A clean result must follow a completed check, not just an initial empty
  // scanner publication: introduce a compiler-only error, then repair it.
  fs.writeFileSync(path.join(dir, 'module.fpr'), 'next : Int -> Int.\nnext x = "wrong".\n');
  s.save(uris['module.fpr']);
  ok(await s.until(() => fromCompiler(s.diags.get(uris['module.fpr'])).some((x) => x.code === 'type-error'), 30000),
    'saving a broken module introduces a real compiler diagnostic');
  fs.writeFileSync(path.join(dir, 'module.fpr'), FILES['module.fpr']);
  s.save(uris['module.fpr']);
  ok(await s.until(() => fromCompiler(s.diags.get(uris['module.fpr'])).length === 0, 30000),
    'saving the repaired module clears its compiler diagnostic without adding a main');

  // fix on disk + save: the diagnostic goes away
  fs.writeFileSync(path.join(dir, 'unbound.fpr'), 'main = print 1.\n');
  s.save(uris['unbound.fpr']);
  ok(await s.until(() => fromCompiler(s.diags.get(uris['unbound.fpr'])).length === 0, 30000), 'saving the fix clears the diagnostic');
  await s.stop();

  console.log('== missing compiler ==');
  const m = server({ home: FPRISC, compilerPath: path.join(dir, 'no-such-fpr') });
  await m.start();
  m.open('unbound.fpr');
  ok(await m.until(() => m.messages.length > 0, 10000) && /could not run the compiler/.test(m.messages[0]), 'a compiler that cannot run is said once, not silently skipped');
  await m.stop();

  console.log('== disabled ==');
  const off = server({ home: FPRISC, check: false });
  await off.start();
  const u = off.open('safety.fpr');
  await off.until(() => false, 3000);
  ok(fromCompiler(off.diags.get(u)).length === 0, 'fpr.check: false runs no compiler');
  await off.stop();

  fs.rmSync(dir, { recursive: true, force: true });
  console.log(fails ? `compiler-check: ${fails} FAILED` : 'compiler-check: all ok');
  process.exit(fails ? 1 : 0);
})();
