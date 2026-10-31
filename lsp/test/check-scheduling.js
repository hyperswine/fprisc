'use strict';
const assert = require('assert/strict');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { createChecker, parseReport } = require('../server/compiler-check');
const { imports, snapshot, includes } = require('../server/check-inputs');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(predicate, label) {
  const end = Date.now() + 6000;
  while (!predicate()) { if (Date.now() > end) throw new Error('Timed out: ' + label); await sleep(10); }
}

(async () => {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'fpr-schedule-')));
  const file = name => path.join(dir, name);
  const write = (name, text) => { fs.mkdirSync(path.dirname(file(name)), { recursive: true }); fs.writeFileSync(file(name), text); return file(name); };
  const events = file('events.jsonl'), compiler = file('fpr');
  const buffers = new Map(), results = [], notices = [], checkers = [];
  const rows = () => fs.existsSync(events) ? fs.readFileSync(events, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse) : [];
  const starts = name => rows().filter(r => r.event === 'start' && (!name || r.name === name));
  const make = (options = {}) => {
    const checker = createChecker({ settings: () => ({ home: dir, compilerPath: compiler }), workspaceRoot: () => dir,
      readText: p => { try { return fs.readFileSync(p, 'utf8'); } catch (_) { return null; } },
      readOpen: p => buffers.get(p) ?? null, onResult: (p, report) => results.push({ p, report }),
      onMissing: (...args) => notices.push(args), delay: 20, ...options });
    checkers.push(checker); return checker;
  };
  const done = p => results.filter(r => r.p === p && r.report !== null);
  try {
    write('core/prelude.fpr', '# prelude\n'); write('fpr.toml', 'manifest = 1\n');
    write('fpr', `#!${process.execPath}
const fs=require('fs'),path=require('path');
const name=process.argv.find(a=>/\\.(fpr|sol)$/.test(a));const text=fs.readFileSync(name,'utf8');
const log=event=>fs.appendFileSync(${JSON.stringify(events)},JSON.stringify({event,name,pid:process.pid})+'\\n');
log('start');process.on('exit',()=>log('end'));
if(text.includes('IGNORETERM'))process.on('SIGTERM',()=>{});
setTimeout(()=>{if(text.includes('HUGE'))process.stdout.write('x'.repeat(20000));
if(text.includes('FAIL'))console.log('=== TYPE ERRORS ===\\n  * '+name+':1: in main: bad value');
process.exitCode=text.includes('FAIL')?1:0;},Number(/WAIT=(\\d+)/.exec(text)?.[1]||40));
`);
    fs.chmodSync(compiler, 0o755);
    const root = write('root.fpr', 'D = use "./dep".\nmain = D.value.\n');
    const dep = write('dep.fpr', 'L = use # comment\n "./leaf".\nvalue = L.value.\n');
    const leaf = write('leaf.fpr', 'value = 1.\n');
    const s = () => snapshot({ file: root, cwd: dir, home: dir, compiler, args: [], env: process.env,
      readOpen: p => buffers.get(p) ?? null });
    assert.deepEqual(imports('M = use # comment\n "x#abcd". # use "ignored"\ns = "use fake".\n').specs, ['x#abcd']);
    assert(imports('M = use # comment\n "x".').complete);
    assert(!imports('M = use dynamic.').complete);
    let before = s(); assert(before.complete && includes(before, leaf));
    assert(!includes(before, file('unrelated.fpr')));
    const stamp = fs.statSync(leaf); write('leaf.fpr', 'value = 2.\n'); fs.utimesSync(leaf, stamp.atime, stamp.mtime);
    assert.notEqual(s().key, before.key, 'same-size, restored-mtime source edits invalidate');
    before = s(); write('leaf.sol', 'value = 3.\n'); assert.notEqual(s().key, before.key, 'new resolution candidate invalidates');
    buffers.set(leaf, 'unsaved'); assert(s().dirty); buffers.clear();
    write('pin.fpr', 'M = use "gone#abcd".\n'); write('.fpr/store/abcd.fpr', 'D = use "../../leaf".\n');
    const pinned = snapshot({ file: file('pin.fpr'), cwd: dir, home: dir, compiler, args: [], env: process.env });
    assert(includes(pinned, file('.fpr/store/abcd.fpr')) && includes(pinned, leaf));
    const foreign = write('hal.fpr', 'primitive : Int.\n');
    const getForeign = () => snapshot({ file: root, cwd: dir, home: dir, compiler, args: ['--foreign=hal.fpr'], env: process.env });
    before = getForeign(); write('hal.fpr', 'primitive : String.\n'); assert.notEqual(getForeign().key, before.key);
    assert(includes(before, foreign));
    const environmentInputs = () => snapshot({ file: root, cwd: dir, home: dir, compiler, args: [],
      env: { ...process.env, FPR_FOREIGN: foreign, FPR_PATH: file('library') } });
    before = environmentInputs(); write('hal.fpr', 'primitive : Bool.\n');
    assert.notEqual(environmentInputs().key, before.key, 'FPR_FOREIGN content invalidates');
    before = environmentInputs(); write('library/core/prelude.fpr', 'value = 1.\n');
    assert.notEqual(environmentInputs().key, before.key, 'FPR_PATH fallback prelude invalidates');
    before = s(); fs.appendFileSync(compiler, '\n'); assert.notEqual(s().key, before.key, 'compiler replacement invalidates');
    console.log('check inputs: transitive, missing candidates, pins, foreign inputs, dirty buffers, compiler identity PASS');

    const checker = make();
    for (let i = 0; i < 12; i++) checker.check(root);
    await until(() => done(root).length === 1, 'coalesced root');
    assert.equal(starts('root.fpr').length, 1);
    checker.check(root); await sleep(100); assert.equal(starts('root.fpr').length, 1, 'unchanged success reuses report');
    assert.deepEqual(checker.affected(leaf), [root]);
    write('leaf.fpr', 'value = 4.\n'); checker.check(root);
    await until(() => starts('root.fpr').length === 2 && rows().filter(r => r.event === 'end').length >= 2, 'changed dependency');
    await until(() => done(root).length === 3, 'second result');
    buffers.set(dep, 'unsaved dependency'); checker.invalidate(dep); checker.check(root);
    await sleep(100); assert.equal(starts('root.fpr').length, 2); assert.equal(results.at(-1).report, null);
    buffers.clear(); checker.check(root); await until(() => starts('root.fpr').length === 3, 'saved dependency');
    await until(() => done(root).length === 4, 'saved dependency result');
    console.log('checker: 12 saves -> one run; unchanged -> zero runs; only affected roots; dirty dependency blocks PASS');

    const failure = write('failure.fpr', '# FAIL\nmain = bad.\n');
    checker.check(failure); await until(() => done(failure).length === 1, 'failed check');
    checker.check(failure); await until(() => done(failure).length === 2, 'failed check retried');
    assert.equal(starts('failure.fpr').length, 2);
    const stale = write('stale.fpr', '# WAIT=250\nD = use "./leaf".\nmain = D.value.\n');
    checker.check(stale); await until(() => starts('stale.fpr').length === 1, 'stale start');
    write('leaf.fpr', 'value = 5.\n'); await sleep(350); assert.equal(done(stale).length, 0, 'disk changed in flight: discard result');
    checker.check(stale); await until(() => starts('stale.fpr').length === 2, 'stale retry');
    checker.invalidate(stale); await sleep(300); assert.equal(done(stale).length, 0, 'edit cancellation cannot publish');

    const many = Array.from({ length: 6 }, (_, i) => write('q' + i + '.fpr', '# WAIT=100\nmain = 1.\n'));
    for (const p of many) checker.check(p);
    await until(() => many.every(p => done(p).length === 1), 'bounded queue');
    let live = 0, peak = 0;
    for (const row of rows().filter(r => /^q\d/.test(r.name))) { live += row.event === 'start' ? 1 : -1; peak = Math.max(peak, live); }
    assert(peak <= 2); assert.equal(live, 0);
    console.log('checker: failed runs retry, in-flight disk edits discarded, cancellation and queue bound PASS');

    const timeout = make({ timeout: 500, maxOutput: 1000 });
    const slow = write('slow.fpr', '# WAIT=10000 IGNORETERM\nmain = 1.\n');
    timeout.check(slow); await until(() => done(slow).length === 1, 'timeout escalation');
    assert.match(done(slow)[0].report.get(slow)[0].message, /timed out/);
    const huge = write('huge.fpr', '# HUGE\nmain = 1.\n'); timeout.check(huge);
    await until(() => done(huge).length === 1, 'output cap'); assert.match(done(huge)[0].report.get(huge)[0].message, /output exceeded/);
    const shutdown = write('shutdown.fpr', '# WAIT=10000 IGNORETERM\nmain = 1.\n');
    checker.check(shutdown); await until(() => starts('shutdown.fpr').length === 1, 'shutdown start');
    const pid = starts('shutdown.fpr')[0].pid; await checker.dispose();
    assert.throws(() => process.kill(pid, 0), /ESRCH/); assert.equal(done(shutdown).length, 0);
    console.log('checker: timeout, output bound, SIGTERM escalation and shutdown reap PASS');

    const unicode = 'main = "🙂" + bad.\n';
    const report = parseReport('u.fpr:1:14:\n  |\nerror here\n', { cwd: dir, mainPath: file('u.fpr'), readText: () => unicode, failed: true });
    assert.equal(report.get(file('u.fpr'))[0].range.start.character, 14);
    console.log('diagnostics: non-BMP compiler columns converted to UTF-16 PASS');
  } finally {
    await Promise.all(checkers.map(c => c.dispose())); fs.rmSync(dir, { recursive: true, force: true });
  }
})().catch(e => { console.error(e); process.exitCode = 1; });
