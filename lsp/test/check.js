#!/usr/bin/env node
// check.js [fp-risc-dir] -- the guard against the rot this extension already
// suffered once: a hover database generated from a doc that no longer exists,
// and a two-language server that resolved imports in one language only.
//
//   node test/check.js ..
//
// Asserts, against the REAL compiler tree:
//   * the generator still finds all four sources and rebuilds the database
//   * builtins added recently are present, typed, and tagged to a profile
//   * a name that exists in one profile is not offered in the other
//   * `use` resolves cross-module in BOTH .fpr and .sol
//   * every grammar regex compiles and matches the syntax it claims
'use strict';
const { execFileSync, spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const FPRISC = path.resolve(process.argv[2] || path.join(ROOT, '..'));
let fails = 0;
function ok(cond, what, detail) {
  if (cond) console.log(`  ok   ${what}`);
  else { fails++; console.log(`  FAIL ${what}${detail ? ' -- ' + detail : ''}`); }
}

if (!fs.existsSync(path.join(FPRISC, 'compiler/Infer.hs'))) {
  console.log(`check: FAIL (no compiler tree at ${FPRISC}; pass its path as argv[1])`);
  process.exit(1);
}

// ---- 1. the generator ------------------------------------------------------
console.log('== generator ==');
const tmp = path.join(os.tmpdir(), `fpr-builtins-${process.pid}.json`);
const out = execFileSync(process.execPath, [path.join(ROOT, 'tools/mkbuiltins.js'), FPRISC, tmp], { encoding: 'utf8' });
const db = JSON.parse(fs.readFileSync(tmp, 'utf8'));
fs.unlinkSync(tmp);
ok(JSON.stringify(db) === JSON.stringify(JSON.parse(fs.readFileSync(path.join(ROOT, 'server/builtins.json'), 'utf8'))), 'checked-in database matches the current compiler');
const table = fs.readFileSync(path.join(FPRISC, 'compiler/Infer.hs'), 'utf8').split('builtinEnv =')[1].split("builtinCons' ::")[0];
const names = [...table.matchAll(/\("([^"]+)"\s*,/g)].map(m => m[1]).filter(n => !n.startsWith('$'));
ok(names.every(n => db[n]), 'every public AOT type-table entry was extracted');
ok(Object.keys(db).length > 400, `database has ${Object.keys(db).length} entries`);
ok(/fpr \d+, sol \d+, both \d+/.test(out), 'every entry is tagged with a profile');

// names the old docs-derived database could not have: if these are missing the
// generator has lost a source
const WANT = {
  'spawnCap': 'fpr', 'spawnCapOn': 'fpr', 'timeNow': 'sol', 'Sys.memInfo': 'fpr',
  'Sys.spawnApp': 'fpr', 'Word.bits': 'fpr', 'Mem.compareExchange': 'fpr', 'receiveNow': 'fpr',
  'Addr.symbol': 'fpr', 'Mod.findAt': 'fpr', 'F64.pow': 'fpr', 'CPU.irqSave': 'fpr',
  'Str.cmp': 'sol', 'Str.codes': 'sol', 'Str.split': 'sol', 'List.groupby': 'sol',
  'Try.parseNum': 'sol', 'Proc.query': 'sol', 'readPath': 'sol', 'shq': 'sol',
  'unsafe': 'both', '?name': 'both', '??': 'both',
};
for (const [name, profile] of Object.entries(WANT)) {
  const e = db[name];
  const okProfile = e && (e.profile === profile || e.profile === 'both');
  ok(e && e.sig && okProfile, `${name} present (${profile})`, e ? `profile ${e.profile}` : 'missing');
}
for (const name of ['glMesh', 'glRenderUi', 'sndMusic', 'Sys.attachQa', 'Pin.wire', '$cast']) ok(!db[name], `${name} is not a compiler builtin`);
ok(db['Int.max'] && db['Str.len'], 'AOT prelude record members are included');
// types come from the tables, so they must look like types
ok(/^send : Int -> a -> Result Unit String/.test(db.send.sig), 'send is typed Result (not the old Unit)', db.send.sig);
ok(db['Sys.memInfo'].sig.includes('List Int'), 'Sys.memInfo returns a List Int', db['Sys.memInfo'].sig);
ok(Object.values(db).filter((e) => e.doc).length > 100, 'a good share of entries carry prose');
ok(Object.values(db).every((e) => (e.doc || '').length < 1200), 'no hover doc is a chapter');

// ---- 2. the grammars -------------------------------------------------------
console.log('== grammars ==');
for (const lang of ['fpr', 'sol']) {
  const g = JSON.parse(fs.readFileSync(path.join(ROOT, `syntaxes/${lang}.tmLanguage.json`), 'utf8'));
  const R = g.repository;
  let bad = null;
  (function walk(o) {
    for (const k in o) {
      const v = o[k];
      if (k === 'match' || k === 'begin' || k === 'end') { try { new RegExp(v); } catch (e) { bad = `${v}: ${e.message}`; } }
      else if (v && typeof v === 'object') walk(v);
    }
  })(R);
  ok(!bad, `${lang}: every regex compiles`, bad);
  const hits = (rule, s) => R[rule] && new RegExp(R[rule].match).test(s);
  ok(hits('typeDecl', 'Ev msg = Type (Msg msg).'), `${lang}: parameterized types`);
  ok(hits('typeDecl', 'Box 1 a = Type a.'), `${lang}: linear parameterized types`);
  ok(hits('typeDecl', 'Block = Layout { size : Word }.'), `${lang}: Layout`);
  ok(hits('profile', 'profile base.'), `${lang}: profiles`);
  ok(hits('typeSig', 'Os.poll : List Int -> List Int.'), `${lang}: foreign signatures`);
  ok(new RegExp(R.number.match).exec('1.25e-3f')[0] === '1.25e-3f', `${lang}: float literals`);
  ok(hits('operator', 'a % b') && hits('operator', 'x ^ 2'), `${lang}: % and ^ are operators`);
  ok(hits('operator', 'xs |>? f'), `${lang}: |>? is an operator`);
  ok(hits('directive', '#: plugins a.fpr'), `${lang}: #: directives have their own scope`);
  ok(hits('unsafeKw', '(n : Int | measure n)'), `${lang}: measure is marked`);
  ok(hits('pathLiteral', '@Model.count'), `${lang}: @path literals are strings`);
  ok(g.patterns.some((p) => p.include === '#directive'), `${lang}: directive runs before comment`);
}

// ---- 3. the server, in BOTH languages --------------------------------------
console.log('== server ==');
function lsp(file, probes) {
  return new Promise((resolve) => {
    const srv = spawn(process.execPath, [path.join(ROOT, 'server/server.js')], { stdio: ['pipe', 'pipe', 'ignore'] });
    let buf = Buffer.alloc(0);
    const pending = new Map();
    let id = 1;
    const got = [];
    srv.stdout.on('data', (c) => {
      buf = Buffer.concat([buf, c]);
      for (;;) {
        const he = buf.indexOf('\r\n\r\n');
        if (he === -1) return;
        const len = +(buf.slice(0, he).toString().match(/Content-Length:\s*(\d+)/i) || [])[1];
        if (buf.length < he + 4 + len) return;
        const body = JSON.parse(buf.slice(he + 4, he + 4 + len).toString('utf8'));
        buf = buf.slice(he + 4 + len);
        if (pending.has(body.id)) { pending.get(body.id)(body); pending.delete(body.id); }
      }
    });
    const send = (o) => {
      const b = Buffer.from(JSON.stringify(o), 'utf8');
      srv.stdin.write(`Content-Length: ${b.length}\r\n\r\n`);
      srv.stdin.write(b);
    };
    const req = (method, params) => new Promise((r) => { const i = id++; pending.set(i, r); send({ jsonrpc: '2.0', id: i, method, params }); });
    (async () => {
      await req('initialize', { capabilities: {} });
      send({ jsonrpc: '2.0', method: 'initialized', params: {} });
      const uri = 'file://' + file;
      send({
        jsonrpc: '2.0',
        method: 'textDocument/didOpen',
        params: { textDocument: { uri, languageId: file.endsWith('.sol') ? 'sol' : 'fpr', version: 1, text: fs.readFileSync(file, 'utf8') } },
      });
      for (const p of probes) {
        const r = await req(p.hover ? 'textDocument/hover' : 'textDocument/definition',
          { textDocument: { uri }, position: { line: p.line - 1, character: p.col - 1 } });
        got.push(r.result);
      }
      srv.kill();
      resolve(got);
    })();
  });
}

(async () => {
  // a .sol file importing a .sol lib -- the case the pinned '.fpr' broke
  const solFile = path.join(FPRISC, 'sol/examples/jsoncsv.sol');
  if (fs.existsSync(solFile)) {
    const [def, hov] = await lsp(solFile, [{ line: 34, col: 44 }, { line: 33, col: 10, hover: true }]);
    ok(def && /json\.sol$/.test(def.uri || ''), 'sol: `use` resolves into the imported .sol module', def && def.uri);
    ok(hov && /```sol/.test(hov.contents.value), 'sol: hovers are fenced as sol', hov && hov.contents.value.slice(0, 20));
  }
  // a .fpr program importing a std .fpr module
  const fprFile = path.join(FPRISC, 'tests/memory.fpr');
  if (fs.existsSync(fprFile)) {
    const [def, hov] = await lsp(fprFile, [{ line: 30, col: 10 }, { line: 49, col: 12, hover: true }]);
    ok(def && /actor\.fpr$/.test(def.uri || ''), 'fpr: `use` resolves into the imported .fpr module', def && def.uri);
    ok(hov && /Sys\.memInfo : Int -> List Int/.test(hov.contents.value), 'fpr: a current builtin hovers with its type');
  }
  console.log(fails ? `\ncheck: ${fails} FAILED` : '\ncheck: all good');
  process.exit(fails ? 1 : 0);
})();
