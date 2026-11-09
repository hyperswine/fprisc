'use strict';
const assert = require('assert/strict');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawnSync } = require('child_process');
const { readReport } = require('../server/editor-report');
const root = path.resolve(__dirname, '../..');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fpr-resource-editor-'));
const readText = f => fs.readFileSync(f, 'utf8');
function check(name, extra = [], budget = '1000') {
  const p = spawnSync(path.join(root, 'fpr'), ['compile', '--system=posix', '--check-only', '--editor-json', ...extra,
    path.isAbsolute(name) ? name : path.join(root, name), path.join(dir, 'never.s')],
  { encoding: 'utf8', timeout: 30000, env: { ...process.env, FPR_HOME: root, FPR_EDITOR_RESOURCE_BUDGET_MS: budget } });
  assert(!p.error, p.error);
  const r = readReport(p.stdout + '\n' + p.stderr, { readText, readOpen: () => null, failed: p.status !== 0 }).report;
  return { p, r };
}
try {
  const { p, r } = check('tests/cases/cost_ho.fpr', ['--cost']);
  assert.equal(p.status, 0, p.stdout + p.stderr);
  assert.equal(r.resourceStatus, 'complete');
  const summary = name => r.resources.find(x => x.name === name && x.file.endsWith('cost_ho.fpr')).summary;
  assert.equal(summary('twice').inferred.work.display, '2·work f + 2');
  assert.equal(summary('twice').inferred.allocation.display, '2·alloc f');
  assert.equal(summary('useIt').inferred.work.display, '11');
  assert.equal(summary('mk').inferred.allocation.display, '24');
  assert.equal(summary('main').inferred.work.status, 'unknown');
  assert(summary('main').inferred.work.unknowns.includes('print'));
  for (const name of ['twice', 'useIt', 'mk']) {
    assert(p.stdout.includes('work  <= ' + summary(name).inferred.work.display), 'CLI/editor equations agree');
  }
  assert.equal(summary('twice').inferred.work.expression.op, 'add');
  const measured = check('tests/measure.fpr').r.resources.find(x => x.name === 'lsum').summary;
  assert.equal(measured.inferred.work.display, '6·(len l + 1)');
  const declared = check('tests/cases/bound_ok.fpr').r.resources.find(x => x.name === 'count').summary;
  assert(declared.declared.work && declared.declared.allocation);
  assert.deepEqual(declared.domains, [], 'termination measure is not an input precondition');
  const limited = check('tests/cases/cost_ho.fpr', [], '0');
  assert.equal(limited.p.status, 0); assert.equal(limited.r.resourceStatus, 'budget-limited');
  assert(limited.r.types.length); assert.deepEqual(limited.r.resources, []);
  for (const name of ['bound_over', 'bound_unproved', 'bound_unused_over', 'bound_signed_unsafe']) {
    const bad = check('tests/cases/' + name + '.fpr', [], '0');
    assert.notEqual(bad.p.status, 0, 'optional budget cannot suppress mandatory contract checks: ' + name);
    assert.deepEqual(bad.r.resources, []); assert.deepEqual(bad.r.types, []);
  }
  const domain = path.join(dir, 'domain.fpr');
  fs.writeFileSync(domain, 'identity : (n : Int | n >= 0) -> Int.\nidentity n = n.\n');
  assert(check(domain).r.resources.find(x => x.name === 'identity').summary.domains.some(x => x.includes('>= 0')));
  const legacy = { ...r, editorVersion: 1 };
  const parse = report => readReport(JSON.stringify(report), { readText, readOpen: () => null, failed: false });
  assert.deepEqual(parse(legacy).report.resources, []); assert(parse(legacy).report.types.length);
  assert.deepEqual(parse({ ...r, resourceVersion: 99 }).report.resources, []);
  const malformed = JSON.parse(JSON.stringify(r)); malformed.resources[0].summary.inferred.work.unit = 'cycles';
  assert.throws(() => parse(malformed), /resource summary/);
  assert(!fs.existsSync(path.join(dir, 'never.s')));
  console.log('resource editor: CLI parity, callback/size equations, declared bounds, unknowns, budget isolation, domains and schema compatibility PASS');
} finally { fs.rmSync(dir, { recursive: true, force: true }); }
