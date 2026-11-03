#!/usr/bin/env node
'use strict';
// Package and publish the SAME tested artifact. No implicit version bump,
// git write or installation into the user's editor. Local publishing credentials
// are loaded only for an authenticated vsce operation, never tests/packaging.
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { parseEnv } = require('node:util');
const root = path.resolve(__dirname, '..');

function plan(mode, dryRun = false) {
  if (!['package', 'publish', 'verify'].includes(mode)) throw new Error('Expected package, publish or verify');
  if (mode === 'verify' && dryRun) throw new Error('verify is read-only and does not accept --dry-run');
  const pkg = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
  if (pkg.name !== 'fpr-lang' || pkg.publisher !== 'hyperswine') throw new Error('Marketplace identity changed');
  if (!/^\d+\.\d+\.\d+$/.test(pkg.version)) throw new Error('Set a stable extension version before releasing');
  const vsix = path.join(root, 'artifacts', `${pkg.name}-${pkg.version}.vsix`);
  const vsce = path.join(root, 'node_modules', '@vscode', 'vsce', 'vsce');
  if (mode === 'verify') return { vsix, commands: [[process.execPath, [vsce, 'verify-pat', pkg.publisher]]] };
  const commands = [
    [process.platform === 'win32' ? 'npm.cmd' : 'npm', ['test']],
    [process.execPath, [vsce, 'package', '--out', vsix,
      '--baseContentUrl', 'https://github.com/hyperswine/fprisc/blob/main/lsp/',
      '--baseImagesUrl', 'https://github.com/hyperswine/fprisc/raw/main/lsp/']],
  ];
  if (mode === 'publish' && !dryRun) commands.push([process.execPath, [vsce, 'publish', '--packagePath', vsix]]);
  return { vsix, commands };
}

// Explicit process credentials override the ignored local .env. Never persist
// credentials in vsce's credential store or inject local secrets into npm test.
function commandEnvironment(args, base = process.env, envFile = path.join(root, '.env')) {
  if (!['publish', 'verify-pat'].includes(args[1])) return base;
  let pat = base.VSCE_PAT || base.AZURE_DEVOPS_PAT;
  if (!pat && fs.existsSync(envFile)) {
    const local = parseEnv(fs.readFileSync(envFile, 'utf8'));
    pat = local.VSCE_PAT || local.AZURE_DEVOPS_PAT;
    if (!pat) throw new Error('Local .env must define VSCE_PAT or AZURE_DEVOPS_PAT for publishing');
  }
  if (!pat) throw new Error('Set VSCE_PAT or AZURE_DEVOPS_PAT in the environment or local lsp/.env; saved credentials are not used');
  return { ...base, VSCE_PAT: pat };
}

function redact(text, pat) {
  if (!pat) return text;
  return text.split(pat).join('[REDACTED]')
    .split(Buffer.from(':' + pat).toString('base64')).join('[REDACTED]')
    .replace(/\b(Basic|Bearer)\s+[A-Za-z0-9+/_=.-]+/gi, '$1 [REDACTED]');
}

function main(argv) {
  if (argv.length === 1 && ['--help', '-h'].includes(argv[0])) {
    console.log('Usage: node tools/release.js package|publish|verify [--dry-run]\nPackage runs tests and creates a VSIX; publish uploads that artifact. --dry-run packages without uploading. verify checks publisher access without uploading. Publish/verify accept VSCE_PAT or AZURE_DEVOPS_PAT from the environment or ignored local .env.');
    return;
  }
  if (argv.length > 2 || (argv[1] && argv[1] !== '--dry-run')) throw new Error('Unexpected release arguments (use --help)');
  const { vsix, commands } = plan(argv[0], argv[1] === '--dry-run');
  if (argv[0] !== 'verify') fs.mkdirSync(path.dirname(vsix), { recursive: true });
  for (const [command, args] of commands) {
    const env = commandEnvironment(args);
    const authenticated = ['publish', 'verify-pat'].includes(args[1]);
    const result = spawnSync(command, args, { cwd: root, env,
      stdio: authenticated ? ['ignore', 'pipe', 'pipe'] : 'inherit', encoding: 'utf8' });
    if (authenticated) {
      process.stdout.write(redact(result.stdout || '', env.VSCE_PAT));
      process.stderr.write(redact(result.stderr || '', env.VSCE_PAT));
    }
    if (result.error) throw result.error;
    if (result.status !== 0) throw new Error(`${path.basename(command)} failed (${result.signal || result.status})`);
  }
  if (argv[0] !== 'verify') console.log(`${argv[0] === 'publish' && argv[1] !== '--dry-run' ? 'Published' : 'Packaged'} ${vsix}`);
}
if (require.main === module) {
  try { main(process.argv.slice(2)); } catch (e) { console.error(e.message); process.exitCode = 1; }
}
module.exports = { plan, commandEnvironment, redact };
