#!/usr/bin/env node
// discovery.js -- which compiler the extension runs, and where it runs it.
//
//   node test/discovery.js
//
// No compiler needed: fake executables in a temp directory stand in for an
// installed toolchain, a module home and PATH.
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const { compilerFor, compilerHome, projectRoot } = require('../server/compiler-check');

let fails = 0;
function ok(cond, what, detail) {
  if (cond) console.log(`  ok   ${what}`);
  else { fails++; console.log(`  FAIL ${what}${detail ? ' -- ' + detail : ''}`); }
}
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'fpr-discovery-'));
function exe(p) { fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, '#!/bin/sh\n'); fs.chmodSync(p, 0o755); return p; }

const savedPath = process.env.PATH, savedHome = process.env.FPR_HOME;
delete process.env.FPR_HOME;
try {
  console.log('== compiler ==');
  // an SDK laid out as the formula installs it: bin/fpr -> ../libexec/fprisc/fpr
  const sdk = path.join(tmp, 'brew');
  const real = exe(path.join(sdk, 'libexec', 'fprisc', 'fpr'));
  fs.mkdirSync(path.join(sdk, 'libexec', 'fprisc', 'core'), { recursive: true });
  fs.writeFileSync(path.join(sdk, 'libexec', 'fprisc', 'core', 'prelude.fpr'), '');
  fs.mkdirSync(path.join(sdk, 'bin'));
  fs.symlinkSync('../libexec/fprisc/fpr', path.join(sdk, 'bin', 'fpr'));
  const installed = [path.join(tmp, 'absent', 'fpr'), path.join(sdk, 'bin', 'fpr')];

  process.env.PATH = path.join(tmp, 'empty');
  ok(compilerFor({}, installed) === path.join(sdk, 'bin', 'fpr'), 'not on PATH: the installed toolchain is found');
  ok(compilerFor({}, []) === 'fpr', 'nothing installed: plain fpr (the missing-compiler notice follows)');
  ok(compilerFor({ compilerPath: '/x/fpr' }, installed) === '/x/fpr', 'fpr.compilerPath wins');
  const home = path.join(tmp, 'checkout');
  exe(path.join(home, 'fpr'));
  ok(compilerFor({ home }, installed) === path.join(home, 'fpr'), "fpr.home's own fpr comes before PATH and installs");

  const bin = path.join(tmp, 'pathbin');
  exe(path.join(bin, 'fpr'));
  process.env.PATH = bin;
  ok(compilerFor({}, installed) === 'fpr', 'on PATH: PATH wins over the usual install places');

  // the home follows the symlink to the SDK, which holds core/prelude.fpr
  process.env.PATH = path.join(tmp, 'empty');
  const h = compilerHome({ compilerPath: path.join(sdk, 'bin', 'fpr') });
  ok(h === fs.realpathSync(path.dirname(real)), 'the installed compiler\'s home is its SDK', h);

  console.log('== project root ==');
  const proj = path.join(tmp, 'hello');
  fs.mkdirSync(path.join(proj, 'src', 'deep'), { recursive: true });
  fs.writeFileSync(path.join(proj, 'fpr.toml'), 'manifest = 1\n');
  ok(projectRoot(path.join(proj, 'src', 'deep', 'a.fpr'), '') === proj, 'fpr.toml marks the root, from a subdirectory');
  fs.mkdirSync(path.join(proj, 'src', '.fpr'));
  ok(projectRoot(path.join(proj, 'src', 'deep', 'a.fpr'), '') === path.join(proj, 'src'), 'the nearest marker wins (.fpr store)');
  const loose = path.join(tmp, 'loose');
  fs.mkdirSync(loose);
  ok(projectRoot(path.join(loose, 'a.fpr'), '') === loose, 'no marker: the file\'s directory');
} finally {
  process.env.PATH = savedPath;
  if (savedHome !== undefined) process.env.FPR_HOME = savedHome;
  fs.rmSync(tmp, { recursive: true, force: true });
}
console.log(fails ? `discovery: FAIL (${fails})` : 'discovery: ok');
process.exit(fails ? 1 : 0);
