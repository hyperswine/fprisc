'use strict';
// Selection policy belongs to the native managers. This module only discovers
// their proxies, caches their read-only JSON response and tracks its inputs.
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');
const cache = new Map();
const hash = value => crypto.createHash('sha256').update(value).digest('hex');
const exists = file => { try { return fs.statSync(file).isFile(); } catch (_) { return false; } };
function executable(command) {
  if (path.isAbsolute(command)) return command;
  return (process.env.PATH || '').split(path.delimiter).filter(Boolean).map(p => path.resolve(p, command)).find(exists) || command;
}
function managedProxy(compiler) {
  try { return ['fprmeta', 'qosmeta'].includes(path.basename(fs.realpathSync(executable(compiler)))); }
  catch (_) { return false; }
}
function managerFor(kind, compiler) {
  const name = kind === 'qos' ? 'qosmeta' : 'fprmeta';
  const candidates = [path.join(path.dirname(executable(compiler)), name), executable(name),
    ...['/opt/homebrew/bin', '/usr/local/bin', '/home/linuxbrew/.linuxbrew/bin', path.join(os.homedir(), '.local/bin')].map(p => path.join(p, name))];
  return candidates.find(p => path.isAbsolute(p) && exists(p)) || null;
}
function home(kind) { return process.env[kind === 'qos' ? 'QOSMETA_HOME' : 'FPRMETA_HOME'] || path.join(os.homedir(), kind === 'qos' ? '.qos' : '.fpr'); }
function signature(file) {
  try { return hash(fs.readFileSync(file)); } catch (_) { return null; }
}
function versions(root) {
  try { return fs.readdirSync(root).filter(n => /^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$/.test(n)).sort(); }
  catch (_) { return []; }
}
function storeState(kind) {
  const root = home(kind);
  let receipts = []; try { receipts = fs.readdirSync(path.join(root, 'receipts')).sort(); } catch (_) {}
  return [root, signature(path.join(root, 'settings.toml')), versions(root), receipts];
}
function managerState() { return JSON.stringify([storeState('fpr'), storeState('qos')]); }
function manifestFor(file) {
  const inputs = [];
  let dir = path.dirname(file);
  for (;;) {
    for (const name of ['fpr.toml', 'qos.toml']) {
      const candidate = path.join(dir, name); inputs.push(candidate);
      if (exists(candidate)) return { file: candidate, kind: name === 'qos.toml' ? 'qos' : 'fpr', inputs };
    }
    const up = path.dirname(dir); if (up === dir) break; dir = up;
  }
  return { inputs };
}
function resolve(settings, file, cwd, compiler) {
  // A checkout/module-home setting is an intentional override. Explicit real
  // compilers keep working; explicit manager proxies still resolve their home.
  if (settings.home || process.env.FPR_HOME) return null;
  const manifest = manifestFor(file);
  const kind = !settings.compilerPath && !file.endsWith('.sol') && manifest.kind === 'qos' ? 'qos' : 'fpr';
  if ((settings.compilerPath || kind === 'fpr') && !managedProxy(compiler)) return null;
  const manager = managerFor(kind, compiler);
  const controls = [...manifest.inputs, path.join(home(kind), 'settings.toml')];
  if (!manager) return { error: `${kind === 'qos' ? 'qosmeta' : 'fprmeta'} is unavailable; install hyperswine/tap/${kind === 'qos' ? 'qosmeta' : 'fprmeta'}.`, controls };
  let identity;
  try { const real = fs.realpathSync(manager), st = fs.statSync(real); identity = [real, st.ino, st.size, st.mtimeMs, st.ctimeMs]; } catch (_) {}
  const key = JSON.stringify([kind, cwd, identity, settings, controls.map(f => [f, signature(f)]), storeState(kind), process.env.FPR_TOOLCHAIN, process.env.QOS_SDK]);
  if (cache.has(key)) return cache.get(key);
  const result = spawnSync(manager, ['which', kind === 'qos' ? 'qos' : 'fpr', '--json'],
    { cwd, env: process.env, encoding: 'utf8', timeout: 2000, maxBuffer: 65536 });
  let selected;
  if (result.error || result.status !== 0) selected = { error: (result.stderr || result.stdout || result.error?.message || 'Toolchain selection failed').trim(), controls };
  else {
    try {
      const data = JSON.parse(result.stdout);
      if (data.format !== 1 || data.component !== (kind === 'qos' ? 'qos-portable' : 'fprisc')
          || !['compiler', 'moduleHome', 'metadata'].every(k => typeof data[k] === 'string' && path.isAbsolute(data[k]))
          || !['modulePaths', 'checkArgs'].every(k => Array.isArray(data[k]) && data[k].every(s => typeof s === 'string'))
          || typeof data.foreign !== 'string' || (data.foreign && !path.isAbsolute(data.foreign))) throw new Error('unsupported manager response');
      selected = { ...data, kind, manager, controls: [...controls, data.metadata] };
    } catch (_) { selected = { error: `Update ${kind === 'qos' ? 'qosmeta' : 'fprmeta'} to 0.2.0 or later for editor toolchain discovery.`, controls }; }
  }
  if (cache.size >= 64) cache.clear();
  cache.set(key, selected); return selected;
}
function clear() { cache.clear(); }
module.exports = { resolve, manifestFor, managerState, clear };
