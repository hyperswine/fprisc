'use strict';

// A structural scan of case expressions, not a typechecker. Keep offsets into
// the original text; strings and comments are opaque so their punctuation can
// never introduce a branch. Compound operators and qualified names stay whole.
function caseBindings(text) {
  const tokens = [];
  const lex = /#[^\n]*|"(?:\\[\s\S]|[^"\\])*"|[A-Za-z_][\w']*(?:\.[A-Za-z_][\w']*)*|\d+(?:\.\d+)?|->|<-|::|\|>\?|\|>|\|\||&&|==|!=|<=|>=|[^\s]/g;
  for (const m of text.matchAll(lex)) if (!m[0].startsWith('#')) tokens.push({ value: m[0], start: m.index });
  const scopes = [];
  const close = { '(': ')', '[': ']', '{': '}' };
  const boundaries = new Set([')', ']', '}', ',', ';', '.', '|', 'of', 'then', 'else']);
  const value = i => tokens[i]?.value;
  const offset = i => tokens[i]?.start ?? text.length;

  function expression(i) {
    while (i < tokens.length && !boundaries.has(value(i))) {
      if (value(i) === 'case') { i = caseExpr(i); continue; }
      if (value(i) === 'if') {
        i = expression(i + 1);
        if (value(i) === 'then') i = block(i + 1);
        if (value(i) === 'else') i = block(i + 1);
        continue;
      }
      if (close[value(i)]) {
        const end = close[value(i++)];
        while (i < tokens.length && value(i) !== end) {
          const next = block(i);
          i = next > i ? next : i + 1;
          if (value(i) === ',') i++;
        }
        if (value(i) === end) i++;
        continue;
      }
      i++;
    }
    return i;
  }

  // In the compiler a block is zero or more pattern/name = expression;
  // statements, followed by a final expression. A bare semicolon ends a case
  // used as a statement RHS, but one after an arm's local binding does not.
  function assignment(i) {
    let depth = 0;
    for (let j = i; j < tokens.length; j++) {
      const v = value(j);
      if (!depth && v === '=') return j;
      if (!depth && (boundaries.has(v) || ['case', 'if', 'fn', '->'].includes(v))) return -1;
      if (close[v]) depth++;
      else if ([')', ']', '}'].includes(v)) { if (!depth) return -1; depth--; }
    }
    return -1;
  }
  function block(i) {
    while (i < tokens.length) {
      const eq = assignment(i);
      if (eq < 0) return expression(i);
      const end = expression(eq + 1);
      if (value(end) !== ';') return end;
      i = end + 1;
    }
    return i;
  }
  function caseExpr(i) {
    const start = i;
    i = expression(i + 1);
    if (value(i) !== 'of') return Math.max(start + 1, i);
    i++;
    while (i < tokens.length) {
      const pattern = i;
      let depth = 0;
      while (i < tokens.length) {
        const v = value(i);
        if (!depth && v === '->') break;
        if (!depth && boundaries.has(v)) return i;
        if (close[v]) depth++;
        else if ([')', ']', '}'].includes(v)) depth--;
        i++;
      }
      if (value(i) !== '->') return i;
      const bindings = tokens.slice(pattern, i).filter(t => /^[a-z_][\w']*$/.test(t.value) && t.value !== '_');
      const body = ++i;
      i = block(i);
      scopes.push({ from: offset(body), to: offset(i), bindings });
      if (value(i) !== '|') break;
      i++;
    }
    return i;
  }
  for (let i = 0; i < tokens.length;) {
    const next = expression(i);
    i = next > i ? next : i + 1;
  }
  // Innermost arm wins when a nested pattern shadows an outer pattern.
  scopes.sort((a, b) => b.from - a.from);
  return (name, at) => {
    for (const scope of scopes) {
      const binding = scope.bindings.find(t => t.value === name);
      if (!binding) continue;
      if (binding.start === at) return { declaration: true };
      if (at >= scope.from && at < scope.to) return { declaration: false };
    }
    return null;
  };
}
module.exports = { caseBindings };
