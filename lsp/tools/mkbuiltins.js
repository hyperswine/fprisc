#!/usr/bin/env node
// mkbuiltins.js <fp-risc-dir> <out.json> -- build the hover database from the
// COMPILER'S OWN TYPE TABLES, which is the only source that cannot go stale:
//
//   compiler/Infer.hs        builtinEnv      -> the .fpr surface
//   compiler/Sol/Infer.hs    solBuiltins     -> the .sol surface
//   compiler/Sol/Preamble.hs the record defs -> the .sol prelude (Str/List/...)
//
// The previous generator read docs/API.md; that file no longer exists in the
// repo, so the database froze at whatever the last run produced and every
// builtin added since (spawnCap, timeNow, Sys.memInfo, glMesh, Str.cmp, the
// whole F64/F32/Pin/Mod surface) hovered as nothing. Types now come from the
// tables verbatim, and prose is scavenged from the table's own Haskell
// comments plus any docs/*.md that names the builtin.
//
//   node tools/mkbuiltins.js ../fprisc server/builtins.json
//
// Every entry carries { sig, section, doc, profile }: profile is "fpr", "sol"
// or "both", so the server offers a name only where it actually exists.
// Per-profile variants preserve different signatures and runtime contracts.
// Reviewed primitive summaries supplement source comments; prelude definitions
// provide documentation when no prose exists. Missing docs fail generation.
'use strict';
const fs = require('fs');
const path = require('path');
const describe = require('./builtin-docs');

const [, , root, out] = process.argv;
if (!root || !out) {
  console.error('usage: mkbuiltins.js <fp-risc-dir> <out.json>');
  process.exit(2);
}

// ---------------------------------------------------------------------------
// the Haskell type expression -> surface syntax
// ---------------------------------------------------------------------------
// The tables use a closed vocabulary (Infer.hs): TFn / TAp / TTupT / TC / TV,
// the tTHING atoms, tList, tcon, and sv for scheme variables. A tiny
// recursive-descent reader over that is exact; anything unrecognised comes
// back verbatim rather than guessed at.
const ATOM = {
  tInt: 'Int', tStr: 'String', tBool: 'Bool', tUnit: 'Unit', tAtom: 'Atom',
  tF64: 'F64', tF32: 'F32', tI32: 'I32', tI64: 'I64', tSString: 'SString',
};
const TVNAME = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'];

function lex(src) {
  const toks = [];
  const re = /\s*("(?:[^"\\]|\\.)*"|[()\[\],]|[A-Za-z_][A-Za-z0-9_.']*|-?\d+)/y;
  let i = 0;
  while (i < src.length) {
    re.lastIndex = i;
    const m = re.exec(src);
    if (!m) { if (!src.slice(i).trim()) break; throw new Error(`Unknown type syntax: ${src.slice(i)}`); }
    toks.push(m[1]);
    i = re.lastIndex;
  }
  return toks;
}

