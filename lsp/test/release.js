'use strict';
const assert = require('assert/strict');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawnSync } = require('child_process');
const { plan, commandEnvironment, redact } = require('../tools/release');
const pkg = require('../package.json');
const lock = require('../package-lock.json');
assert.equal(pkg.publisher, 'hyperswine');
assert.equal(pkg.version, lock.version);
assert.equal(pkg.version, lock.packages[''].version);
assert.equal(pkg.repository.directory, 'lsp');
assert.equal(pkg.engines.vscode, '^1.82.0');
assert.equal(pkg.devDependencies['@vscode/vsce'], lock.packages['node_modules/@vscode/vsce'].version);
const packaged = plan('package'), dry = plan('publish', true), published = plan('publish');
assert.deepEqual(dry, packaged);
assert.equal(packaged.commands.length, 3);
assert.equal(packaged.commands[0][1][0], 'test');
assert(packaged.commands[2][1][0].endsWith('packaged-compatibility.js'));
assert.equal(packaged.commands[2][1][1], packaged.vsix);
assert(!packaged.commands.some(([, args]) => args.includes('publish')));
assert.deepEqual(published.commands.slice(0, 3), packaged.commands);
assert.deepEqual(published.commands[3][1].slice(-3), ['publish', '--packagePath', packaged.vsix]);
assert.throws(() => plan('unpublish'));
assert(fs.existsSync(path.join(__dirname, '../../compiler/Infer.hs')));
console.log('release: identity, lock, monorepo layout, test-before-package and exact-artifact publish PASS');

const verified = plan('verify');
assert.deepEqual(verified.commands[0][1].slice(-2), ['verify-pat', 'hyperswine']);
assert.equal(verified.commands.length, 1);
assert.throws(() => plan('verify', true));
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'fpr-publish-env-'));
try {
  const local = path.join(tmp, '.env');
  fs.writeFileSync(local, 'AZURE_DEVOPS_PAT="local-test-value"\nOTHER=unrelated\n', { mode: 0o600 });
  const base = { PATH: '/test/path' };
  const publishArgs = published.commands.at(-1)[1];
  assert.deepEqual(commandEnvironment(publishArgs, base, local), { ...base, VSCE_PAT: 'local-test-value' });
  assert.deepEqual(base, { PATH: '/test/path' });
  assert.equal(commandEnvironment(publishArgs, { VSCE_PAT: 'explicit-test-value' }, local).VSCE_PAT, 'explicit-test-value');
  assert.equal(commandEnvironment(publishArgs, { AZURE_DEVOPS_PAT: 'process-test-value' }, local).VSCE_PAT, 'process-test-value');
  for (const [, args] of [...packaged.commands, ...dry.commands]) {
    assert.strictEqual(commandEnvironment(args, base, local), base);
  }
  fs.writeFileSync(local, 'OTHER=not-a-publishing-credential\n');
  assert.throws(() => commandEnvironment(publishArgs, base, local), /must define/);
  assert.strictEqual(commandEnvironment(packaged.commands[0][1], base, local), base);
  assert.throws(() => commandEnvironment(publishArgs, base, path.join(tmp, 'absent')), /saved credentials are not used/);
  assert.equal(redact('Authorization: Basic ' + Buffer.from('vsce:local-test-value').toString('base64'), 'local-test-value'), 'Authorization: Basic [REDACTED]');
  assert.equal(redact('raw local-test-value and ' + Buffer.from(':local-test-value').toString('base64'), 'local-test-value'), 'raw [REDACTED] and [REDACTED]');
} finally {
  fs.rmSync(tmp, { recursive: true });
}
// Exercise vsce's real file selection; .gitignore is not the VSIX allow-list.
const probe = path.join(__dirname, '..', `.env.release-check-${process.pid}`);
try {
  fs.writeFileSync(probe, 'AZURE_DEVOPS_PAT=packaging-test-value\n', { mode: 0o600 });
  const vsce = packaged.commands[1][1][0];
  const files = spawnSync(process.execPath, [vsce, 'ls'], { cwd: path.join(__dirname, '..'), encoding: 'utf8' });
  assert.equal(files.status, 0, files.stderr);
  assert(!files.stdout.split(/\r?\n/).some(file => /(^|\/)\.env(?:\.|$)/.test(file)), 'Local environment file would enter the VSIX');
} finally {
  fs.rmSync(probe, { force: true });
}
console.log('release: local PAT isolation, explicit overrides, verification and actual VSIX environment-file exclusion PASS');
