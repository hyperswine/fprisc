'use strict';
// strings.js -- strings that hold code that holds strings.
//
// "{...}" inside a literal is an interpolation, and the code in it may hold a
// string again: statLine in fprisc/examples/pos1.fpr is
//   "{S.padRight 9 " " label} n {S.padLeft 6 " " "{st.n}"} ..."
// The grammars' interpolation rule knew no nested string and no nested brace,
// so the inner "{st.n}" closed the OUTER interpolation, the quotes fell out of
// step, and the rest of the file was highlighted as one string.  The server's
// line scanners toggled on every quote and forgot their state at each line
// end, with the matching faults.  This checks both.
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');
const ROOT = process.env.FPR_EXT_ROOT || path.join(__dirname, '..'); // FPR_EXT_ROOT: check another copy of the extension

let failed = 0;
const ok = (cond, what, detail) => {
  console.log(`${cond ? 'ok  ' : 'FAIL'} ${what}${!cond && detail !== undefined ? '\n       ' + detail : ''}`);
  if (!cond) failed++;
};

// ---- a TextMate interpreter, as much of one as these grammars use -----------
// match, begin/end with nested patterns, include of a repository rule; the
// earliest match wins, an end before a pattern at the same place, then order.
function tokenizer(grammar) {
  const R = grammar.repository;
  function expand(patterns, seen) {
    const out = [];
    for (const p of patterns || []) {
      if (p.include) {
        const name = p.include.slice(1);
        const r = R[name];
        if (!r || seen.has(name)) continue;
        if (r.match || r.begin) out.push(r);
        else out.push(...expand(r.patterns, new Set([...seen, name])));
      } else if (p.match || p.begin) out.push(p);
      else if (p.patterns) out.push(...expand(p.patterns, seen));
    }
    return out;
  }
  const scopesOf = (rule) => {
    const out = [];
    if (rule.name) out.push(rule.name);
    for (const caps of [rule.captures, rule.beginCaptures])
      for (const k in caps || {}) if (caps[k].name) out.push(caps[k].name);
    return out;
  };
  return function tokenize(text) {
    const stack = [{ patterns: expand(grammar.patterns, new Set()), scopes: [] }];
    const lines = text.split('\n').map((line) => {
      const tokens = [];
      let pos = 0;
      while (pos < line.length) {
        const top = stack[stack.length - 1];
        let best = null;
        const tryRe = (src, kind, rule) => {
          const re = new RegExp(src, 'g');
          re.lastIndex = pos;
          const m = re.exec(line);
          if (m && (best === null || m.index < best.m.index)) best = { m, kind, rule };
        };
        if (top.end) tryRe(top.end, 'end', top.rule);
        for (const r of top.patterns) tryRe(r.match || r.begin, r.match ? 'match' : 'begin', r);
        if (!best) { tokens.push({ from: pos, to: line.length, scopes: top.scopes }); break; }
        const { m, kind, rule } = best;
        if (m.index > pos) tokens.push({ from: pos, to: m.index, scopes: top.scopes });
        const to = m.index + Math.max(m[0].length, 1);
        if (kind === 'end') { tokens.push({ from: m.index, to, scopes: top.scopes }); stack.pop(); }
        else if (kind === 'match') tokens.push({ from: m.index, to, scopes: top.scopes.concat(scopesOf(rule)) });
        else {
          const scopes = top.scopes.concat(rule.name ? [rule.name] : []);
          tokens.push({ from: m.index, to, scopes });
          stack.push({ rule, end: rule.end, patterns: expand(rule.patterns, new Set()), scopes });
        }
        pos = to;
      }
      return { line, tokens, openAfter: stack.length - 1 };
    });
    return lines;
  };
}

const statLine = 'statLine label st = "{S.padRight 9 " " label} n {S.padLeft 6 " " "{st.n}"}  avg {S.padLeft 7 " " "{avg st}"} us  max {S.padLeft 7 " " "{st.max}"} us  last {st.last} us".';

