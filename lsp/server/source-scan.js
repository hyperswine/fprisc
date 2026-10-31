'use strict';
// Shared lexical scan for editor features and conservative check inputs.
function scanLines(lines) {
  const clean = [], code = [], inString = [];
  let inStr = false, depth = 0;
  const stack = []; // brace depth of the code around each open interpolation
  for (const line of lines) {
    inString.push(inStr || stack.length > 0);
    let cut = line.length, out = '';
    for (let i = 0; i < line.length; i++) {
      const c = line[i];
      if (inStr) {
        if (c === '\\') { out += ' '; if (i + 1 < line.length) { out += ' '; i++; } continue; }
        if (c === '"') { inStr = false; out += c; continue; }
        if (c === '{') { stack.push(depth); depth = 0; inStr = false; out += ' '; continue; }
        out += ' ';
      } else {
        if (c === '#' && stack.length === 0) { cut = i; break; }
        if (c === '"') { inStr = true; out += c; continue; }
        if (c === '{') depth++;
        else if (c === '}') {
          if (depth > 0) depth--;
          else if (stack.length) { depth = stack.pop(); inStr = true; out += ' '; continue; }
        }
        out += c;
      }
    }
    clean.push(line.slice(0, cut));
    code.push(out);
  }
  return { clean, code, inString };
}

module.exports = { scanLines };
