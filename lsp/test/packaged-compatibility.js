'use strict';
// Exercise the reader actually shipped in the VSIX against both compiler profiles.
const assert = require('assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const root = path.resolve(__dirname, '../..');
const archive = path.resolve(process.argv[2]);
const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'fpr-vsix-compat-')));
try {
  const unpack = spawnSync('unzip', ['-q', archive, 'extension/server/editor-report.js', 'extension/package.json', '-d', tmp], { encoding: 'utf8' });
  assert.equal(unpack.status, 0, unpack.stderr);
  assert.equal(require(path.join(tmp, 'extension/package.json')).version, require('../package.json').version);
  const { readReport } = require(path.join(tmp, 'extension/server/editor-report.js'));
  for (const profile of ['fpr', 'sol']) {
    const file = path.join(tmp, `main.${profile}`);
    for (const broken of [false, true]) {
      fs.writeFileSync(file, broken ? 'value = packaged_missing_name.\n' : 'value = 42.\n' + (profile === 'sol' ? '> print "MUST NOT EXECUTE".\n' : ''));
      const result = spawnSync(path.join(root, 'fpr'), ['compile', ...(profile === 'sol' ? ['--target=bytecode'] : ['--system=posix', '--check-only']), '--editor-json', file, ...(profile === 'sol' ? [] : [path.join(tmp, 'unused.s')])],
        { encoding: 'utf8', timeout: 15000, env: { ...process.env, FPR_HOME: root } });
      assert.ifError(result.error);
      assert.equal(result.status, broken ? 1 : 0, result.stderr + result.stdout);
      const parsed = readReport(result.stdout + '\n' + result.stderr, { readText: p => fs.readFileSync(p, 'utf8'), readOpen: () => null, failed: broken });
      assert(parsed && !parsed.stale, 'packaged reader must accept the current compiler report');
      assert.equal(parsed.report.ok, !broken);
      assert.equal(parsed.report.diagnostics.length > 0, broken);
      assert(!result.stdout.includes('MUST NOT EXECUTE'));
      assert(!fs.existsSync(path.join(tmp, 'unused.s')));
    }
  }
  console.log('VSIX compatibility: current FP-RISC/Sol success and error reports, no script execution PASS');
} finally { fs.rmSync(tmp, { recursive: true, force: true }); }
