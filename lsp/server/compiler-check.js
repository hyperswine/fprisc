'use strict';
// compiler-check.js -- the compiler as the source of truth for errors.
//
// On open and on save, the file on disk is checked by the real compiler:
//   .fpr   fpr compile <fprArgs> --check-only FILE OUT    (OUT is never written)
//   .sol   fpr compile --target=bytecode FILE             (compiles, does not run)
// and its report becomes diagnostics. The report is text meant for people, so
// parseReport reads the shapes it actually has:
//
//   === TYPE ERRORS ===                      a section, then one item per error
//     * f.fpr:3: in g: <message>             located: path:line[:col]
//     * in main: <message>                   anchored only by the clause name
//     * loop is unsafe (recursive) but ...   anchored by a leading top-level name
//     * got into a typed hole, ?todo : x33   anchored by the hole
//   f.fpr:1:18:                              a parse error (megaparsec): a source
//     |  ...  ^^                             excerpt, then the message, ending at
//   unexpected ...                           a blank line
//   use: no such module file: ./x.fpr  ...   an import that did not resolve
//   error: <message>                         a refusal of the whole file
//
// A failed check that yields none of these still reports, as one file-level
// error carrying the compiler's own words: a failure is never silent.

const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const inputs = require('./check-inputs');
const { readReport } = require('./editor-report');

const SEVERITY = { error: 1, warning: 2, info: 3 };

const ANSI = /\x1b\[[0-9;]*m/g;
// a name, qualified or not; the `.` that ends a clause is not part of it
const IDENT = /[A-Za-z_?][\w'?]*(?:\.[A-Za-z_][\w']*)*/y;