console.log('== grammars ==');
for (const lang of ['fpr', 'sol']) {
  const tokenize = tokenizer(JSON.parse(fs.readFileSync(path.join(ROOT, `syntaxes/${lang}.tmLanguage.json`), 'utf8')));
  const scopesAt = (row, needle, nth) => {
    let i = -1;
    for (let k = 0; k <= (nth || 0); k++) i = row.line.indexOf(needle, i + 1);
    const t = row.tokens.find((x) => x.from <= i && i < x.to);
    return t ? t.scopes.join(' ') : '';
  };
  const isStr = (s) => s.includes('string.quoted.double');
  const inInterp = (s) => s.includes('meta.embedded.interpolation');

  const rows = tokenize([statLine, 'after x = x + 1.'].join('\n'));
  ok(rows[0].openAfter === 0, `${lang}: the string on the statLine line is closed at its end`, `rules still open: ${rows[0].openAfter}`);
  ok(!isStr(scopesAt(rows[1], 'after')) && !isStr(scopesAt(rows[1], '1')), `${lang}: the line after it is code, not string`, scopesAt(rows[1], 'after'));
  ok(isStr(scopesAt(rows[0], ' avg ')) && !inInterp(scopesAt(rows[0], ' avg ')), `${lang}: the text between two interpolations is string text`, scopesAt(rows[0], ' avg '));
  ok(inInterp(scopesAt(rows[0], 'padLeft')) && scopesAt(rows[0], 'padLeft').includes('variable.other.member'), `${lang}: a qualified name inside an interpolation is code`, scopesAt(rows[0], 'padLeft'));
  const inner = scopesAt(rows[0], 'st.n');
  ok((inner.match(/string\.quoted\.double/g) || []).length === 2 && (inner.match(/meta\.embedded\.interpolation/g) || []).length === 2,
     `${lang}: "{st.n}" inside an interpolation is a string with its own interpolation`, inner);
  const pad = scopesAt(rows[0], '" "');
  ok((pad.match(/string\.quoted\.double/g) || []).length === 2, `${lang}: a string argument inside an interpolation is a nested string`, pad);

  const more = tokenize([
    'a = "{f { x = 1, y = "}" } 2}" + tail.',       // a record, and a string holding a brace, inside an interpolation
    'b = "brace \\{ not code } and quote \\" still text".', // escapes
    'c = "one {x} two {"three {"four {y}"}"} five".',        // three deep
    'css = "',
    '.a\\{color:#fff}',
    '#id\\{x:1}',
    '".',
    'd = 4. # a comment with "a quote',
    'e = 5.',
  ].join('\n'));
  ok(more[0].openAfter === 0 && !isStr(scopesAt(more[0], 'tail')), `${lang}: braces and a "}" string inside an interpolation do not end it early`, `${more[0].openAfter} ${scopesAt(more[0], 'tail')}`);
  ok(more[1].openAfter === 0 && !inInterp(scopesAt(more[1], 'not code')), `${lang}: an escaped brace opens nothing, an escaped quote ends nothing`, scopesAt(more[1], 'not code'));
  ok(more[2].openAfter === 0 && isStr(scopesAt(more[2], ' five')) && !inInterp(scopesAt(more[2], ' five')), `${lang}: three levels deep comes back out`, scopesAt(more[2], ' five'));
  ok(isStr(scopesAt(more[5], '#id')) && !scopesAt(more[5], '#id').includes('comment'), `${lang}: a # on a line inside a multi-line string is text`, scopesAt(more[5], '#id'));
  ok(more[6].openAfter === 0 && scopesAt(more[7], '# a comment').includes('comment'), `${lang}: after the multi-line string, a comment is a comment`, scopesAt(more[7], '# a comment'));
  ok(more[7].openAfter === 0 && !isStr(scopesAt(more[8], 'e')), `${lang}: a quote inside a comment opens no string`, scopesAt(more[8], 'e'));
}

// ---- the server: the same text, over LSP ---------------------------------------
console.log('== server ==');
function lsp(file, requests) {
  return new Promise((resolve) => {
    const srv = spawn(process.execPath, [path.join(ROOT, 'server/server.js')], { stdio: ['pipe', 'pipe', 'ignore'] });
    let buf = Buffer.alloc(0);
    const pending = new Map();
    let id = 1;
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
      send({ jsonrpc: '2.0', method: 'textDocument/didOpen',
             params: { textDocument: { uri, languageId: 'fpr', version: 1, text: fs.readFileSync(file, 'utf8') } } });
      const got = [];
      for (const [method, params] of requests) got.push((await req(method, { textDocument: { uri }, ...params })).result);
      srv.kill();
      resolve(got);
    })();
  });
}

(async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fpr-strings-'));
  const file = path.join(dir, 'strings.fpr');
  const src = [
    'unsafe base.',                                       // 1
    'avg st = st.',                                       // 2
    statLine.replace(/S\.pad(Left|Right) \d+ " " /g, 'avg '), // 3: the same nesting, names this file defines
    'css = "',                                            // 4
    '.a\\{color:#fff}',                                   // 5
    'notADef = 1',                                        // 6: inside the string
    '#id\\{x:1}',                                         // 7
    '".',                                                 // 8
    'after x = avg x.',                                   // 9
  ];
  fs.writeFileSync(file, src.join('\n') + '\n');
  const col = (line, needle, nth) => { let i = -1; for (let k = 0; k <= (nth || 0); k++) i = src[line - 1].indexOf(needle, i + 1); return i; };
  const [symbols, defAfter, defInside] = await lsp(file, [
    ['textDocument/documentSymbol', {}],
    ['textDocument/definition', { position: { line: 8, character: col(9, 'avg') + 1 } }],
    ['textDocument/definition', { position: { line: 2, character: col(3, 'avg st}') + 1 } }],
  ]);
  const names = (symbols || []).map((s) => s.name);
  ok(names.includes('after') && names.includes('statLine') && names.includes('css'), 'the declarations around the strings are in the outline', names.join(' '));
  ok(!names.includes('notADef'), 'a line inside a multi-line string is not a declaration', names.join(' '));
  const lineOf = (d) => { const one = Array.isArray(d) ? d[0] : d; return one ? (one.range || one.targetRange).start.line + 1 : null; };
  ok(lineOf(defAfter) === 2, 'a name after the strings resolves to its definition', JSON.stringify(defAfter));
  ok(lineOf(defInside) === 2, 'a name INSIDE a nested interpolation is code: it resolves too', JSON.stringify(defInside));
  fs.rmSync(dir, { recursive: true, force: true });
  console.log(failed ? `\n${failed} FAILED` : '\nstrings: all passed');
  process.exit(failed ? 1 : 0);
})();
