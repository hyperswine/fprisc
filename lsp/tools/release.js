#!/usr/bin/env node
'use strict';
// Package and publish the SAME tested artifact. No implicit version bump,
// git write, credential lookup or installation into the user's editor.
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const root = path.resolve(__dirname, '..');

function plan(mode, dryRun = false) {
  if (!['package', 'publish'].includes(mode)) throw new Error('Expected package or publish');
  const pkg = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
  if (pkg.name !== 'fpr-lang' || pkg.publisher !== 'jasen') throw new Error('Marketplace identity changed');
  if (!/^\d+\.\d+\.\d+$/.test(pkg.version)) throw new Error('Set a stable extension version before releasing');
  const vsix = path.join(root, 'artifacts', `${pkg.name}-${pkg.version}.vsix`);
  const vsce = path.join(root, 'node_modules', '@vscode', 'vsce', 'vsce');
  const commands = [
    [process.platform === 'win32' ? 'npm.cmd' : 'npm', ['test']],
    [process.execPath, [vsce, 'package', '--out', vsix,
      '--baseContentUrl', 'https://github.com/hyperswine/fprisc/blob/main/lsp/',
      '--baseImagesUrl', 'https://github.com/hyperswine/fprisc/raw/main/lsp/']],
  ];
  if (mode === 'publish' && !dryRun) commands.push([process.execPath, [vsce, 'publish', '--packagePath', vsix]]);
  return { vsix, commands };
}

function main(argv) {
  if (argv.length === 1 && ['--help', '-h'].includes(argv[0])) {
    console.log('Usage: node tools/release.js package|publish [--dry-run]\nRuns tests and packages a VSIX; publish uploads that exact artifact. --dry-run packages without uploading.');
    return;
  }
  if (argv.length > 2 || (argv[1] && argv[1] !== '--dry-run')) throw new Error('Unexpected release arguments (use --help)');
  const { vsix, commands } = plan(argv[0], argv[1] === '--dry-run');
  fs.mkdirSync(path.dirname(vsix), { recursive: true });
  for (const [command, args] of commands) {
    const result = spawnSync(command, args, { cwd: root, stdio: 'inherit' });
    if (result.error) throw result.error;
    if (result.status !== 0) throw new Error(`${path.basename(command)} failed (${result.signal || result.status})`);
  }
  console.log(`${argv[0] === 'publish' && argv[1] !== '--dry-run' ? 'Published' : 'Packaged'} ${vsix}`);
}
if (require.main === module) {
  try { main(process.argv.slice(2)); } catch (e) { console.error(e.message); process.exitCode = 1; }
}
module.exports = { plan };