function escapeRe(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

function slug(section) {
  const s = section.toUpperCase();
  if (s.startsWith('TYPE ERRORS')) return 'type-error';
  if (s.startsWith('TYPED HOLES')) return 'typed-hole';
  if (s.startsWith('SAFETY')) return 'safety';
  if (s.startsWith('LINEARITY')) return 'linearity';
  if (s.startsWith('PRECONDITION')) return 'precondition';
  if (s.startsWith('SIG/STRUCT')) return 'sig-struct';
  if (s.startsWith('PATH LITERALS')) return 'path-literal';
  if (s.startsWith('COST')) return 'cost';
  if (s.startsWith('MANIFEST')) return 'manifest';
  if (s.startsWith('TYPEID')) return 'typeid-collision';
  return s.toLowerCase().replace(/[^a-z]+/g, '-').replace(/^-|-$/g, '');
}

// ---------------------------------------------------------------------------
// locating a message in a file
// ---------------------------------------------------------------------------

function lineRange(lines, line) {
  const text = lines[line] || '';
  const start = text.length - text.trimStart().length;
  return { start: { line, character: start }, end: { line, character: Math.max(start + 1, text.trimEnd().length) } };
}

function tokenRange(lines, line, col) {
  const text = lines[line] || '';
  IDENT.lastIndex = col;
  const m = IDENT.exec(text);
  const end = m && m.index === col ? col + m[0].length : col + 1;
  return { start: { line, character: col }, end: { line, character: Math.min(Math.max(end, col + 1), Math.max(text.length, col + 1)) } };
}

function nameOnLine(lines, line, name) {
  const text = lines[line] || '';
  const re = new RegExp(`(^|[^\\w'.])(${escapeRe(name)})(?![\\w'])`);
  const m = re.exec(text);
  if (!m) return null;
  const c = m.index + m[1].length;
  return { start: { line, character: c }, end: { line, character: c + name.length } };
}

// the first top-level line for NAME: a signature or clause starts at column 0
function declRange(lines, name) {
  const re = new RegExp(`^${escapeRe(name)}(?=[\\s:=(]|$)`);
  for (let i = 0; i < lines.length; i++)
    if (re.test(lines[i])) return { start: { line: i, character: 0 }, end: { line: i, character: name.length } };
  return null;
}

// `<eval N>` is the Nth top-level `>` statement of a .sol script
function evalRange(lines, n) {
  let seen = 0;
  for (let i = 0; i < lines.length; i++)
    if (/^>/.test(lines[i]) && ++seen === n) return lineRange(lines, i);
  return null;
}

const FILE_LEVEL = { start: { line: 0, character: 0 }, end: { line: 0, character: 1 } };

// the clause a message names: `in main: ...`, `in <eval 2>: ...`
function anchorOf(message) {
  const m = /^in (<eval \d+>|[^\s:]+):/.exec(message);
  return m ? m[1] : null;
}

function rangeFor(lines, item) {
  const anchor = anchorOf(item.message);
  if (item.line !== undefined) {
    const line = Math.min(Math.max(item.line, 0), Math.max(lines.length - 1, 0));
    if (item.col !== undefined) {
      // Compiler columns count decoded characters; LSP uses UTF-16 units.
      const col = [...(lines[line] || '')].slice(0, Math.max(0, item.col)).join('').length;
      return tokenRange(lines, line, col);
    }
    if (anchor && !anchor.startsWith('<')) {
      const r = nameOnLine(lines, line, anchor);
      if (r) return r;
    }
    // Structured safety reports already locate the definition line but name
    // their owner in prose instead of an `in NAME:` prefix.
    const unsafeOwner = /^([A-Za-z_][\w']*) is unsafe\b/.exec(item.message);
    if (unsafeOwner) {
      const r = nameOnLine(lines, line, unsafeOwner[1]);
      if (r) return r;
    }
    return lineRange(lines, line);
  }
  if (anchor) {
    const ev = /^<eval (\d+)>$/.exec(anchor);
    const r = ev ? evalRange(lines, +ev[1]) : declRange(lines, anchor);
    if (r) return r;
  }
  const hole = /\?[A-Za-z_][\w']*/.exec(item.message);
  if (hole) {
    for (let i = 0; i < lines.length; i++) {
      const r = nameOnLine(lines, i, hole[0]);
      if (r) return r;
    }
  }
  const lead = /^([A-Za-z_][\w']*) /.exec(item.message);
  if (lead) {
    const r = declRange(lines, lead[1]);
    if (r) return r;
  }
  return FILE_LEVEL;
}

// `use: no such module file: ././nosuch.fpr` -> the `use "./nosuch"` line
function useRange(lines, missing) {
  const base = path.basename(missing).replace(/\.(fpr|sol)$/, '');
  for (let i = 0; i < lines.length; i++) {
    const m = /use\s+"([^"#]+)/.exec(lines[i]);
    if (m && path.basename(m[1]).replace(/\.(fpr|sol)$/, '') === base) {
      const c = m.index + m[0].indexOf('"');
      return { start: { line: i, character: c }, end: { line: i, character: c + m[1].length + 2 } };
    }
  }
  return FILE_LEVEL;
}

// ---------------------------------------------------------------------------
// the report
// ---------------------------------------------------------------------------

// output: everything the compiler printed. cwd: where it ran (relative paths
// in messages are relative to it). mainPath: the checked file. readText(abs):
// the text to locate against (an open editor's, else the disk's), or null.
// Returns Map(absolute path -> [Diagnostic]).
function parseReport(output, { cwd, mainPath, readText, failed }) {
  const out = new Map();
  const textCache = new Map();
  function linesOf(p) {
    if (!textCache.has(p)) {
      const t = readText(p);
      textCache.set(p, t === null || t === undefined ? [] : t.split(/\r?\n/));
    }
    return textCache.get(p);
  }
  function resolve(p) {
    const abs = path.isAbsolute(p) ? p : path.resolve(cwd, p);
    return fs.existsSync(abs) || readText(abs) !== null ? abs : null;
  }
  function add(file, range, message, code, severity) {
    if (!out.has(file)) out.set(file, []);
    out.get(file).push({ range, severity: severity || SEVERITY.error, source: 'fpr compile', code, message });
  }
  function addItem(item, code, severity) {
    let file = mainPath;
    let message = item.message;
    if (item.path) {
      const abs = resolve(item.path);
      if (abs) file = abs;
      else {
        // a location the editor cannot open (<prelude>, a generated file):
        // keep it in the words, report it on the checked file
        message = `${item.path}:${item.line + 1}: ${message}`;
        item = { message };
      }
    }
    add(file, rangeFor(linesOf(file), item), message, code, severity);
  }

  const lines = output.replace(ANSI, '').split(/\r?\n/);
  let section = null;
  let item = null;
  const flush = () => {
    if (!item) return;
    addItem(item, slug(section), /TYPED HOLES/.test(section) ? SEVERITY.warning : SEVERITY.error);
    item = null;
  };
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    let m;
    if ((m = /^=== (.+?) ===\s*$/.exec(l))) { flush(); section = m[1]; continue; }
    if (section && (m = /^ {2}\* (.*)$/.exec(l))) {
      flush();
      const body = m[1];
      const loc = /^(.+?):(\d+)(?::(\d+))?: ([\s\S]*)$/.exec(body);
      item = loc && !/^in /.test(loc[1])
        ? { path: loc[1], line: +loc[2] - 1, col: loc[3] ? +loc[3] - 1 : undefined, message: loc[4] }
        : { message: body };
      continue;
    }
    if (section && item && /^ {3,}\S/.test(l)) { item.message += '\n' + l.trim(); continue; }
    if (section && l.trim() !== '') { flush(); section = null; }
    if ((m = /^(\S.*?):(\d+):(\d+):\s*$/.exec(l))) {
      flush(); section = null;
      // megaparsec: excerpt + message up to the next blank line
      const msg = [];
      let j = i + 1;
      for (; j < lines.length && lines[j].trim() !== ''; j++)
        if (!/^\s*\d*\s*\|/.test(lines[j])) msg.push(lines[j].trim());
      i = j;
      addItem({ path: m[1], line: +m[2] - 1, col: +m[3] - 1, message: msg.join('\n') || 'parse error' }, 'parse');
      continue;
    }
    if ((m = /^use: no such module file: (.*?)(?:\s+\(nor |$)/.exec(l))) {
      add(mainPath, useRange(linesOf(mainPath), m[1]), l.slice('use: '.length).trim(), 'import');
      continue;
    }
    if ((m = /^(?:error|\[sol\]): (.*)$/.exec(l))) {
      addItem({ message: m[1] }, 'error');
      continue;
    }
  }
  flush();

  if (failed && out.size === 0) {
    const said = lines.filter((l) => l.trim() && !/^(use: \S+ resolves to|precond:|linear types:)/.test(l));
    add(mainPath, FILE_LEVEL, said.length ? said.slice(-12).join('\n') : 'the compiler check failed without a message', 'check-failed');
  }
  return out;
}

// ---------------------------------------------------------------------------
// running it
// ---------------------------------------------------------------------------

// The project root: the nearest directory at or above the file that holds a
// `.fpr` store (where `fpr commit` wrote it), else the workspace root when
// the file is inside it, else the file's own directory. The compiler looks
// for `.fpr/store` relative to where it runs, so this is where it runs: a
// pinned import that resolves from the store on the command line at the
// root resolves the same way in the editor.
function projectRoot(file, workspaceRoot) {
  let dir = path.dirname(file);
  for (;;) {
    // an fpr.toml marks a project root (`fpr new`), as `fpr check` finds it
    try { if (fs.statSync(path.join(dir, 'fpr.toml')).isFile()) return dir; } catch (e) { /* .fpr? */ }
    try { if (fs.statSync(path.join(dir, '.fpr')).isDirectory()) return dir; } catch (e) { /* up */ }
    const up = path.dirname(dir);
    if (up === dir) break;
    dir = up;
  }
  if (workspaceRoot && !path.relative(workspaceRoot, file).startsWith('..') && !path.isAbsolute(path.relative(workspaceRoot, file)))
    return workspaceRoot;
  return path.dirname(file);
}

function onPath(cmd) {
  for (const dir of (process.env.PATH || '').split(path.delimiter).filter(Boolean)) {
    const p = path.join(dir, cmd);
    try { if (fs.statSync(p).isFile()) return p; } catch (e) { /* next */ }
  }
  return null;
}

// The compiler's own home, as it computes it with no FPR_HOME: the directory
// its executable really lives in (symlinks resolved), when that holds the
// prelude. Null when the compiler cannot be found or is not laid out so.
function compilerHome(settings) {
  const c = compilerFor(settings);
  const exe = path.isAbsolute(c) ? c : onPath(c);
  if (!exe) return null;
  try {
    const dir = path.dirname(fs.realpathSync(exe));
    return fs.existsSync(path.join(dir, 'core', 'prelude.fpr')) ? dir : null;
  } catch (e) { return null; }
}

// Where an installed toolchain puts `fpr` (the Homebrew formula
// hyperswine/tap/fprisc links bin/fpr). VS Code started from the Dock or
// Finder does not get a login shell's PATH, so /opt/homebrew/bin is often
// missing from it even when `fpr` works in a terminal.
function installedCompilers() {
  return ['/opt/homebrew/bin/fpr', '/usr/local/bin/fpr', '/home/linuxbrew/.linuxbrew/bin/fpr',
    path.join(os.homedir(), '.local', 'bin', 'fpr')];
}

// the compiler: an explicit path, else the home's own `fpr`, else PATH, else
// an installed toolchain's usual place
function compilerFor(settings, installed = installedCompilers()) {
  if (settings.compilerPath) return settings.compilerPath;
  const home = settings.home || process.env.FPR_HOME;
  if (home) {
    const p = path.join(home, 'fpr');
    try { if (fs.statSync(p).isFile()) return p; } catch (e) { /* PATH */ }
  }
  if (onPath('fpr')) return 'fpr';
  for (const p of installed) {
    try { if (fs.statSync(p).isFile()) return p; } catch (e) { /* next */ }
  }
  return 'fpr';
}

// Run from the project root with the file's path relative to it, so the
// report's paths are short and the store is found. The .sol listing goes to
// stdout and the report to stderr; native reports go to stdout.
function commandFor(file, settings, cwd) {
  const name = path.relative(cwd || path.dirname(file), file);
  if (file.endsWith('.sol')) return { args: ['compile', '--target=bytecode', '--editor-json', name], stdout: false };
  const extra = Array.isArray(settings.checkArgs) ? settings.checkArgs : ['--system=posix'];
  const sink = path.join(os.tmpdir(), `fpr-check-${process.pid}.s`);
  return { args: ['compile', ...extra, '--check-only', '--editor-json', name, sink], stdout: true };
}

function envFor(settings) {
  const env = { ...process.env };
  if (settings.home) env.FPR_HOME = settings.home;
  const extra = [...(settings.modulePaths || []), ...(process.env.FPR_PATH || '').split(path.delimiter)].filter(Boolean);
  if (extra.length) env.FPR_PATH = extra.join(path.delimiter);
  return env;
}

// One checker per server. check(file) runs the compiler on the saved file; a
// newer request for the same file supersedes (kills) the one in flight.
// onResult(file, Map(path -> diags) | null) -- null when the compiler could
// not be started; onMissing(compiler, err) once per compiler path.
function createChecker({ settings, workspaceRoot, readText, readOpen = () => null, onResult, onMissing,
  concurrency = 2, delay = 120, timeout = 120000, maxOutput = 8 * 1024 * 1024 }) {
  const running = new Map(), jobs = new Set(), pending = new Map();
  const known = new Map(), cache = new Map(), reportedFiles = new Map(), legacyCompilers = new Set();
  const warned = new Set();
  let timer = null, disposed = false;
  function describe(file) {
    const s = settings(), compiler = compilerFor(s);
    const cwd = projectRoot(file, workspaceRoot ? workspaceRoot() : '');
    const cmd = commandFor(file, s, cwd), env = envFor(s);
    let identity = compiler;
    try { const st = fs.statSync(path.isAbsolute(compiler) ? compiler : onPath(compiler)); identity += `:${st.mtimeMs}:${st.ctimeMs}:${st.size}`; } catch (_) {}
    if (legacyCompilers.has(identity)) cmd.args = cmd.args.filter(a => a !== "--editor-json");
    const input = inputs.snapshot({ file, cwd, home: s.home || env.FPR_HOME || compilerHome(s),
      compiler, args: cmd.args, env, readOpen, additionalFiles: reportedFiles.get(file) || [] });
    return { file, compiler, identity, cwd, cmd, env, input };
  }
  function stop(job) {
    job.superseded = true;
    job.child.kill();
    if (!job.killTimer) job.killTimer = setTimeout(() => job.child.kill('SIGKILL'), 1000);
  }
  function check(file) {
    if (disposed) return;
    const request = describe(file), { input } = request;
    known.set(file, input);
    if (input.dirty) { cancel(file); onResult(file, null); return; }
    const previous = running.get(file);
    if (previous && !previous.superseded && input.complete && previous.input.key === input.key) return;
    if (previous) stop(previous);
    const hit = cache.get(file);
    if (hit && input.complete && hit.input.key === input.key) { onResult(file, hit.result); return; }
    cache.delete(file);
    onResult(file, null);
    pending.set(file, request);
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => { timer = null; drain(); }, delay);
  }
  function drain() {
    if (disposed) return;
    while (jobs.size < concurrency && pending.size) {
      const [file] = pending.keys(); pending.delete(file);
      // Re-read at dequeue: inputs may change while another check is running.
      const request = describe(file);
      known.set(file, request.input);
      if (!request.input.dirty) start(request);
    }
  }
  function start({ file, compiler, identity, cwd, cmd, env, input }) {
    let child;
    try {
      child = spawn(compiler, cmd.args, { cwd, env, stdio: ['ignore', cmd.stdout ? 'pipe' : 'ignore', 'pipe'] });
    } catch (e) {
      missing(compiler, e); onResult(file, null); return;
    }
    const job = { child, input, superseded: false, error: null };
    running.set(file, job); jobs.add(job);
    const chunks = [];
    let size = 0;
    function fail(message) {
      if (job.failure) return;
      job.failure = message; clearTimeout(limit); stop(job);
    }
    const limit = setTimeout(() => fail('Compiler check timed out; save to retry.'), timeout);
    const collect = c => {
      size += c.length;
      if (size > maxOutput) { if (!job.failure) fail('Compiler check output exceeded its limit; save to retry.'); }
      else chunks.push(c);
    };
    if (child.stdout) child.stdout.on('data', collect);
    child.stderr.on('data', collect);
    child.on('error', (e) => {
      job.error = e;
    });
    child.on('close', (code) => {
      clearTimeout(limit); clearTimeout(job.killTimer); jobs.delete(job);
      const current = running.get(file) === job;
      if (current) running.delete(file);
      if (!disposed && current && (!job.superseded || job.failure)) {
        const now = describe(file).input;
        if (!now.dirty && now.key === input.key) {
          if (job.error) { missing(compiler, job.error); onResult(file, null); }
          else if (job.failure || code !== null) {
            const output = job.failure ? 'error: ' + job.failure : Buffer.concat(chunks).toString('utf8');
            const options = { cwd, mainPath: file, readText, failed: code !== 0 };
            let parsed, reportError;
            try { parsed = readReport(output, { readText, readOpen, failed: code !== 0 }); }
            catch (e) { reportError = e.message; }
            // Older toolchains reject the new option. Retry their original
            // check once, and remember that capability until the binary changes.
            if (!parsed && !reportError && !job.failure && code !== 0 && cmd.args.includes('--editor-json') &&
                /unknown Sol option --editor-json|usage:.*(?:compile|fpr)|--editor-json.*(?:does not exist|No such file)/is.test(output)) {
              legacyCompilers.add(identity); check(file); drain(); return;
            }
            if (parsed && parsed.stale) { onResult(file, null); drain(); return; }
            let result;
            if (reportError) result = parseReport('error: ' + reportError, { ...options, failed: true });
            else if (parsed) {
              const { report, texts } = parsed;
              // The compiler's cwd can canonicalize symlinks (/var ->
              // /private/var on macOS). Preserve the editor's URI spelling.
              const aliases = new Map([...input.files].reverse().map(([name, info]) => [info.real, name]));
              const editorPath = name => { try { return aliases.get(fs.realpathSync(name)) || name; } catch (_) { return name; } };
              report.types = report.types.map(t => ({ ...t, file: editorPath(t.file) }));
              result = new Map();
              for (const d of report.diagnostics) {
                // For deliberately file-level legacy gates, retain the legacy
                // range refinement, but keep the compiler's message and code.
                const lines = (texts.get(d.file) || readText(d.file) || '').split(/\r?\n/);
                const missing = /no such module file: (.*?)(?:\s+\(nor |$)/.exec(d.message);
                const item = { message: d.message };
                if (d.precision !== 'file') item.line = d.start.line;
                if (d.precision === 'point') item.col = d.start.character;
                const range = missing ? useRange(lines, missing[1]) : rangeFor(lines, item);
                const target = editorPath(d.file);
                if (!result.has(target)) result.set(target, []);
                result.get(target).push({ range, message: d.message, code: d.code, severity: d.code === 'typed-hole' ? 2 : d.severity, source: 'fpr compile' });
              }
              // A gate not migrated to structured diagnostics still reports its
              // original words; do not hide that failure behind a generic label.
              if (report.diagnostics.some(d => d.code === 'check-failed')) result = parseReport(output.split(/\r?\n/).filter(l => !l.startsWith('{"editorVersion"')).join('\n'), options);
              result.editor = report;
              reportedFiles.set(file, report.inputs.map(i => i.file));
            } else result = parseReport(output, options);
            const completed = describe(file).input;
            known.set(file, completed);
            if (!reportError && !job.failure && code === 0 && completed.complete && !completed.dirty) cache.set(file, { input: completed, result });
            onResult(file, result);
          }
        }
      }
      drain();
    });
  }
  function missing(compiler, e) {
    if (warned.has(compiler)) return;
    warned.add(compiler);
    onMissing(compiler, e);
  }
  function cancel(file) {
    pending.delete(file); cache.delete(file);
    const job = running.get(file);
    if (job) { stop(job); running.delete(file); }
  }
  function affected(file) { return [...known].filter(([, input]) => inputs.includes(input, file)).map(([root]) => root); }
  function invalidate(file) {
    const roots = affected(file);
    for (const root of roots) { cancel(root); onResult(root, null); }
    return roots;
  }
  function forget(file) { cancel(file); known.delete(file); reportedFiles.delete(file); }
  async function dispose() {
    disposed = true; clearTimeout(timer); pending.clear(); cache.clear(); known.clear();
    await Promise.all([...jobs].map(job => new Promise(resolve => {
      job.child.once('close', resolve); stop(job);
    })));
  }
  return { check, cancel, affected, invalidate, forget, dispose };
}

module.exports = { parseReport, createChecker, compilerFor, compilerHome, commandFor, projectRoot, envFor, installedCompilers };
