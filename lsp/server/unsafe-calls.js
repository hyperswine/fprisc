'use strict';

// Recognize syntactic applications of statically resolved unsafe functions.
// This intentionally does not infer the safety of arbitrary function values.
function unsafeCalls(doc, api) {
  const tokens = [];
  const lex = /#[^\n]*|"(?:\\[\s\S]|[^"\\])*"|[A-Za-z_][\w']*(?:\.[A-Za-z_][\w']*)*|\d+(?:\.\d+)?|->|<-|::|\|>\?|\|>|\|\||&&|==|!=|<=|>=|[^\s]/g;
  for (const m of doc.text.matchAll(lex)) if (!m[0].startsWith('#')) tokens.push({ value: m[0], at: m.index });
  const lineStarts = [0];
  for (let i = 0; i < doc.text.length; i++) if (doc.text[i] === '\n') lineStarts.push(i + 1);
  const position = at => {
    let lo = 0, hi = lineStarts.length;
    while (lo + 1 < hi) { const mid = (lo + hi) >> 1; if (lineStarts[mid] <= at) lo = mid; else hi = mid; }
    return { line: lo, character: at - lineStarts[lo] };
  };
  const scopes = [];
  for (const d of doc.decls) for (let ci = 0; ci < (d.clauses || []).length; ci++) {
    const from = d.clauses[ci], to = ci + 1 < d.clauses.length ? d.clauses[ci + 1] - 1 : d.endLine;
    const text = doc.code.slice(from, to + 1).join('\n');
    const eq = /(?<![=<>!])=(?!=)/.exec(text);
    if (!eq) continue;
    scopes.push({ from, to, start: lineStarts[from] + eq.index + 1,
      params: api.clauseBinders(doc.code[from], d.name), locals: api.clauseLocals(doc, from, to) });
  }
  function signature(src, d) {
    const start = d.sigLine ?? d.line;
    if (!/^\s*[\w.']+\s*:/.test(src.clean[start] || '')) return '';
    let result = '';
    for (let i = start; i < src.clean.length; i++) {
      if (i > start && /^[A-Za-z_>]/.test(src.clean[i])) break;
      result += ' ' + src.clean[i];
      if (/\.\s*$/.test(src.clean[i])) break;
    }
    return result;
  }
  function declaredUnsafe(src, d) {
    const sig = signature(src, d);
    if (/:\s*unsafe\b/.test(sig)) return true;
    return (d.kind === 12 || /->/.test(sig)) && src.clean.some(l => /^\s*unsafe\s+(?:program|module|builtin|base|extbase|sol)\s*\./.test(l));
  }
  function unsafeName(name, src, depth = 8) {
    if (!depth) return false;
    const own = src.decls.find(d => d.name === name);
    if (own) {
      if (own.aliasOf) return unsafeName(own.aliasOf.mod + '.' + own.aliasOf.member, src, depth - 1);
      if (declaredUnsafe(src, own)) return true;
      // An ordinary binding can alias an unsafe function without applying it.
      const head = src.clean[own.line] || '';
      const alias = /^\s*[\w']+\s*=\s*([A-Za-z_][\w']*(?:\.[A-Za-z_][\w']*)*)\s*\.\s*$/.exec(head);
      return alias ? unsafeName(alias[1], src, depth - 1) : false;
    }
    const dot = name.indexOf('.');
    if (dot !== -1) {
      const qualifier = name.slice(0, dot);
      const mod = api.resolveName(src, qualifier, 8);
      if (mod) return mod.kind === 'module' ? unsafeName(name.slice(dot + 1), mod.doc, depth - 1) : false;
    }
    const builtin = api.builtinFor(src.uri, name);
    return !!builtin && /:\s*unsafe\b/.test(builtin.sig);
  }
  const caseBinding = api.caseBindings(doc.text);
  const diagnostics = [];
  for (let ti = 0; ti < tokens.length; ti++) {
    const t = tokens[ti];
    if (!/^[A-Za-z_][\w']*(?:\.[A-Za-z_][\w']*)*$/.test(t.value)) continue;
    const pos = position(t.at);
    const scope = scopes.find(s => t.at >= s.start && pos.line <= s.to);
    if (!scope) continue;
    const first = t.value.split('.')[0];
    if (scope.params.has(first) || caseBinding(first, t.at)) continue;
    if (scope.locals.some(b => b.name === first && b.visible &&
      (pos.line > b.visible.line || (pos.line === b.visible.line && pos.character >= b.visible.col)))) continue;
    // Lambda parameters are unknown function values. Stay quiet when shadowed.
    const preceding = doc.text.slice(scope.start, t.at);
    if ([...preceding.matchAll(/\bfn\s+([a-z_][\w']*(?:\s+[a-z_][\w']*)*)\s*->/g)].some(m => m[1].split(/\s+/).includes(first))) continue;
    let after = ti + 1, before = ti - 1;
    while (tokens[before]?.value === '(' && tokens[after]?.value === ')') { before--; after++; }
    const next = tokens[after]?.value || '';
    const atom = /^(?:[A-Za-z_0-9"([{@?])/.test(next) && !['of','then','else','and','or','unsafe','measure'].includes(next);
    const piped = ['|>', '|>?'].includes(tokens[before]?.value);
    if (!atom && !piped) continue;
    if (!unsafeName(t.value, doc)) continue;
    const symbol = t.value.split('.').pop();
    const start = position(t.at + t.value.length - symbol.length);
    diagnostics.push({ range: { start, end: { line: start.line, character: start.character + symbol.length } },
      severity: 3, source: 'fpr', code: 'unsafe-call', message: `Call to unsafe function '${t.value}'.` });
  }
  return diagnostics;
}
module.exports = { unsafeCalls };
