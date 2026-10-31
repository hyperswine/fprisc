#!/usr/bin/env node
// server.js -- a minimal, zero-dependency LSP server for FP-RISC (.fpr).
// v0.2: the sol-lang server core upstreamed. Scope: the open module, plus a
// BEST-EFFORT reach into modules imported with `X = use "path"` --
// if the file can't be found or parsed, the feature silently degrades
// to single-module behaviour rather than erroring.
//
// Features:
//   documentSymbol   outline (clauses grouped, sigs folded, Type ctors,
//                    Struct/Sig members, use aliases, `>` transaction blocks)
//   definition       top-level names, ctors, members, locals; through
//   declaration      use-aliases and re-export aliases (M = mx.M) into
//                    the imported file, alias chase depth-limited
//   hover            leading `#` doc comments on any decl/member (local
//                    or imported), plus baked-in builtin docs extracted
//                    from compiler type tables and preludes (server/builtins.json)
//   diagnostics      the compiler's own report on open and save
//                    (compiler-check.js; `fpr compile --check-only`, or the
//                    bytecode compile for .sol), plus best-effort scanner
//                    hints while typing: unresolved names, a qualified
//                    member a resolved module does not define.
//   semanticTokens   conservative: only identifiers the line parser is
//                    sure about (decl names + their use sites, ctors,
//                    module aliases, builtins, clause params). Unknown
//                    identifiers are left to the TextMate grammar.

'use strict';

const fs = require('fs');
const path = require('path');
const { caseBindings } = require('./case-bindings');
const { unsafeCalls } = require('./unsafe-calls');
const { createChecker, compilerHome, projectRoot } = require('./compiler-check');
const { createRemarkRunner } = require('./optimization-remarks');

const BUILTINS = (() => {
  try { return JSON.parse(fs.readFileSync(path.join(__dirname, 'builtins.json'), 'utf8')); }
  catch (e) { return {}; }
})();

// The realtime escapes are a .sol tier (they leave the transaction); the
// database marks them, so the set is derived rather than hardcoded.
const REALTIME = new Set(
  Object.keys(BUILTINS).filter((k) => /^Realtime/.test(BUILTINS[k].section || ''))
);