function renderType(src) {
  const toks = lex(src);
  let p = 0;
  const peek = () => toks[p];
  const eat = (t) => { if (toks[p] === t) { p++; return true; } return false; };

  function ty() {
    const t = toks[p++];
    if (t === undefined) return '?';
    if (t === '(') {
      const parts = [ty()];
      while (eat(',')) parts.push(ty());
      eat(')');
      return parts.length > 1 ? `(${parts.join(', ')})` : parts[0];
    }
    if (t === '[') { // a list of types: tcon args / scheme vars
      const parts = [];
      if (peek() !== ']') { parts.push(ty()); while (eat(',')) parts.push(ty()); }
      eat(']');
      return parts;
    }
    if (t === 'TFn') { const a = arg(); const b = ty(); return `${a} -> ${b}`; }
    if (t === 'TAp') { const a = arg(); const b = arg(); return `${a} ${b}`; }
    if (t === 'TTupT') { const xs = ty(); return `(${(Array.isArray(xs) ? xs : [xs]).join(', ')})`; }
    if (t === 'TC') return (toks[p++] || '""').replace(/"/g, '');
    if (t === 'TV' || t === 'sv') { const n = +toks[p++]; return TVNAME[n] || `t${n}`; }
    if (t === 'tList' || t === 'tVector') return `${t === 'tList' ? 'List' : 'Vector'} ${arg()}`;
    if (t === 'tcon') {
      const n = (toks[p++] || '""').replace(/"/g, '');
      const xs = ty();
      return [n, ...(Array.isArray(xs) ? xs : [xs])].join(' ');
    }
    if (ATOM[t]) return ATOM[t];
    throw new Error(`Unknown compiler type atom: ${t}`);
  }
  // argument position: anything compound needs its own parentheses
  function arg() {
    const v = ty();
    if (Array.isArray(v)) return v;
    return / /.test(v) && !/^\(/.test(v) ? `(${v})` : v;
  }

  const r = ty();
  if (p !== toks.length) throw new Error(`Unconsumed type syntax: ${src} (${toks.slice(p).join(' ')})`);
  return Array.isArray(r) ? r.join(', ') : r;
}

// read a `name = M.fromList [ ("x", TYPE), ... ]` table, keeping the Haskell
// comments that lead or trail each entry as its doc
function readTable(text, tableName) {
  const start = text.indexOf(`\n${tableName} =`);
  if (start === -1) throw new Error(`Missing compiler table: ${tableName}`);
  const open = text.indexOf('[', start);
  if (open === -1) return [];
  let depth = 0, end = open;
  for (; end < text.length; end++) {
    const c = text[end];
    if (c === '"') { end++; while (end < text.length && (text[end] !== '"' || text[end - 1] === '\\')) end++; continue; }
    if (c === '[' || c === '(') depth++;
    else if (c === ']' || c === ')') { depth--; if (depth === 0) break; }
  }
  const body = text.slice(open + 1, end);

  const entries = [];
  let d = 0, cur = '', pending = [];
  for (const raw of body.split(/\r?\n/)) {
    const line = raw.trim();
    if (/^--/.test(line)) { // a comment line documents whatever follows
      if (cur.trim() === '') pending.push(line.replace(/^--\s?/, ''));
      continue;
    }
    let ln = raw, trailing = null;
    const cm = ln.match(/\s--\s?(.*)$/);
    if (cm && (ln.slice(0, cm.index).match(/"/g) || []).length % 2 === 0) {
      trailing = cm[1].trim();
      ln = ln.slice(0, cm.index);
    }
    cur += ' ' + ln;
    for (const c of ln) {
      if (c === '(' || c === '[') d++;
      else if (c === ')' || c === ']') d--;
    }
    if (trailing) pending.push(trailing);
    if (d === 0 && /\)\s*,?\s*$/.test(ln.trim())) {
      const m = cur.match(/^\s*\(\s*"([^"]+)"\s*,\s*([\s\S]*?)\s*\)\s*,?\s*$/);
      if (m) {
        const inner = m[2].replace(/^mono\s*/, '').replace(/^scheme\s*\[[^\]]*\]\s*/, '');
        entries.push({ name: m[1], type: renderType(inner), doc: pending.join(' ').trim() });
      }
      cur = ''; pending = [];
    }
  }
  return entries;
}

// the sol prelude records (Preamble.hs): `"  name = fn a b -> ...,"` inside a
// `X = {` block -- the Str./List./Numeric. surface users actually type
function readPrelude(text) {
  const out = [];
  let rec = null;
  for (const raw of text.split(/\r?\n/)) {
    const s = raw.match(/^\s*(?:\[\s*)?"((?:[^"\\]|\\.)*)"/);
    if (!s) continue;
    const line = s[1].replace(/\\"/g, '"').replace(/\\\\/g, '\\');
    // `Str = Struct Add {` / `List = {`: a record opens the field run
    const open = line.match(/^([A-Z][A-Za-z0-9_']*)\s*=\s*(?:Struct\b[^{]*)?\{\s*$/);
    if (open) { rec = open[1]; continue; }
    if (/^\}\.?$/.test(line.trim())) { rec = null; continue; }
    if (!rec) continue;
    // a field is `name = ...` or an operator member `(+) = ...`
    const m = line.match(/^\s*(\([-+*\/%^!<>=&|:~]+\)|[a-zA-Z_][A-Za-z0-9_']*)\s*=\s*(.*?),?\s*$/);
    if (!m) continue;
    const [, field, rhs] = m;
    const params = (rhs.match(/^fn\s+([^-]*?)\s*->/) || [, ''])[1].trim();
    out.push({
      name: `${rec}.${field}`,
      // a prelude member has no table type: show the CALL form (its own
      // parameter names), with the definition as the doc
      sig: params ? `${rec}.${field} ${params}` : `${rec}.${field}`,
      doc: '```\n' + `${rec}.${field} = ${rhs.replace(/,$/, '')}` + '\n```',
    });
  }
  return out;
}

// prelude DECLARATIONS -- the tier the tables do not hold: Sol's IO and
// transaction surface (`readPath p = ...`, `open : String -> Handle.`) and
// FP-RISC's core/prelude.fpr (the typed stdlib layered over the prims). Both
// are ordinary surface syntax, so one reader serves them: a `name : TYPE .`
// line is the signature, a `name args = body.` line the definition, and the
// `#` comment block above a declaration is its doc.
function readDecls(lines, section) {
  const out = new Map();
  let comment = [];
  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i];
    const line = raw.trim();
    if (line === '') { comment = []; continue; }
    const c = line.match(/^#\s?(.*)$/);
    if (c) { comment.push(c[1]); continue; }
    if (/^\s/.test(raw)) { comment = []; continue; }
    const sig = line.match(/^([A-Za-z_][\w.']*)\s*:\s*(.+?)\s*\.?$/);
    if (sig && !/^(case|of|fn)$/.test(sig[1])) {
      const e = out.get(sig[1]) || { name: sig[1], doc: '', section };
      e.sig = `${sig[1]} : ${sig[2].replace(/\s*\.$/, '')}`;
      if (!e.doc && comment.length) e.doc = comment.join('\n');
      out.set(sig[1], e);
      continue;
    }
    const def = line.match(/^([A-Za-z_][\w.']*)((?:\s+[^=]*?)?)=(?!=)/);
    if (def && !/^(Type|Sig|Struct)$/.test(def[1])) {
      const e = out.get(def[1]) || { name: def[1], doc: '', section };
      if (!e.sig) e.sig = /\b(Type|Sig)\b/.test(line) ? line : `${def[1]}${def[2] ? ' ' + def[2].trim() : ''}`;
      let end = i + 1;
      while (end < lines.length && (/^\s+\S/.test(lines[end]) || /^\}\.?$/.test(lines[end]))) end++;
      e.source = lines.slice(i, end).join('\n');
      if (/=\s*Type\b/.test(line)) e.sig = e.source.replace(/\s+/g, ' ');
      if (!e.doc && comment.length) e.doc = comment.join('\n');
      out.set(def[1], e);
      comment = [];
    }
  }
  for (const e of [...out.values()]) {
    const type = (e.source || '').match(/^[A-Z][\w']*(?:\s+[^=]*)?=\s*Type\s*\(([\s\S]*)\)\.\s*$/);
    if (!type) continue;
    let depth = 0, start = 0;
    const body = type[1];
    const clauses = [];
    for (let i = 0; i <= body.length; i++) {
      if (i === body.length || (body[i] === '|' && depth === 0)) { clauses.push(body.slice(start, i).trim()); start = i + 1; }
      else if ('([{'.includes(body[i])) depth++;
      else if (')]}'.includes(body[i])) depth--;
    }
    for (const clause of clauses) {
      const match = clause.match(/^([A-Z][\w']*)\b/);
      if (!match || out.has(match[1])) continue;
      out.set(match[1], { name: match[1], sig: clause.replace(/\s+/g, ' '), section,
        doc: `Constructor of \`${e.name}\`. Construct or pattern-match this case as \`${clause.replace(/\s+/g, ' ')}\`.` });
    }
  }
  return [...out.values()];
}

// the Sol preamble is a list of Haskell string literals holding that surface
function preambleLines(text) {
  const out = [];
  for (const raw of text.split(/\r?\n/)) {
    const m = raw.match(/^\s*(?:\[\s*)?"((?:[^"\\]|\\.)*)",?\s*$/);
    if (!m) continue;
    out.push(m[1].replace(/\\"/g, '"').replace(/\\n/g, '\n').replace(/\\\\/g, '\\'));
  }
  return out;
}

// prose: a docs/*.md paragraph that names the builtin in bold or in backticks
// keeps its text as the hover body (the old generator's job, pointed at the
// docs the repo actually has)
// a hover is a tooltip, not a chapter: keep the opening of a paragraph and
// say so rather than pasting a page of docs/MEMORY.md into the popup
const DOC_MAX = 700;
function clip(text) {
  if (text.length <= DOC_MAX) return text;
  const cut = text.lastIndexOf('. ', DOC_MAX);
  return text.slice(0, cut > DOC_MAX / 2 ? cut + 1 : DOC_MAX).trimEnd() + ' …';
}

function docProse(dirs) {
  const prose = new Map();
  for (const dir of dirs) {
    let files = [];
    try { files = fs.readdirSync(dir).filter((f) => f.endsWith('.md')); } catch (e) { continue; }
    for (const f of files) {
      const text = fs.readFileSync(path.join(dir, f), 'utf8').split(/\r?\n/);
      let sec = '';
      for (let i = 0; i < text.length; i++) {
        const h = text[i].match(/^#+\s+(.*)/);
        if (h) { sec = h[1].trim(); continue; }
        const names = [
          ...[...text[i].matchAll(/\*\*([A-Za-z_][\w.']*(?:\s*\/\s*[\w.']+)*)/g)].map((m) => m[1]),
          ...[...text[i].matchAll(/`([A-Z][\w']*\.[a-zA-Z_]\w*)`/g)].map((m) => m[1]),
        ];
        if (!names.length) continue;
        let a = i; while (a > 0 && text[a - 1].trim() !== '' && !/^#/.test(text[a - 1])) a--;
        let b = i; while (b + 1 < text.length && text[b + 1].trim() !== '') b++;
        const para = clip(text.slice(a, b + 1).join('\n').trim());
        for (const run of names) {
          let qual = null;
          for (const n of run.split('/').map((s) => s.trim())) {
            const t = n.replace(/[\\`]/g, '').trim();
            if (!/^[A-Za-z_][\w.']*$/.test(t)) continue;
            const qm = t.match(/^([A-Z][\w']*)\.(.+)$/);
            if (qm) qual = qm[1];
            const key = qm || !qual ? t : `${qual}.${t}`;
            if (!prose.has(key)) {
              prose.set(key, { doc: para, section: f.replace(/\.md$/, '') + (sec ? ' — ' + sec : '') });
            }
          }
        }
      }
    }
  }
  return prose;
}

// ---------------------------------------------------------------------------
const infer = fs.readFileSync(path.join(root, 'compiler/Infer.hs'), 'utf8');
const solInfer = fs.readFileSync(path.join(root, 'compiler/Sol/Infer.hs'), 'utf8');
const preamble = fs.readFileSync(path.join(root, 'compiler/Sol/Preamble.hs'), 'utf8');
const prose = docProse([path.join(root, 'docs')]);

const entries = {};
function put(e, profile, section) {
  if (e.name.startsWith('$')) return;
  const p = prose.get(e.name);
  const authored = describe(e.name, profile);
  const sourceDoc = e.source ? `Definition in ${section}:\n\n\`\`\`\n${clip(e.source)}\n\`\`\`` : '';
  const doc = authored || clip(e.doc || '') || sourceDoc || (p && p.doc) || '';
  const sig = e.sig || `${e.name} : ${e.type}`;
  const entry = entries[e.name] || { sig, section, doc, profile, variants: {} };
  const previous = entry.variants[profile];
  // Compiler signatures win over inferred prelude call forms. A later
  // definition can still supply missing documentation for a signature.
  entry.variants[profile] = previous ? { ...previous, doc: previous.doc || doc } : { sig, doc, section };
  if (entry.profile !== profile) entry.profile = 'both';
  if (!entry.doc) entry.doc = doc;
  entries[e.name] = entry;
}
for (const e of readTable(infer, 'builtinEnv')) put(e, 'fpr', 'FP-RISC builtins (compiler/Infer.hs)');
for (const e of readTable(infer, "builtinCons'")) { put(e, 'fpr', 'Constructors'); put(e, 'sol', 'Constructors'); }
for (const e of readTable(solInfer, 'solBuiltins')) put(e, 'sol', 'Sol builtins (compiler/Sol/Infer.hs)');
for (const e of readPrelude(preamble)) put(e, 'sol', 'Sol prelude (compiler/Sol/Preamble.hs)');
// the declaration tier: Sol's IO/transaction surface, then FP-RISC's stdlib
for (const e of readDecls(preambleLines(preamble), 'Sol prelude (compiler/Sol/Preamble.hs)')) {
  put(e, 'sol', e.section);
}
try {
  const fprPrelude = fs.readFileSync(path.join(root, 'core/prelude.fpr'), 'utf8').split(/\r?\n/);
  for (const e of readPrelude(fprPrelude.map(line => JSON.stringify(line)).join('\n'))) put(e, 'fpr', 'FP-RISC prelude (core/prelude.fpr)');
  for (const e of readDecls(fprPrelude, 'FP-RISC prelude (core/prelude.fpr)')) put(e, 'fpr', e.section);
} catch (err) { throw new Error(`Cannot generate FP-RISC prelude reference: ${err.message}`); }

// the surface that is syntax rather than a table entry: no type table can
// hold these, so they are written out here
const SYNTAX = {
  profile: ['profile builtin. / profile base. / profile extbase. / profile sol.', 'Profiles', 'both',
    'Selects the language profile. Base is the default; `unsafe base.` also marks the file blanket-unsafe. The target system is selected separately by the compiler.'],
  Layout: ['Block = Layout { size : Word, next : Block }.', 'Memory layouts', 'fpr',
    'Declares a nominal pointer type with generated field accessors and layout metadata. Field widths and alignment are checked by the compiler.'],
  '@': ['@Msg / @Model.field', 'Derived codecs and field paths', 'both',
    'In AOT code, a declared sum type produces a wire codec; a record field path produces a lens with a codec when its type supports one. In Sol, path literals are URL strings.'],
  unsafe: ['unsafe program. / unsafe module. / f : unsafe A -> B', 'Safety', 'both',
    'The safety line (docs/SAFETY.md): recursion without a `measure` needs an explicit `unsafe` signature, or the whole file opts out with `unsafe program.` (`unsafe module.` for a library). A recursive helper with neither is refused by name.'],
  measure: ['(n : Int | measure n)', 'Safety', 'both',
    'A structural-descent witness in a precondition: the argument that strictly decreases, which is what makes the recursion safe without an `unsafe` marker.'],
  '?name': ['?name', 'Typed holes', 'both',
    'A TYPED HOLE: compilation stops and reports the type the hole must have, with the bindings in scope.'],
  '??': ['??', 'Typed holes', 'both',
    'A RUNTIME hole: the program compiles and traps if it reaches the hole, so a partly-written program still runs.'],
  '>': ['> effect.', 'Sol transactions', 'sol',
    'A top-level effect in a .sol script. Effects run in file order and the WHOLE SCRIPT is one atomic transaction over the filesystem: writes land at commit, a conflict retries the script.'],
  '#:': ['#: directive args', 'Program directives', 'both',
    'A directive read by the qos.py harness rather than the compiler: `#: plugins a.fpr b.fpr` builds and seeds those as plugin .qa images, `#: expect <line>` asserts the run prints it, `#: disk-mb N` seeds a disk of that size.'],
};
for (const [name, [sig, section, profile, doc]] of Object.entries(SYNTAX)) {
  entries[name] = { sig, section, doc, profile };
}


// Scalar/container type names are compiler syntax, not term-table bindings.
const TYPES = {
  Int: ['both', 'Tagged machine integer in FP-RISC; arithmetic overflow traps. In Sol, Int names the VM Numeric representation.'],
  I32: ['fpr', 'Distinct signed 32-bit integer with wrapping arithmetic. Construct with I32.ofInt or I32.parse; it never implicitly mixes with Int.'],
  I64: ['fpr', 'Distinct signed 64-bit integer with wrapping arithmetic. Construct with I64.ofInt or I64.parse; it never implicitly mixes with Int.'],
  F32: ['fpr', 'IEEE-754 single-precision floating-point type. Use F32 conversions to cross numeric types.'],
  F64: ['fpr', 'IEEE-754 double-precision floating-point type. Use F64 conversions to cross numeric types.'],
  Word: ['fpr', 'Unsigned machine word for bit manipulation and low-level memory access. Its width depends on the target; query Word.bits Unit.'],
  Addr: ['fpr', 'Raw machine address, distinct from integer data. Use Addr and Mem operations; the caller is responsible for valid access.'],
  String: ['both', 'Byte string. Lengths and indexes in the primitive string APIs count bytes rather than Unicode characters.'],
  Bool: ['both', 'Boolean type with constructors True and False.'],
  Result: ['both', 'Result value error = Ok value | Err error. Pattern-match both cases to handle fallible operations.'],
  Atom: ['fpr', 'Interned atom value used by the compiler/runtime.'],
};
for (const [name, [profile, doc]] of Object.entries(TYPES)) entries[name] = { sig: name, section: 'Types', profile, doc };
const missing = Object.entries(entries).flatMap(([name, e]) => {
  const variants = e.variants || { [e.profile]: e };
  return Object.entries(variants).filter(([, v]) => !v.doc.trim()).map(([p]) => `${name} (${p})`);
});
if (missing.length) throw new Error(`Missing builtin documentation: ${missing.join(', ')}`);

fs.writeFileSync(out, JSON.stringify(entries, null, 1));
const by = { fpr: 0, sol: 0, both: 0 };
for (const e of Object.values(entries)) by[e.profile]++;
const documented = Object.values(entries).filter((e) => e.doc).length;
console.log(
  `${Object.keys(entries).length} entries -> ${out}\n` +
  `  fpr ${by.fpr}, sol ${by.sol}, both ${by.both}; ${documented} carry prose`
);
