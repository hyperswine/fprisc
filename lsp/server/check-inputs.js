'use strict';
// An over-approximation, not a second module resolver. Track every possible
// source/store candidate (including missing ones), so shadowing and newly
// created imports invalidate checks too. Unrecognized syntax disables reuse.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { scanLines } = require('./source-scan');
const hash = value => crypto.createHash('sha256').update(value).digest('hex');

function imports(text) {
  const lines = text.split(/\r?\n/);
  const code = scanLines(lines).code.map((s, i) => s.padEnd(lines[i].length)).join('\n');
  const source = lines.join('\n'), specs = [];
  let complete = true;
  for (const token of code.matchAll(/\buse\b/g)) {
    const tail = code.slice(token.index + 3);
    const start = /^\s*"/.exec(tail);
    if (!start) { complete = false; continue; }
    const offset = token.index + 3 + start[0].length;
    const end = source.indexOf('"', offset);
    if (end < 0) { complete = false; continue; }
    const spec = source.slice(offset, end);
    if (/[\\{}]/.test(spec)) complete = false;
    specs.push(spec);
  }
  return { specs, complete };
}

function snapshot({ file, cwd, home, compiler, args, env, readOpen = () => null, additionalFiles = [] }) {
  const files = new Map(), texts = new Map(), realFiles = new Set();
  let complete = true, dirty = false;
  const roots = [home, ...(env.FPR_PATH || '').split(path.delimiter)].filter(Boolean);
  function visit(name, follow = true) {
    name = path.resolve(cwd, name);
    if (files.has(name)) return;
    if (files.size >= 2048) { complete = false; return; }
    let text = null, real = name;
    try { real = fs.realpathSync(name); text = fs.readFileSync(name, 'utf8'); }
    catch (e) { if (e.code !== 'ENOENT' && e.code !== 'ENOTDIR') complete = false; }
    files.set(name, { real, digest: text === null ? null : hash(text) });
    realFiles.add(real);
    const open = readOpen(name);
    if (open !== null && open !== undefined && open !== text) dirty = true;
    if (text === null) return;
    texts.set(name, text);
    if (!follow) return;
    const found = imports(text); complete &&= found.complete;
    for (const spec of found.specs) {
      const at = spec.indexOf('#'), module = at < 0 ? spec : spec.slice(0, at);
      const pin = at < 0 ? '' : spec.slice(at + 1);
      // Native imports append .fpr even to a name ending in .sol. Sol also
      // accepts explicit extensions. Include both interpretations.
      const names = [...new Set([...( /\.(fpr|sol)$/.test(module) ? [module] : []),
        module.endsWith('.fpr') ? module : module + '.fpr', module.endsWith('.sol') ? module : module + '.sol'])];
      for (const root of [path.dirname(name), ...roots])
        for (const candidate of names) visit(path.resolve(cwd, root, candidate));
      if (pin) {
        if (!/^[0-9a-f]+$/i.test(pin)) { complete = false; continue; }
        for (const root of [cwd, ...roots]) visit(path.join(root, '.fpr', 'store', pin + '.fpr'));
      }
    }
  }
  visit(file);
  for (const extra of additionalFiles) visit(extra);
  for (const root of roots) visit(path.join(root, 'core', 'prelude.fpr'));
  if (!home) complete = false;
  for (const foreign of (env.FPR_FOREIGN || '').split(path.delimiter).filter(Boolean)) visit(foreign);
  visit(path.join(cwd, 'fpr.toml'), false);
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--foreign' && args[i + 1]) visit(args[++i]);
    else if (arg.startsWith('--foreign=')) visit(arg.slice('--foreign='.length));
    else if (arg.startsWith('--prelude=')) { if (arg.slice(10)) visit(arg.slice(10)); }
    else if (arg.startsWith('--manifest=')) { visit(arg.slice(11), false); complete = false; }
    else if (arg.startsWith('--') && !/^(--check-only|--editor-json|--target=bytecode|--system=[\w-]+)$/.test(arg)) complete = false;
  }
  let executable = compiler;
  if (!path.isAbsolute(executable)) executable = (env.PATH || '').split(path.delimiter)
    .map(p => path.resolve(cwd, p, compiler)).find(p => { try { fs.accessSync(p, fs.constants.X_OK); return fs.statSync(p).isFile(); } catch (_) { return false; } });
  let identity = null;
  try {
    const real = fs.realpathSync(executable), st = fs.statSync(real);
    identity = [real, st.dev, st.ino, st.size, st.mtimeMs, st.ctimeMs];
    realFiles.add(real);
  } catch (_) { complete = false; }
  const key = hash(JSON.stringify([cwd, home, compiler, identity, args, env, [...files]]));
  return { key, complete, dirty, files, texts, realFiles };
}

function includes(input, file) {
  if (!input || !input.complete) return true;
  file = path.resolve(file);
  if (input.files.has(file) || input.realFiles.has(file)) return true;
  try { return input.realFiles.has(fs.realpathSync(file)); } catch (_) { return false; }
}
module.exports = { imports, snapshot, includes };