// ONE server, TWO languages. The extension of the file being edited decides
// how `use "x"` resolves -- this was pinned to '.fpr', so in every .sol file
// the import resolved to a .sol path with .fpr glued on, no module was ever
// found, and cross-module hovers, definitions and the member diagnostic all
// silently degraded. Resolution now tries the importer's own extension first
// and the sibling second, because the two profiles do import across.
const EXTS = ['.fpr', '.sol'];
function extOf(uri) { return (uri || '').endsWith('.sol') ? '.sol' : '.fpr'; }
// the fence language for hovers, so .sol content is not labelled fpr
function fenceOf(uri) { return extOf(uri) === '.sol' ? 'sol' : 'fpr'; }
// a builtin exists in this profile? (entries are tagged fpr | sol | both)
function builtinFor(uri, name) {
  // Compiler tables spell I32.+; surface syntax can spell I32.(+).
  // Prelude record members are stored in the latter form. Accept both.
  const operator = name.match(/^([A-Za-z_][\w']*)\.(?:\(([-+*/%^!<>=&|:~]+)\)|([-+*/%^!<>=&|:~]+))$/);
  const alternate = operator && (operator[2] ? `${operator[1]}.${operator[2]}` : `${operator[1]}.(${operator[3]})`);
  const b = BUILTINS[name] || (alternate && BUILTINS[alternate]);
  if (!b) return null;
  const want = extOf(uri) === '.sol' ? 'sol' : 'fpr';
  if (b.profile && b.profile !== 'both' && b.profile !== want) return null;
  return b.variants && b.variants[want] ? { ...b, ...b.variants[want] } : b;
}

// ---------------------------------------------------------------------------
// transport (identical to fpr-lang)
// ---------------------------------------------------------------------------

let buffer = Buffer.alloc(0);
process.stdin.on('data', (chunk) => {
  buffer = Buffer.concat([buffer, chunk]);
  while (true) {
    const headerEnd = buffer.indexOf('\r\n\r\n');
    if (headerEnd === -1) return;
    const header = buffer.slice(0, headerEnd).toString('ascii');
    const m = header.match(/Content-Length:\s*(\d+)/i);
    if (!m) { buffer = buffer.slice(headerEnd + 4); continue; }
    const len = parseInt(m[1], 10);
    const start = headerEnd + 4;
    if (buffer.length < start + len) return;
    const body = buffer.slice(start, start + len).toString('utf8');
    buffer = buffer.slice(start + len);
    let msg;
    try { msg = JSON.parse(body); } catch (e) { continue; }
    handle(msg);
  }
});

function send(obj) {
  const body = Buffer.from(JSON.stringify(obj), 'utf8');
  process.stdout.write(`Content-Length: ${body.length}\r\n\r\n`);
  process.stdout.write(body);
}
function reply(id, result) { send({ jsonrpc: '2.0', id, result }); }
function replyErr(id, code, message) { send({ jsonrpc: '2.0', id, error: { code, message } }); }
function notifyOut(method, params) { send({ jsonrpc: '2.0', method, params }); }

// ---------------------------------------------------------------------------
// documents + imported-module cache
// ---------------------------------------------------------------------------

const docs = new Map();      // uri -> analysis (open editors)
let moduleSettings = {};
let rootPath = '';           // from initialize: the workspace root

// ---------------------------------------------------------------------------
// workspace symbols (Ctrl+T): every top-level definition in every .fpr/.sol
// under the workspace root.  Same analyzer as open docs; cached by mtime;
// vendor/build dirs skipped; file count capped so giant trees stay snappy.
// ---------------------------------------------------------------------------
let workspaceRoots = [];
const workspaceIndex = require('./workspace-index').createIndex({ analyze,
  onLimit: limit => notifyOut('window/logMessage', { type: 2, message: `FP-RISC: workspace index reached its ${limit}-file limit.` }) });
function workspaceSymbols(query) { return workspaceIndex.symbols(query); }
const modCache = new Map();  // abs path -> { mtimeMs, analysis }

function uriToPath(uri) {
  if (!uri || !uri.startsWith('file://')) return null;
  return decodeURIComponent(uri.slice('file://'.length));
}
function pathToUri(p) {
  return 'file://' + p.split(path.sep).join('/').split('/').map(encodeURIComponent).join('/').replace(/^/, '');
}

// `use "dir/name#hash"`: the part before `#` finds the file, the hash names
// the version. Resolution follows the compiler: importer-relative, then the
// module home, then the extra roots. A pinned use whose working file is
// missing, or whose code is no longer the pinned version, resolves to the
// committed copy in the store -- the same file the compiler reads.
function splitSpec(spec) {
  const i = spec.indexOf('#');
  return i < 0 ? { name: spec, hash: '' } : { name: spec.slice(0, i), hash: spec.slice(i + 1) };
}

// The module home as the compiler sees it: the setting, FPR_HOME, else the
// compiler's own home (so the editor and the compiler read the same std),
// else the workspace root. Recomputed when settings change.
let homeCache = null;
function moduleHome() {
  if (homeCache === null)
    homeCache = moduleSettings.home || process.env.FPR_HOME || compilerHome(moduleSettings) || rootPath || '';
  return homeCache;
}

function modulePath(fromUri, usePath) {
  const from = uriToPath(fromUri);
  if (!from) return null;
  const { name, hash } = splitSpec(usePath);
  const own = extOf(fromUri);
  const tries = EXTS.some((e) => name.endsWith(e))
    ? [name]
    : [name + own, ...EXTS.filter((e) => e !== own).map((e) => name + e)];
  const extra = [...(moduleSettings.modulePaths || []), ...(process.env.FPR_PATH || '').split(path.delimiter)].filter(Boolean);
  const roots = [path.dirname(from), moduleHome(), ...extra].filter(Boolean);
  let found = null;
  for (const root of roots) {
    for (const t of tries) {
      const p = path.isAbsolute(t) ? t : path.resolve(root, t);
      if (docs.has(pathToUri(p))) { found = p; break; }
      try { if (fs.statSync(p).isFile()) { found = p; break; } } catch (e) { /* next */ }
    }
    if (found) break;
  }
  if (hash) {
    const blob = storeBlob(from, hash);
    if (blob && (!found || !sameCode(found, blob))) return blob;
  }
  return found;
}

// the committed copy of a version: the project's store (where the compiler
// runs, see projectRoot), then the home's
function storeBlob(fromFile, hash) {
  const stores = [projectRoot(fromFile, rootPath), moduleHome()].filter(Boolean);
  for (const root of stores) {
    const p = path.join(root, '.fpr', 'store', hash + '.fpr');
    try { if (fs.statSync(p).isFile()) return p; } catch (e) { /* next */ }
  }
  return null;
}

// Is the working file still the committed code? Identity is the parsed
// tree, so comments and layout do not count: compare the comment-free
// lines with whitespace runs collapsed. (Close to, not exactly, the
// compiler's AST hash; a false "differs" only means navigation opens the
// committed copy, which is the version the compiler uses anyway.)
function sameCode(a, b) {
  const norm = (p) => {
    const open = docs.get(pathToUri(p));
    let text;
    try { text = open ? open.text : fs.readFileSync(p, 'utf8'); } catch (e) { return null; }
    const scanned = scanLines(text.split(/\r?\n/));
    // Never collapse literal whitespace: "a  b" and "a b" are different
    // pinned programs. Be conservative on any line touching a string; a
    // formatting-only mismatch safely falls back to the committed blob.
    return scanned.clean.map((line, i) => scanned.inString[i] || line.includes('"')
      ? JSON.stringify(line) : line.replace(/\s+/g, ' ').trim()).filter(Boolean).join('\n');
  };
  const na = norm(a);
  return na !== null && na === norm(b);
}

function loadModule(fromUri, usePath) {
  // best-effort: resolve relative to the importing file, in its own profile
  // first. A miss degrades to single-module behaviour rather than erroring.
  const p = modulePath(fromUri, usePath);
  if (!p) return null;
  const opened = docs.get(pathToUri(p));
  if (opened) return opened;
  try {
    const st = fs.statSync(p);
    const hit = modCache.get(p);
    if (hit && hit.mtimeMs === st.mtimeMs) return hit.analysis;
    const text = fs.readFileSync(p, 'utf8');
    const analysis = analyze(pathToUri(p), text);
    modCache.set(p, { mtimeMs: st.mtimeMs, analysis });
    return analysis;
  } catch (e) { return null; }
}

// ---------------------------------------------------------------------------
// analysis: line-shaped scan of one module
// ---------------------------------------------------------------------------

const SymbolKind = {
  Module: 2, Namespace: 3, Class: 5, Method: 6, Field: 8,
  Constructor: 9, Enum: 10, Interface: 11, Function: 12,
  Variable: 13, Constant: 14, EnumMember: 22, Struct: 23, Event: 24,
};

// ONE scan of a module's lines that knows what a string can hold.  A string
// literal may span lines, and "{...}" inside it is an INTERPOLATION: code, which
// can hold strings again ("{pad 6 " " "{n}"}" nests to any depth) and braces of
// its own (a record literal).  Toggling on every quote, as this used to, read
// the code inside a nested interpolation as text and the text around it as
// code; and a line inside a multi-line string (CSS, a script) was cut at its
// first `#` as if that began a comment.
//   clean[i]  the line without its comment (string contents kept)
//   code[i]   the same length, literal TEXT blanked: quotes kept, interpolated
//             code kept (it is code: its names are uses), its braces blanked
//   inString[i]  does the line START inside a string (or its interpolation)?
const { scanLines } = require('./source-scan');
function stripComment(line) { return scanLines([line]).clean[0]; }
function blankStrings(line) { return scanLines([line]).code[0]; }

function analyze(uri, text) {
  const lines = text.split(/\r?\n/);
  const { clean, code, inString } = scanLines(lines);

  // top-level starts: identifier at col 0, or a `>` transaction opener --
  // never a line that begins inside a string, so a giant multi-line string
  // (a stylesheet, a script) does not fragment into declarations
  const starts = [];
  for (let i = 0; i < lines.length; i++)
    if (!inString[i] && /^[A-Za-z_>]/.test(lines[i])) starts.push(i);
  starts.push(lines.length);

  // doc comment above a start line: contiguous `#` lines directly over it
  function docAbove(i) {
    const out = [];
    let li = i - 1;
    while (li >= 0 && /^\s*#/.test(lines[li])) {
      out.unshift(lines[li].replace(/^\s*#\s?/, ''));
      li--;
    }
    // drop divider lines (`---- section ----`) and leading/trailing blanks
    while (out.length && /^[\s=~-]*$|^-{3,}.*-{3,}$/.test(out[0])) out.shift();
    while (out.length && /^[\s=~-]*$/.test(out[out.length - 1])) out.pop();
    return out.length ? out.join('\n') : null;
  }

  const decls = [];
  const bySig = new Map();

  for (let s = 0; s < starts.length - 1; s++) {
    const i = starts[s];
    const endLine = starts[s + 1] - 1;
    const head = clean[i];
    let m;

    // `>` transaction block
    if (head[0] === '>') {
      decls.push({
        name: '> transaction', kind: SymbolKind.Event, line: i, endLine,
        detail: head.slice(1).trim().slice(0, 40), children: [], doc: docAbove(i),
      });
      continue;
    }

    // use aliases + re-export aliases can share a line
    // (`mx = use "../lib/matrix".  M = mx.M.`)
    let consumed = false;
    {
      const useRe = /([A-Za-z_][\w']*)\s*=\s*use\s*"([^"]*)"/g;
      let um;
      while ((um = useRe.exec(head)) !== null) {
        decls.push({
          name: um[1], kind: SymbolKind.Module, line: i, endLine: i,
          col: um.index, detail: `use "${um[2]}"`, usePath: um[2],
          children: [], doc: docAbove(i),
        });
        consumed = true;
      }
      const aliasRe = /(?:^|\.\s+)([A-Za-z_][\w']*)\s*=\s*([A-Za-z_][\w']*)\.([A-Za-z_][\w']*)\s*\./g;
      let am;
      while ((am = aliasRe.exec(code[i])) !== null) {
        const col = am.index + am[0].indexOf(am[1]);
        decls.push({
          name: am[1], kind: SymbolKind.Constant, line: i, endLine: i,
          col, detail: `= ${am[2]}.${am[3]}`, aliasOf: { mod: am[2], member: am[3] },
          children: [], doc: docAbove(i),
        });
        consumed = true;
      }
    }
    if (consumed) continue;

    // Structural record type aliases, used by field paths and persistence.
    if ((m = head.match(/^([A-Z][\w']*)\s*=\s*\{/)) && /:\s*/.test(clean.slice(i, endLine + 1).join('\n'))) {
      const children = [];
      for (let li = i; li <= endLine; li++) {
        for (const f of clean[li].matchAll(/([a-z_][\w']*)\s*:(?!:)/g))
          children.push({ name: f[1], kind: SymbolKind.Field, line: li, col: f.index });
      }
      decls.push({ name: m[1], kind: SymbolKind.Struct, line: i, endLine, children, detail: 'record type', doc: docAbove(i) });
      continue;
    }
    // Type / Sig / Struct
    if ((m = head.match(/^([A-Z][\w']*)\s*(1\s*)?(?:[a-z_][\w']*\s+)*=\s*(Type|Sig|Struct|Layout)\b/))) {
      const name = m[1], form = m[3], linear = !!m[2];
      const body = clean.slice(i, endLine + 1).join('\n');
      const decl = {
        name, line: i, endLine, children: [], doc: docAbove(i),
        kind: form === 'Type' ? SymbolKind.Enum : form === 'Sig' ? SymbolKind.Interface : SymbolKind.Struct,
        detail: form + (linear ? ' (linear)' : ''),
      };
      if (form === 'Type') {
        const re = /[(|]\s*([A-Z][\w']*)/g;
        let cm;
        while ((cm = re.exec(body)) !== null) {
          const pos = offsetToLineCol(body, cm.index + cm[0].length - cm[1].length);
          decl.children.push({ name: cm[1], kind: SymbolKind.Constructor, line: i + pos.line, col: pos.col });
        }
      } else {
        const sep = form === 'Sig' || form === 'Layout' ? ':' : '=';
        for (let li = i; li <= endLine; li++) {
          const l = clean[li];
          const re = new RegExp(
            "(?:^|[{,]\\s*|^\\s+)((?:[a-z_][\\w']*)|\\((?:[^()\\s]+)\\))\\s*\\" + sep + '(?!=)', 'g');
          let mm;
          while ((mm = re.exec(l)) !== null) {
            if (li === i && mm.index === 0) continue;
            decl.children.push({
              name: mm[1].replace(/^\((.*)\)$/, '$1'),
              kind: form === 'Sig' ? SymbolKind.Method : SymbolKind.Field,
              line: li, col: mm.index + mm[0].indexOf(mm[1]),
              doc: docAbove(li),
            });
          }
        }
      }
      decls.push(decl);
      continue;
    }

    // type signature
    if ((m = head.match(/^([A-Za-z_][\w']*(?:\.[A-Za-z_][\w']*)*)\s*:(?!:)/))) {
      bySig.set(m[1], i);
      continue;
    }

    // function clause
    if ((m = head.match(/^([A-Za-z_][\w']*(?:\.[A-Za-z_][\w']*)*)\b/))) {
      const block = clean.slice(i, endLine + 1).join('\n');
      if (!/=/.test(block)) continue;
      const name = m[1];
      const valueBinding = new RegExp('^' + escapeRe(name) + '\\s*=(?!=)').test(block);
      const lambdaBinding = new RegExp('^' + escapeRe(name) + '\\s*=\\s*fn\\b').test(block);
      const kind = valueBinding && !lambdaBinding ? SymbolKind.Variable : SymbolKind.Function;
      const prev = decls[decls.length - 1];
      if (prev && prev.kind === SymbolKind.Function && prev.name === name) {
        prev.endLine = endLine;
        prev.clauses.push(i);
      } else {
        decls.push({
          name, kind, line: i, endLine,
          detail: '', children: [], doc: docAbove(i), clauses: [i],
        });
      }
      continue;
    }
  }

  for (const d of decls) {
    if (d.clauses && bySig.has(d.name)) {
      d.sigLine = bySig.get(d.name);
      d.detail = clean[d.sigLine].trim().replace(/\.$/, '');
      if (!d.doc) d.doc = docAbove(d.sigLine);
    }
  }
  for (const [name, line] of bySig) {
    if (!decls.some((dd) => dd.name === name)) {
      decls.push({ name, kind: clean[line].includes('->') ? SymbolKind.Function : SymbolKind.Variable, line, sigLine: line, endLine: line, detail: clean[line].trim(), children: [], doc: docAbove(line) });
    }
  }
  decls.sort((a, b) => a.line - b.line || (a.col || 0) - (b.col || 0));

  return { uri, text, lines, clean, code, decls };
}

function offsetToLineCol(s, off) {
  let line = 0, col = 0;
  for (let i = 0; i < off; i++) {
    if (s[i] === '\n') { line++; col = 0; } else col++;
  }
  return { line, col };
}

// ---------------------------------------------------------------------------
// lookups
// ---------------------------------------------------------------------------

function wordAt(doc, pos) {
  const line = doc.clean[pos.line] || '';
  // Qualified operator fields use both I32.+ and Int.(+) spellings.
  const operators = /\b([A-Za-z_][\w']*)\.(\([-+*/%^!<>=&|:~]+\)|[-+*/%^!<>=&|:~]+)/g;
  for (const match of line.matchAll(operators)) {
    const start = match.index + match[1].length + 1;
    if (pos.character >= start && pos.character < match.index + match[0].length)
      return { word: match[2], qualifier: match[1], start, end: match.index + match[0].length };
  }
  const isW = (c) => /[\w']/.test(c);
  let a = pos.character, b = pos.character;
  while (a > 0 && isW(line[a - 1])) a--;
  while (b < line.length && isW(line[b])) b++;
  if (a === b) return null;
  const word = line.slice(a, b);
  let qualifier = null;
  if (a >= 2 && line[a - 1] === '.') {
    let qa = a - 1;
    while (qa > 0 && /[\w'.]/.test(line[qa - 1])) qa--;
    if (qa < a - 1) qualifier = line.slice(qa, a - 1);
  }
  return { word, qualifier, start: a, end: b };
}

function loc(uri, line, colStart, colEnd) {
  return { uri, range: { start: { line, character: colStart }, end: { line, character: colEnd } } };
}
function nameColOnLine(doc, line, name, prefer) {
  if (prefer !== undefined) return prefer;
  const l = doc.clean[line] || '';
  const m = l.match(new RegExp("(?:^|[^\\w'])(" + escapeRe(name) + ")(?![\\w'])"));
  return m ? m.index + m[0].indexOf(m[1]) : 0;
}
function escapeRe(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

// resolve a name in `doc` to { doc, decl, member? }, chasing use/alias
// links up to `depth` hops. Every failure returns null -- callers fall
// back to more local answers.
function resolveName(doc, name, depth) {
  if (depth <= 0) return null;
  const d = doc.decls.find((x) => x.name === name);
  if (!d) return null;
  if (d.usePath) {
    const target = loadModule(doc.uri, d.usePath);
    return target ? { kind: 'module', doc: target, decl: d } : { kind: 'local', doc, decl: d };
  }
  if (d.aliasOf) {
    const mod = resolveName(doc, d.aliasOf.mod, depth - 1);
    if (mod && mod.kind === 'module') {
      const remote = mod.doc.decls.find((x) => x.name === d.aliasOf.member);
      if (remote) return { kind: 'remote', doc: mod.doc, decl: remote };
    }
    return { kind: 'local', doc, decl: d };
  }
  return { kind: 'local', doc, decl: d };
}

// Conservative local shadowing guard for source/type hovers and namespaces.
// Unresolved local types are omitted instead of borrowing a global's type.
function locallyBound(doc, name, pos) {
  if (!doc.localScopes) {
    doc.localScopes = [];
    for (const d of doc.decls) for (let i = 0; i < (d.clauses || []).length; i++) {
      const from = d.clauses[i], to = i + 1 < d.clauses.length ? d.clauses[i + 1] - 1 : d.endLine;
      doc.localScopes.push({ from, to, binders: clauseBinders(doc.code[from], d.name), locals: clauseLocals(doc, from, to) });
    }
    doc.caseScope = caseBindings(doc.text);
    doc.lineOffsets = [0];
    for (let i = 0; i < doc.text.length; i++) if (doc.text[i] === '\n') doc.lineOffsets.push(i + 1);
  }
  if (doc.caseScope(name, doc.lineOffsets[pos.line] + pos.character)) return true;
  const scope = doc.localScopes.find(s => pos.line >= s.from && pos.line <= s.to);
  if (!scope) return false;
  if (scope.binders.has(name)) return true;
  if (scope.locals.some(b => b.name === name && b.visible &&
    (pos.line > b.visible.line || (pos.line === b.visible.line && pos.character >= b.visible.col)))) return true;
  // Lambda scopes are not yet represented by the scanner. Suppress a global
  // answer if a same-named lambda parameter occurs earlier in this clause.
  const before = doc.code.slice(scope.from, pos.line).concat((doc.code[pos.line] || '').slice(0, pos.character)).join('\n');
  return [...before.matchAll(/\bfn\s+([^=]*?)\s*->/g)].some(m => m[1].split(/\s+/).includes(name));
}

function findDefinition(uri, doc, pos, wantDeclaration) {
  const w = wordAt(doc, pos);
  if (!w) return null;
  const { word, qualifier } = w;

  if (qualifier) {
    if (locallyBound(doc, qualifier.split('.')[0], pos)) return null;
    const direct = doc.decls.find(d => d.name === `${qualifier}.${word}`);
    if (direct) return loc(uri, wantDeclaration && direct.sigLine !== undefined ? direct.sigLine : direct.line, direct.col || 0, (direct.col || 0) + direct.name.length);
    const r = resolveName(doc, qualifier, 3);
    if (r) {
      const owner = r.kind === 'module' ? null : r.decl;
      if (r.kind === 'module') {
        // qualifier is a use-alias: member is a top-level of the imported file
        const remote = r.doc.decls.find((x) => x.name === word);
        if (remote) return loc(r.doc.uri, remote.line, nameColOnLine(r.doc, remote.line, remote.name, remote.col), nameColOnLine(r.doc, remote.line, remote.name, remote.col) + word.length);
        // fall back to the use line itself
        return loc(uri, r.decl.line, r.decl.col || 0, (r.decl.col || 0) + qualifier.length);
      }
      if (owner) {
        const member = owner.children.find((c) => c.name === word);
        if (member) return loc(r.doc.uri, member.line, member.col, member.col + word.length);
        const col = nameColOnLine(r.doc, owner.line, owner.name, owner.col);
        return loc(r.doc.uri, owner.line, col, col + owner.name.length);
      }
    }
    const foreign = doc.decls.find(d => d.name === `${qualifier}.${word}`);
    if (foreign) return loc(uri, foreign.line, 0, foreign.name.length);
    // unknown qualifier (Vec.*, Str.* builtins): fall through
  }

  const top = doc.decls.find((d) => d.name === word);
  if (top) {
    if (wantDeclaration && top.sigLine !== undefined) return loc(uri, top.sigLine, 0, word.length);
    const col = nameColOnLine(doc, top.line, word, top.col);
    return loc(uri, top.line, col, col + word.length);
  }

  for (const d of doc.decls) {
    const c = d.children.find((cc) => cc.name === word);
    if (c) return loc(uri, c.line, c.col, c.col + word.length);
  }

  // best-effort local bind / clause param, inside the enclosing block
  const encl = doc.decls.find((d) => pos.line >= d.line && pos.line <= d.endLine);
  if (encl) {
    for (let li = pos.line; li >= encl.line; li--) {
      const l = doc.code[li];
      const eq = l.search(/=[^=<>]/);
      if (eq === -1) continue;
      const lhs = l.slice(0, eq);
      let m = null, best = null;
      const re = new RegExp("(?:^|[\\s(,>])(" + escapeRe(word) + ")(?=[\\s),])", 'g');
      while ((m = re.exec(lhs)) !== null) best = m;
      if (best) {
        const col = best.index + best[0].indexOf(word);
        if (li === pos.line && col === w.start) continue;
        return loc(uri, li, col, col + word.length);
      }
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// hover
// ---------------------------------------------------------------------------

function declHeadLine(d, srcDoc) {
  if (d.sigLine !== undefined) return srcDoc.clean[d.sigLine].trim();
  return (srcDoc.clean[d.line] || '').trim().replace(/\s+/g, ' ').slice(0, 100);
}

function hoverFor(uri, doc, pos) {
  const raw = doc.lines[pos.line] || '';
  // Non-word builtin syntax must be recognized as a token too.
  const special = /^\s*#:/.exec(raw);
  if (special && pos.character >= special[0].length - 2 && pos.character < special[0].length) {
    return { contents: { kind: 'markdown', value: renderBuiltin('#:', builtinFor(uri, '#:'), uri) } };
  }
  const clean = doc.clean[pos.line] || '';
  const symbol = /[-+*/%^!<>=&|:~]+/g;
  for (const match of clean.matchAll(symbol)) {
    if (pos.character < match.index || pos.character >= match.index + match[0].length) continue;
    // '>' describes a Sol top-level effect only, never a comparison.
    if (match[0] === '>' && clean.slice(0, match.index).trim()) continue;
    if (match.index && /[.]/.test(clean[match.index - 1])) continue;
    const b = builtinFor(uri, match[0]);
    if (b) return { contents: { kind: 'markdown', value: renderBuiltin(match[0], b, uri) } };
  }

  // typed holes: '?' is not a word character -- detect ?name / ?? around
  // the cursor and hover their doc entries
  {
    const line = doc.lines[pos.line] || '';
    let a = pos.character;
    while (a > 0 && /[\w'?]/.test(line[a - 1])) a--;
    const m = /^(\?\?|\?[a-z][\w']*)/.exec(line.slice(a));
    if (m && pos.character <= a + m[0].length) {
      const key = m[0] === '??' ? '??' : '?name';
      const b = builtinFor(uri, key);
      if (b) {
        const range = { start: { line: pos.line, character: a }, end: { line: pos.line, character: a + m[0].length } };
        return { contents: { kind: 'markdown', value: '```\n' + b.sig + '\n```\n' + b.doc }, range };
      }
    }
  }
  const literal = /@[A-Za-z_][\w.']*/g;
  let lm;
  while ((lm = literal.exec(doc.lines[pos.line] || ''))) {
    if (pos.character >= lm.index && pos.character < lm.index + lm[0].length) {
      const b = builtinFor(uri, '@');
      return { contents: { kind: 'markdown', value: renderBuiltin('@', b, uri) } };
    }
  }
  const w = wordAt(doc, pos);
  if (!w) return null;
  const { word, qualifier } = w;
  const range = { start: { line: pos.line, character: w.start }, end: { line: pos.line, character: w.end } };
  const md = (s) => ({ contents: { kind: 'markdown', value: s }, range });

  if (locallyBound(doc, (qualifier || word).split('.')[0], pos)) return null;

  // 1. qualified through a module/alias
  if (qualifier) {
    const r = resolveName(doc, qualifier, 3);
    if (r) {
      if (r.kind === 'module') {
        const remote = r.doc.decls.find((x) => x.name === word);
        if (remote) return md(renderDecl(remote, r.doc, `${qualifier}.${word}`, uri));
      } else {
        const member = r.decl.children && r.decl.children.find((c) => c.name === word);
        if (member) {
          const memberDoc = member.doc ? '\n\n' + member.doc : '';
          const line = (r.doc.clean[member.line] || '').trim().replace(/,\s*$/, '');
          return md('```' + fenceOf(uri) + '\n' + line + '\n```' + memberDoc + `\n\n*member of \`${r.decl.name}\`*`);
        }
      }
    }
    const declared = doc.decls.find(d => d.name === `${qualifier}.${word}`);
    if (declared) return md(renderDecl(declared, doc, declared.name, uri));
    if (r) return null; // A source namespace shadows the builtin namespace.
    const q = builtinFor(uri, `${qualifier}.${word}`);
    if (q) return md(renderBuiltin(`${qualifier}.${word}`, q, uri));
  }

  // 2. local decl
  const top = doc.decls.find((d) => d.name === word);
  if (top) return md(renderDecl(top, doc, word, uri));

  // 3. member of any local Type/Sig/Struct
  for (const d of doc.decls) {
    const c = d.children.find((cc) => cc.name === word);
    if (c) {
      const line = (doc.clean[c.line] || '').trim();
      return md('```' + fenceOf(uri) + '\n' + line + '\n```' + (c.doc ? '\n\n' + c.doc : '') + `\n\n*member of \`${d.name}\`*`);
    }
  }

  // 4. builtin
  const b = builtinFor(uri, word);
  if (b) return md(renderBuiltin(word, b, uri));

  return null;
}

function renderDecl(d, srcDoc, label, uri) {
  let head = declHeadLine(d, srcDoc);
  if (d.sigLine === undefined && !d.usePath) {
    const file = uriToPath(srcDoc.uri);
    for (const result of compilerDiags.values()) {
      const type = result.editor && result.editor.types.find(t => t.file === file && t.start.line === d.line);
      if (type) { head = `${label} : ${type.type}\n${head}`; break; }
    }
  }
  if (d.usePath) head = `${d.name} = use "${d.usePath}"`;
  let out = '```' + fenceOf(uri || srcDoc.uri) + '\n' + head + '\n```';
  if (d.doc) out += '\n\n' + d.doc;
  if (d.usePath) {
    const target = loadModule(srcDoc.uri, d.usePath);
    if (target) {
      const names = target.decls.filter((x) => x.kind !== SymbolKind.Event).map((x) => x.name).slice(0, 12);
      out += `\n\n*module — exports: ${names.join(', ')}${target.decls.length > 12 ? ', …' : ''}*`;
    }
  }
  return out;
}

function renderBuiltin(name, b, uri) {
  const fence = fenceOf(uri);
  let out = '```' + fence + '\n' + b.sig.replace(/\s+•\s+/g, '\n') + '\n```';
  if (b.doc) out += '\n\n' + b.doc;
  const where = b.profile === 'both' ? 'fpr + sol' : b.profile;
  out += `\n\n*builtin (${where}) — ${b.section}*`;
  if (REALTIME.has(name)) {
    out = '⚠ **realtime escape — bypasses the transaction**\n\n' + out;
  }
  return out;
}

// ---------------------------------------------------------------------------
// diagnostics -- CONFIDENT ONLY. The single check: `X.y` where X is a use
// alias whose file was found AND parsed to a non-trivial module (>= 3
// decls), and y is neither a top-level decl nor any decl's child there.
// Everything the parser is less sure about stays silent.
// ---------------------------------------------------------------------------

// The scanner reports names it cannot resolve, not compiler errors. Dynamic
// record members and type-variable positions are deliberately left to the compiler.
function unresolvedDiagnostics(doc) {
  const covered = new Set();
  const data = semanticTokens(doc).data;
  let line = 0, col = 0;
  for (let i = 0; i < data.length; i += 5) {
    line += data[i]; col = data[i] ? data[i + 1] : col + data[i + 1];
    covered.add(`${line}:${col}`);
  }
  const masked = doc.text.replace(/#[^\n]*|"(?:\\[\s\S]|[^"\\])*"/g,
    text => text.replace(/[^\r\n]/g, ' ')).split(/\r?\n/);
  const types = new Set(['Int', 'List', 'String', 'Bool', 'Unit', 'F32', 'F64', 'I32', 'I64', 'Word', 'Addr', 'Vector', 'SString', 'Result', 'True', 'False', 'Nil', 'Cons', 'Ok', 'Err']);
  const namespaces = new Set([...Object.keys(BUILTINS).filter(n => builtinFor(doc.uri, n) && n.includes('.')), ...doc.decls.map(d => d.name).filter(n => n.includes('.'))].map(n => n.split('.')[0]));
  const diagnostics = [];
  for (const d of doc.decls) {
    if (!d.clauses) continue;
    for (let ci = 0; ci < d.clauses.length; ci++) {
      const from = d.clauses[ci];
      const to = ci + 1 < d.clauses.length ? d.clauses[ci + 1] - 1 : d.endLine;
      const block = masked.slice(from, to + 1).join('\n');
      // These constructs are valid bindings even where semantic highlighting
      // does not yet model their scope. Avoid claiming they are undefined.
      const additional = new Set();
      for (const m of block.matchAll(/\bfn\s+([a-z_][\w']*(?:\s+[a-z_][\w']*)*)\s*->/g))
        for (const name of m[1].split(/\s+/)) additional.add(name);
      for (const m of block.matchAll(/(?:^|[;\n]|->)\s*([a-z_][\w']*(?:\s+[a-z_][\w']*)*)\s*=(?!=)/g))
        for (const name of m[1].split(/\s+/)) additional.add(name);
      for (const m of block.matchAll(/(?:^|[;\n]|->)\s*([([{][^=;\n]+)=(?!=)/g))
        for (const name of m[1].match(/[a-z_][\w']*/g) || []) additional.add(name);
      for (let li = from; li <= to; li++) {
        const source = masked[li] || '';
        for (const m of source.matchAll(/[A-Za-z_][\w']*/g)) {
          const name = m[0], col = m.index;
          if (covered.has(`${li}:${col}`) || KEYWORDS.has(name) || types.has(name) || namespaces.has(name) || name === '_' || additional.has(name)) continue;
          // Field selections need inferred record types. Path literals, holes,
          // record labels and type annotations are not free expression names.
          const before = source.slice(0, col), after = source.slice(col + name.length);
          if (/[0-9]$/.test(before)) continue;
          if (/[.@?]$/.test(before) || /(?:^|[^\w'])[@?][\w.']*$/.test(before + name)) continue;
          if (/^\s*:(?!:)/.test(after) || /^\s*=(?!=)/.test(after)) continue;
          if (li === from && col === nameColOnLine(doc, from, d.name)) continue;
          diagnostics.push({
            range: { start: { line: li, character: col }, end: { line: li, character: col + name.length } },
            severity: 3, source: 'fpr', code: 'unresolved-name',
            message: `Cannot resolve '${name}' (best-effort source scan).`,
          });
        }
      }
    }
  }
  return diagnostics;
}

// ---------------------------------------------------------------------------
// compiler diagnostics: checked file -> Map(path -> diags). A check of one
// file can report into another (an imported module), so a file's compiler
// diagnostics are the union over every check that named it.
// ---------------------------------------------------------------------------

const compilerDiags = new Map();

function compilerDiagsFor(file) {
  const all = new Map();
  for (const byPath of compilerDiags.values()) for (const d of byPath.get(file) || []) all.set(JSON.stringify(d), d);
  return [...all.values()];
}

function checkEnabled() { return moduleSettings.check !== false; }

function readOpen(file) {
  const direct = docs.get(pathToUri(file));
  if (direct) return direct.text;
  let real; try { real = fs.realpathSync(file); } catch (_) { return null; }
  for (const [uri, doc] of docs) {
    try { if (fs.realpathSync(uriToPath(uri)) === real) return doc.text; } catch (_) { /* absent */ }
  }
  return null;
}

const checker = createChecker({
  settings: () => moduleSettings,
  workspaceRoot: () => rootPath,
  readOpen,
  readText: (p) => {
    try { return fs.readFileSync(p, 'utf8'); } catch (e) { /* unsaved or gone */ }
    const open = docs.get(pathToUri(p));
    return open ? open.text : null;
  },
  onResult: (file, byPath) => {
    const before = compilerDiags.get(file);
    if (byPath && docs.has(pathToUri(file))) compilerDiags.set(file, byPath);
    else compilerDiags.delete(file);
    republish(new Set([...(before ? before.keys() : []), ...(byPath ? byPath.keys() : []), file]));
  },
  onMissing: (compiler, e) => notifyOut('window/showMessage', {
    type: 2,
    message: `FP-RISC: could not run the compiler '${compiler}' (${e.code || e.message}); compiler diagnostics are off. Set fpr.compilerPath or fpr.home.`,
  }),
});

// Explicit remark requests never replace ordinary checking diagnostics.
let remarkDiags = new Map();
const remarkRunner = createRemarkRunner({
  settings: () => moduleSettings,
  workspaceRoot: () => rootPath,
  readOpen: file => {
    const direct = docs.get(pathToUri(file));
    if (direct) return direct.text;
    let real; try { real = fs.realpathSync(file); } catch (_) { return null; }
    for (const [uri, doc] of docs) {
      try { if (fs.realpathSync(uriToPath(uri)) === real) return doc.text; } catch (_) { /* absent */ }
    }
    return null;
  },
  onResult: byPath => {
    const changed = new Set([...remarkDiags.keys(), ...byPath.keys()]);
    remarkDiags = byPath; republish(changed);
  },
  onInvalidated: message => notifyOut('fpr/remarksInvalidated', { message }),
});

function checkDoc(uri) {
  const file = uriToPath(uri);
  if (file && checkEnabled()) checker.check(file);
}

function dropCheck(uri) {
  const file = uriToPath(uri);
  if (!file) return;
  checker.forget(file);
  const before = compilerDiags.get(file);
  compilerDiags.delete(file);
  if (before) republish(new Set(before.keys()));
}

function republish(files) {
  for (const f of files) {
    const uri = pathToUri(f);
    const doc = docs.get(uri);
    if (doc) publishDiagnostics(uri, doc);
    else notifyOut('textDocument/publishDiagnostics', { uri, diagnostics: [] });
  }
}

function publishDiagnostics(uri, doc) {
  const diags = moduleSettings.unresolvedNames === false ? [] : unresolvedDiagnostics(doc);
  if (moduleSettings.unsafeCalls === true) diags.push(...unsafeCalls(doc, { clauseBinders, clauseLocals, resolveName, builtinFor, caseBindings }));
  const qre = /([A-Za-z_][\w']*)\.([a-z_][\w']*)/g;
  for (let li = 0; moduleSettings.unresolvedNames !== false && li < doc.code.length; li++) {
    let m;
    qre.lastIndex = 0;
    while ((m = qre.exec(doc.code[li])) !== null) {
      const [_, qual, member] = m;
      const alias = doc.decls.find((d) => d.name === qual && d.usePath);
      if (!alias) {
        const namespace = Object.keys(BUILTINS).some(n => n.startsWith(qual + '.') && builtinFor(uri, n));
        if (namespace && !resolveName(doc, qual, 3) && !builtinFor(uri, qual + '.' + member) && !doc.decls.some(d => d.name === qual + '.' + member)) {
          const col = m.index + qual.length + 1;
          diags.push({ range: { start: { line: li, character: col }, end: { line: li, character: col + member.length } }, severity: 3, source: 'fpr', code: 'unresolved-name', message: `Cannot resolve '${qual}.${member}' (best-effort source scan).` });
        }
        continue;
      }
      const target = loadModule(doc.uri, alias.usePath);
      if (!target || target.decls.length < 3) continue;
      const found = target.decls.some((d) => d.name === member)
        || target.decls.some((d) => d.children.some((c) => c.name === member));
      if (found) continue;
      const col = m.index + qual.length + 1;
      diags.push({
        range: { start: { line: li, character: col }, end: { line: li, character: col + member.length } },
        severity: 3, // Information
        source: 'fpr',
        // name the file that was actually read, not a guessed extension
        message: `no top-level '${member}' found in ${path.basename(modulePath(doc.uri, alias.usePath) || alias.usePath)} (best-effort scan)`,
      });
    }
  }
  diags.push(...compilerDiagsFor(uriToPath(uri)));
  diags.push(...(remarkDiags.get(uriToPath(uri)) || []));
  notifyOut('textDocument/publishDiagnostics', { uri, diagnostics: diags });
}


// ---------------------------------------------------------------------------
// semantic tokens -- conservative. A token is emitted only when the line
// parser KNOWS what a name is: a declared name (function/type/module
// alias), a declared constructor, a builtin from builtins.json, a member
// reached through a resolvable qualifier, or a clause parameter (pattern
// binders of the enclosing clause head, incl. `p <- e` guard binds).
// Anything ambiguous emits nothing and keeps its TextMate color.
// ---------------------------------------------------------------------------

const TOKEN_TYPES = ['namespace', 'type', 'enumMember', 'function', 'parameter', 'variable', 'property'];
const TOKEN_MODS = ['defaultLibrary', 'declaration'];
const TT = Object.fromEntries(TOKEN_TYPES.map((t, i) => [t, i]));
const TM = { defaultLibrary: 1, declaration: 2 };

function declarationToken(d) {
  if (d.usePath || d.aliasOf) return TT.namespace;
  if (d.kind === SymbolKind.Function) return TT.function;
  if (d.kind === SymbolKind.Variable || d.kind === SymbolKind.Constant) return TT.variable;
  if (d.kind === SymbolKind.Constructor) return TT.enumMember;
  return TT.type;
}
function builtinToken(name) {
  // Prelude type/structure names also occur in the reference database.
  // Their presence there must not override the grammar with a function token.
  return /^[A-Z][\w']*$/.test(name) ? TT.type : TT.function;
}

const KEYWORDS = new Set(['case', 'of', 'fn', 'use', 'Type', 'Sig', 'Struct', 'Layout', 'if', 'then', 'else', 'and', 'or', 'profile', 'unsafe', 'measure']);

// pattern binders of one clause head line: lowercase idents in the
// pattern region (before the first top-level `=` body marker), except
// guard EXPRESSIONS -- in `| e1, p <- e2` only p binds; e1/e2 are uses.
function clauseBinders(headLine, fnName) {
  const binders = new Set();
  // body starts at an `=` that is not ==, <=, >=, <-
  let eq = -1;
  for (let i = 0; i < headLine.length; i++) {
    if (headLine[i] === '=' && headLine[i + 1] !== '=' &&
        headLine[i - 1] !== '=' && headLine[i - 1] !== '<' && headLine[i - 1] !== '>' && headLine[i - 1] !== '!') {
      eq = i; break;
    }
  }
  const head = eq === -1 ? headLine : headLine.slice(0, eq);
  const bar = head.indexOf('|');
  const patPart = bar === -1 ? head : head.slice(0, bar);
  const collect = (txt) => {
    const re = /[a-z_][\w']*/g;
    let m;
    while ((m = re.exec(txt)) !== null) {
      if (m[0] !== fnName && !KEYWORDS.has(m[0])) binders.add(m[0]);
    }
  };
  collect(patPart.replace(new RegExp('^\\s*' + escapeRe(fnName) + "(?![\\w'])"), ''));
  if (bar !== -1) {
    // guards: only the LHS of each `<-` binds
    for (const g of head.slice(bar + 1).split(',')) {
      const arrow = g.indexOf('<-');
      if (arrow !== -1) collect(g.slice(0, arrow));
    }
  }
  return binders;
}

// Simple sequential bindings in the outer clause body. Delimiter tracking keeps
// record fields and bindings in nested expressions out of the enclosing scope.
function clauseLocals(doc, from, to) {
  const body = doc.code.slice(from, to + 1).join('\n');
  const assignment = /(?<![=<>!])=(?!=)/.exec(body);
  if (!assignment) return [];
  const locals = [];
  let depth = 0, start = true, pending = null;
  for (let i = assignment.index + 1; i < body.length; i++) {
    const c = body[i];
    if (start && depth === 0 && !/\s/.test(c)) {
      const match = /^([a-z_][\w']*)\s*=(?!=)/.exec(body.slice(i));
      if (match && !KEYWORDS.has(match[1])) {
        const site = offsetToLineCol(body, i);
        pending = { name: match[1], line: from + site.line, col: site.col };
        locals.push(pending);
      }
      start = false;
    }
    if ('([{'.includes(c)) depth++;
    else if (')]}'.includes(c)) depth--;
    else if (c === ';' && depth === 0) {
      if (pending) {
        const visible = offsetToLineCol(body, i + 1);
        pending.visible = { line: from + visible.line, col: visible.col };
        pending = null;
      }
      start = true;
    }
  }
  return locals;
}

function semanticTokens(doc) {
  const caseBindingAt = caseBindings(doc.text);
  const lineOffsets = [0];
  for (let i = 0; i < doc.text.length; i++) if (doc.text[i] === '\n') lineOffsets.push(i + 1);
  // absolute tokens [line, col, len, type, mods], sorted later, then delta-encoded
  const toks = [];
  const push = (line, col, len, type, mods) => toks.push([line, col, len, type, mods || 0]);

  // index the module's names once
  const byName = new Map();
  for (const d of doc.decls) {
    if (!byName.has(d.name)) byName.set(d.name, d);
  }
  const ctorOwner = new Map();
  for (const d of doc.decls) for (const c of d.children) {
    if (c.kind === SymbolKind.Constructor && !ctorOwner.has(c.name)) ctorOwner.set(c.name, d);
  }

  // per-clause binder sets, precomputed
  const clauseRanges = []; // { from, to, binders }
  for (const d of doc.decls) {
    if (!d.clauses) continue;
    for (let ci = 0; ci < d.clauses.length; ci++) {
      const from = d.clauses[ci];
      const to = ci + 1 < d.clauses.length ? d.clauses[ci + 1] - 1 : d.endLine;
      clauseRanges.push({ from, to, binders: clauseBinders(doc.code[from], d.name), locals: clauseLocals(doc, from, to) });
    }
  }
  const clauseAt = (line) => clauseRanges.find((c) => line >= c.from && line <= c.to);

  const idRe = /[A-Za-z_][\w']*/g;
  for (let li = 0; li < doc.code.length; li++) {
    const line = doc.code[li];
    let m;
    idRe.lastIndex = 0;
    while ((m = idRe.exec(line)) !== null) {
      const word = m[0];
      const col = m.index;
      if (KEYWORDS.has(word)) continue;
      const before = line[col - 1];
      const qualified = before === '.';

      if (qualified) {
        // find the qualifier
        let qa = col - 1;
        while (qa > 0 && /[\w'.]/.test(line[qa - 1])) qa--;
        const qual = line.slice(qa, col - 1);
        if (!qual || locallyBound(doc, qual.split('.')[0], { line: li, character: qa })) continue;
        const direct = byName.get(qual + '.' + word);
        if (direct) { push(li, col, word.length, declarationToken(direct)); continue; }
        if (doc.decls.some(d => d.name.startsWith(qual + '.' + word + '.'))) { push(li, col, word.length, TT.namespace); continue; }
        const r = resolveName(doc, qual, 3);
        if (r && r.kind === 'module') {
          const remote = r.doc.decls.find((x) => x.name === word);
          if (remote) push(li, col, word.length, declarationToken(remote));
          continue;
        }
        if (r && r.decl.children && r.decl.children.some((c) => c.name === word)) {
          push(li, col, word.length, TT.property);
          continue;
        }
        if (builtinFor(doc.uri, qual + '.' + word)) push(li, col, word.length, builtinToken(qual + '.' + word), TM.defaultLibrary);
        continue;
      }

      const caseBinding = caseBindingAt(word, lineOffsets[li] + col);
      if (caseBinding) {
        push(li, col, word.length, TT.variable, caseBinding.declaration ? TM.declaration : 0);
        continue;
      }
      const scope = clauseAt(li);
      if (scope) {
        const local = [...scope.locals].reverse().find(b => b.name === word &&
          ((b.line === li && b.col === col) || (b.visible &&
            (li > b.visible.line || (li === b.visible.line && col >= b.visible.col)))));
        if (local) {
          push(li, col, word.length, TT.variable, local.line === li && local.col === col ? TM.declaration : 0);
          continue;
        }
        // Parameters also shadow builtins, including on the clause head.
        if (scope.binders.has(word)) { push(li, col, word.length, TT.parameter); continue; }
      }
      if (line[col + word.length] === '.' && doc.decls.some(d => d.name.startsWith(word + '.'))) { push(li, col, word.length, TT.namespace); continue; }
      const d = byName.get(word);
      if (d) {
        const isDeclSite = li === d.line && col === (d.col !== undefined ? d.col : nameColOnLine(doc, d.line, d.name));
        const mods = isDeclSite ? TM.declaration : 0;
        if (d.usePath || d.aliasOf) { push(li, col, word.length, TT.namespace, mods); continue; }
        if (d.kind === SymbolKind.Function || d.kind === SymbolKind.Variable) {
          // a clause binder shadows a top-level name inside its clause
          const cl = clauseAt(li);
          if (cl && cl.binders.has(word) && !isDeclSite && !(li === cl.from)) { push(li, col, word.length, TT.parameter); continue; }
          push(li, col, word.length, declarationToken(d), mods); continue;
        }
        push(li, col, word.length, TT.type, mods); continue;
      }
      if (ctorOwner.has(word)) { push(li, col, word.length, TT.enumMember); continue; }
      if (builtinFor(doc.uri, word)) { push(li, col, word.length, builtinToken(word), TM.defaultLibrary); continue; }
      const cl = clauseAt(li);
      if (cl && cl.binders.has(word)) { push(li, col, word.length, TT.parameter); continue; }
      // unknown: emit nothing
    }
  }

  toks.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
  const data = [];
  let pl = 0, pc = 0;
  for (const [l, c, len, type, mods] of toks) {
    data.push(l - pl, l === pl ? c - pc : c, len, type, mods);
    pl = l; pc = c;
  }
  return { data };
}

// ---------------------------------------------------------------------------
// documentSymbol
// ---------------------------------------------------------------------------

function documentSymbols(doc) {
  return doc.decls.map((d) => {
    const col = nameColOnLine(doc, d.line, d.kind === SymbolKind.Event ? '>' : d.name, d.col);
    const nameLen = d.kind === SymbolKind.Event ? 1 : d.name.length;
    return {
      name: d.name,
      detail: d.detail || '',
      kind: d.kind,
      range: {
        start: { line: d.sigLine !== undefined ? Math.min(d.sigLine, d.line) : d.line, character: 0 },
        end: { line: d.endLine, character: (doc.lines[d.endLine] || '').length },
      },
      selectionRange: {
        start: { line: d.line, character: col },
        end: { line: d.line, character: col + nameLen },
      },
      children: d.children.map((c) => ({
        name: c.name, detail: '', kind: c.kind,
        range: { start: { line: c.line, character: c.col }, end: { line: c.line, character: c.col + c.name.length } },
        selectionRange: { start: { line: c.line, character: c.col }, end: { line: c.line, character: c.col + c.name.length } },
        children: [],
      })),
    };
  });
}

// Completion uses the same declarations and profile-filtered reference as hover.
function completions(doc, pos) {
  const before = (doc.code[pos.line] || '').slice(0, pos.character);
  const match = before.match(/([A-Za-z_][\w']*(?:\.[A-Za-z_][\w']*)*)\.([\w']*)$/);
  const items = new Map();
  const add = (name, detail, documentation) => items.set(name, { label: name, kind: 3, detail, documentation });
  if (match) {
    if (locallyBound(doc, match[1].split('.')[0], pos)) return [];
    const resolved = resolveName(doc, match[1], 3);
    if (resolved) {
      const declarations = resolved.kind === 'module' ? resolved.doc.decls : resolved.decl.children || [];
      for (const d of declarations) if (d.name.startsWith(match[2])) add(d.name, d.detail || d.name, d.doc || '');
      return [...items.values()];
    }
    for (const d of doc.decls) if (d.name.startsWith(match[1] + '.' + match[2])) add(d.name.slice(match[1].length + 1), d.detail, d.doc || '');
  } else {
    for (const d of doc.decls) add(d.name, d.detail || d.name, d.doc || '');
  }
  for (const name of Object.keys(BUILTINS)) {
    const b = builtinFor(doc.uri, name);
    if (!b || !/^[A-Za-z_]/.test(name)) continue;
    if (match) {
      if (name.startsWith(match[1] + '.' + match[2])) add(name.slice(match[1].length + 1), b.sig, b.doc);
    } else if (!items.has(name)) add(name, b.sig, b.doc);
  }
  return [...items.values()];
}

// ---------------------------------------------------------------------------
// dispatch
// ---------------------------------------------------------------------------

function openDoc(uri, text) {
  const a = analyze(uri, text);
  docs.set(uri, a);
  if (uriToPath(uri)) workspaceIndex.overlay(uriToPath(uri), text);
  for (const [openUri, doc] of docs) publishDiagnostics(openUri, doc);
}

function changedFiles(files, saved) {
  const affected = new Set();
  for (const file of files) {
    if (!file) continue;
    for (const root of saved ? checker.affected(file) : checker.invalidate(file)) affected.add(root);
    affected.add(file);
  }
  if (saved) for (const file of affected) if (docs.has(pathToUri(file))) checkDoc(pathToUri(file));
}

function resetChecks() {
  for (const uri of docs.keys()) dropCheck(uri);
  modCache.clear(); homeCache = null;
  for (const [uri, doc] of docs) { publishDiagnostics(uri, doc); checkDoc(uri); }
}

function handle(msg) {
  const { id, method, params } = msg;
  try {
    switch (method) {
      case 'initialize':
        moduleSettings = (params && params.initializationOptions) || {};
        rootPath = uriToPath((params && (params.rootUri || (params.workspaceFolders && params.workspaceFolders[0] && params.workspaceFolders[0].uri))) || '');
        workspaceRoots = (params.workspaceFolders || []).map(f => uriToPath(f.uri)).filter(Boolean);
        if (!workspaceRoots.length && rootPath) workspaceRoots = [rootPath];
        workspaceIndex.setRoots(workspaceRoots);
        reply(id, {
          capabilities: {
            workspaceSymbolProvider: true,
            workspace: { workspaceFolders: { supported: true, changeNotifications: true } },
            textDocumentSync: { openClose: true, change: 1, save: { includeText: false } },
            documentSymbolProvider: true,
            definitionProvider: true,
            declarationProvider: true,
            hoverProvider: true,
            completionProvider: { triggerCharacters: ['.'] },
            semanticTokensProvider: {
              legend: { tokenTypes: TOKEN_TYPES, tokenModifiers: TOKEN_MODS },
              full: true,
            },
          },
          serverInfo: { name: 'fpr-ls', version: require('../package.json').version },
        });
        break;
      case 'initialized': break;
      case 'workspace/didChangeWorkspaceFolders': {
        const removed = new Set(params.event.removed.map(f => uriToPath(f.uri)));
        workspaceRoots = [...workspaceRoots.filter(r => !removed.has(r)), ...params.event.added.map(f => uriToPath(f.uri)).filter(Boolean)];
        rootPath = workspaceRoots[0] || '';
        workspaceIndex.setRoots(workspaceRoots); resetChecks(); break;
      }
      case 'workspace/didChangeConfiguration':
        remarkRunner.invalidate('Compiler configuration changed');
        moduleSettings = (params.settings && params.settings.fpr) || {};
        resetChecks();
        break;
      case 'textDocument/completion': {
        const doc = docs.get(params.textDocument.uri);
        reply(id, doc ? completions(doc, params.position) : []);
        break;
      }
      case 'textDocument/didOpen':
        remarkRunner.invalidate('An editor buffer opened');
        openDoc(params.textDocument.uri, params.textDocument.text);
        changedFiles([uriToPath(params.textDocument.uri)], true);
        break;
      case 'textDocument/didSave':
        remarkRunner.invalidate('A source file was saved');
        modCache.clear();
        changedFiles([uriToPath(params.textDocument.uri)], true);
        break;
      case 'textDocument/didChange': {
        remarkRunner.invalidate('An editor buffer changed');
        changedFiles([uriToPath(params.textDocument.uri)], false);
        const changes = params.contentChanges;
        if (changes.length) openDoc(params.textDocument.uri, changes[changes.length - 1].text);
        break;
      }
      case 'textDocument/didClose':
        remarkRunner.invalidate('An editor buffer closed');
        docs.delete(params.textDocument.uri);
        workspaceIndex.overlay(uriToPath(params.textDocument.uri), null);
        changedFiles([uriToPath(params.textDocument.uri)], false);
        dropCheck(params.textDocument.uri);
        changedFiles([uriToPath(params.textDocument.uri)], true);
        for (const [uri, doc] of docs) publishDiagnostics(uri, doc);
        // what remains is only what another open file's check says about it
        republish(new Set([uriToPath(params.textDocument.uri)].filter(Boolean)));
        break;
      case 'workspace/didChangeWatchedFiles': {
        remarkRunner.invalidate('Workspace source files changed');
        modCache.clear(); homeCache = null;
        const files = (params.changes || []).map(c => uriToPath(c.uri)).filter(Boolean);
        for (const file of files) workspaceIndex.update(file);
        if (files.some(f => path.basename(f) === 'fpr.toml')) resetChecks();
        else changedFiles(files, true);
        for (const [uri, doc] of docs) publishDiagnostics(uri, doc);
        break;
      }
      case 'fpr/optimizationRemarks': {
        const file = uriToPath(params && params.uri);
        if (!file || !docs.has(params.uri)) { replyErr(id, -32602, 'Open a saved native .fpr file first'); break; }
        remarkRunner.run(file).then(result => reply(id, result), e => replyErr(id, -32603, e.message));
        break;
      }
      case 'fpr/invalidateOptimizationRemarks':
        remarkRunner.invalidate('Workspace source files changed');
        break;
      case 'fpr/cancelOptimizationRemarks':
        remarkRunner.invalidate('Remark request cancelled');
        break;
      case 'workspace/symbol': {
        workspaceSymbols(params && params.query).then(result => reply(id, result), e => replyErr(id, -32603, e.message));
        break;
      }
      case 'textDocument/documentSymbol': {
        const doc = docs.get(params.textDocument.uri);
        reply(id, doc ? documentSymbols(doc) : []);
        break;
      }
      case 'textDocument/definition':
      case 'textDocument/declaration': {
        const doc = docs.get(params.textDocument.uri);
        reply(id, doc ? findDefinition(params.textDocument.uri, doc, params.position, method.endsWith('declaration')) : null);
        break;
      }
      case 'textDocument/semanticTokens/full': {
        const doc = docs.get(params.textDocument.uri);
        reply(id, doc ? semanticTokens(doc) : { data: [] });
        break;
      }
      case 'textDocument/hover': {
        const doc = docs.get(params.textDocument.uri);
        reply(id, doc ? hoverFor(params.textDocument.uri, doc, params.position) : null);
        break;
      }
      case 'shutdown': Promise.all([checker.dispose(), remarkRunner.dispose()]).then(() => reply(id, null), e => replyErr(id, -32603, e.message)); break;
      case 'exit': Promise.all([checker.dispose(), remarkRunner.dispose()]).finally(() => process.exit(0)); break;
      default:
        if (id !== undefined) replyErr(id, -32601, `method not found: ${method}`);
    }
  } catch (e) {
    if (id !== undefined) replyErr(id, -32603, String(e && e.stack || e));
  }
}

process.stdin.on('end', () => Promise.all([checker.dispose(), remarkRunner.dispose()]).finally(() => process.exit(0)));
