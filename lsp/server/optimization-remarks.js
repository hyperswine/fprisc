'use strict';
// Explicit native analysis only. The ordinary checker remains independent.
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { spawn } = require('child_process');
const { compilerFor, projectRoot, envFor } = require('./compiler-check');

function digest(bytes) {
  let h = 14695981039346656037n;
  for (const byte of bytes) h = BigInt.asUintN(64, (h ^ BigInt(byte)) * 1099511628211n);
  return h.toString(16).padStart(16, '0');
}
function parseRemarks(text, cwd) {
  let inputs = null;
  const records = [];
  for (const line of text.split(/\r?\n/)) {
    if (!line.startsWith('{')) continue; // legacy diagnostics/debug output
    let r;
    try { r = JSON.parse(line); } catch (_) { throw new Error('Malformed compiler remark JSON'); }
    if (r.remarkInputsVersion !== undefined) {
      if (inputs || r.remarkInputsVersion !== 1 || r.algorithm !== 'fnv1a-64-utf8' || !Array.isArray(r.files) || !r.files.length)
        throw new Error('Unsupported compiler remark input manifest');
      inputs = new Map();
      for (const f of r.files) {
        if (typeof f.file !== 'string' || !/^[0-9a-f]{16}$/.test(f.digest)) throw new Error('Invalid remark input');
        const file = path.resolve(cwd, f.file);
        if (inputs.has(file)) throw new Error('Duplicate remark input');
        inputs.set(file, f.digest);
      }
    } else if (r.remarkVersion !== undefined) {
      if (r.remarkVersion !== 1 || r.positionEncoding !== 'utf-32' || typeof r.kind !== 'string'
          || typeof r.owner !== 'string' || typeof r.message !== 'string' || !['applied', 'declined'].includes(r.outcome))
        throw new Error('Unsupported compiler remark record');
      records.push({ ...r, file: typeof r.file === 'string' ? path.resolve(cwd, r.file) : null });
    }
  }
  if (!inputs) throw new Error('Compiler did not provide source snapshots; use an updated FP-RISC compiler');
  if (records.some(r => r.file && !inputs.has(r.file))) throw new Error('Remark location has no source snapshot');
  return { inputs, records };
}
function diagnostics(records, readText) {
  const result = new Map();
  for (const r of records) {
    if (!r.file || !r.start) continue;
    const text = readText(r.file);
    if (text === null) continue;
    const lines = text.split(/\r?\n/);
    const point = p => {
      if (!p || !Number.isInteger(p.line) || !Number.isInteger(p.character) || p.line < 0 || p.line >= lines.length || p.character < 0) return null;
      const chars = [...lines[p.line]];
      if (p.character > chars.length) return null;
      return { line: p.line, character: chars.slice(0, p.character).join('').length };
    };
    const start = point(r.start);
    if (!start) continue;
    const end = r.precision === 'definition' && r.end === null
      ? { line: start.line, character: lines[start.line].length } : point(r.end);
    if (!end || end.line < start.line || (end.line === start.line && end.character < start.character)) continue;
    if (!result.has(r.file)) result.set(r.file, []);
    result.get(r.file).push({ range: { start, end }, severity: 3, source: 'fpr optimization', code: r.kind,
      codeDescription: { href: 'https://github.com/hyperswine/fprisc/blob/main/docs/2026-10-27-OPTIMIZATION-REMARKS.md#catalogue' },
      message: `${r.owner}: ${r.message}`, data: { reason: r.reason, pass: r.pass, heat: r.heat } });
  }
  return result;
}
function createRemarkRunner({ settings, workspaceRoot, readOpen, onResult, onInvalidated }) {
  let generation = 0, active = null, published = false, serial = 0, temporary = null, disposed = false;
  const jobs = new Set(), watchers = [];
  const disk = file => { try { return fs.readFileSync(file, 'utf8'); } catch (_) { return null; } };
  function clearWatchers() { for (const watcher of watchers.splice(0)) watcher.close(); }
  function invalidate(reason = 'Source or configuration changed') {
    generation++;
    clearWatchers();
    if (active) { active.finish({ status: 'cancelled', message: reason }); active.child.kill(); active = null; }
    if (published) { published = false; onResult(new Map()); onInvalidated(reason); }
  }
  function current(inputs) {
    for (const [file, expected] of inputs) {
      const saved = disk(file), open = readOpen(file);
      if (saved === null || digest(Buffer.from(saved, 'utf8')) !== expected || (open !== null && open !== saved)) return false;
    }
    return true;
  }
  function watch(inputs) {
    const directories = new Map();
    for (const file of inputs.keys()) {
      const dir = path.dirname(file);
      if (!directories.has(dir)) directories.set(dir, new Set());
      directories.get(dir).add(path.basename(file));
    }
    for (const [dir, names] of directories) {
      const watcher = fs.watch(dir, (_, name) => {
        if (!name || names.has(String(name))) invalidate('A compiled source file changed');
      });
      watcher.on('error', () => invalidate('Source watching stopped; rerun remarks'));
      watchers.push(watcher);
    }
  }
  function run(file) {
    invalidate('Superseded by a new remark request');
    if (disposed) return Promise.resolve({ status: 'cancelled' });
    const s = settings(), cwd = projectRoot(file, workspaceRoot());
    const saved = disk(file), open = readOpen(file);
    if (!file.endsWith('.fpr') || saved === null || (open !== null && open !== saved))
      return Promise.resolve({ status: 'error', message: 'Save this native .fpr file before requesting remarks' });
    const extra = (Array.isArray(s.checkArgs) ? s.checkArgs : ['--system=posix'])
      .filter(a => a !== '--check-only' && !/^--remarks(?:=|$)/.test(a));
    if (extra.some(a => /^(--lib|--stdcheck|--arc|--raw|--sol|--target=bytecode|--manifest)$/.test(a) || a.startsWith('--manifest=')))
      return Promise.resolve({ status: 'error', message: 'This remark command supports native Base files and modules; remove incompatible checkArgs' });
    try { if (!temporary) temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'fpr-editor-remarks-')); }
    catch (e) { return Promise.resolve({ status: 'error', message: e.message }); }
    const output = path.join(temporary, `${++serial}-${crypto.createHash('sha256').update(file).digest('hex').slice(0, 12)}.s`);
    const ticket = generation;
    return new Promise(resolve => {
      const child = spawn(compilerFor(s), ['compile', ...extra, '--plugin', '--remarks=json', file, output],
        { cwd, env: envFor(s), stdio: ['ignore', 'pipe', 'pipe'] });
      const job = { child, done: false, finish(result) { if (!this.done) { this.done = true; resolve(result); } } };
      active = job; jobs.add(job);
      const chunks = []; let size = 0;
      const collect = chunk => {
        size += chunk.length;
        if (size > 64 * 1024 * 1024) { job.finish({ status: 'error', message: 'Compiler remark output exceeded 64 MiB' }); child.kill(); }
        else chunks.push(chunk);
      };
      child.stdout.on('data', collect); child.stderr.on('data', collect);
      child.on('error', e => job.finish({ status: 'error', message: `Could not run FP-RISC compiler: ${e.code || e.message}` }));
      child.on('close', code => {
        jobs.delete(job); if (active === job) active = null;
        for (const suffix of ['', '.units', '.abirev']) { try { fs.unlinkSync(output + suffix); } catch (_) { /* absent */ } }
        if (job.done || ticket !== generation || disposed) { job.finish({ status: 'cancelled' }); return; }
        const text = Buffer.concat(chunks).toString('utf8');
        if (code !== 0) { job.finish({ status: 'error', message: text.trim().split('\n').slice(-12).join('\n') || 'Compiler failed' }); return; }
        try {
          const { inputs, records } = parseRemarks(text, cwd);
          if (!inputs.has(file) || !current(inputs)) { job.finish({ status: 'stale', message: 'Source changed or a dependency has unsaved edits; save and rerun remarks' }); return; }
          // Install watchers before the final check to close the publication gap.
          watch(inputs);
          if (!current(inputs)) { clearWatchers(); job.finish({ status: 'stale', message: 'Source changed during analysis' }); return; }
          const byPath = diagnostics(records, disk);
          published = true; onResult(byPath);
          job.finish({ status: 'ok', records });
        } catch (e) { clearWatchers(); job.finish({ status: 'error', message: e.message }); }
      });
    });
  }
  async function dispose() {
    disposed = true; invalidate('Language server stopped');
    await Promise.all([...jobs].map(job => new Promise(resolve => {
      if (job.child.exitCode !== null) { resolve(); return; }
      const timer = setTimeout(() => job.child.kill('SIGKILL'), 1000);
      job.child.once('close', () => { clearTimeout(timer); resolve(); }); job.child.kill();
    })));
    if (temporary) fs.rmSync(temporary, { recursive: true, force: true });
  }
  return { run, invalidate, dispose };
}
module.exports = { digest, parseRemarks, diagnostics, createRemarkRunner };
