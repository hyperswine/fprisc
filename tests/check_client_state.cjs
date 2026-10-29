#!/usr/bin/env node
// Typed client state (std/view, std/livejs, std/live) in a real browser, on one
// and four harts: an enumeration, a whole-number input that refuses other text,
// a toggle, a password mirrored only as it was declared, a family of quantities
// stepped within bounds, a two-field send and the server's own assignment into a
// focused input.  tests/clientlive.fpr shows what the server decoded.
// NODE_PATH may point to Playwright; CHROME_BIN may select an installed Chromium.
const {chromium} = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {execFileSync, spawn} = require('node:child_process');
const root = path.resolve(__dirname, '..');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'fpr-client-state-'));
const binary = path.join(tmp, 'clientlive');
const env = {...process.env, FPR_HOME: root, XDG_CACHE_HOME: process.env.XDG_CACHE_HOME || path.join(tmp, 'cache')};
const shown = el => getComputedStyle(el).display !== 'none';
(async () => {
  let browser;
  try {
    execFileSync(path.join(root, 'fpr'), ['build', 'tests/clientlive.fpr', '-o', binary], {cwd: root, env, timeout: 180000, stdio: 'pipe'});
    browser = await chromium.launch({headless: true, ...(process.env.CHROME_BIN ? {executablePath: process.env.CHROME_BIN} : {})});
    for (const harts of ['1', '4']) {
      const directory = path.join(tmp, 'live-' + harts); fs.mkdirSync(directory);
      const server = spawn(binary, [], {cwd: directory, env: {...env, FPR_HARTS: harts}, stdio: ['ignore', 'pipe', 'pipe']});
      let logs = '', page;
      server.stderr.on('data', data => { logs = (logs + data).slice(-8000); });
      try {
        const port = await new Promise((resolve, reject) => {
          const timer = setTimeout(() => reject(new Error('startup timeout: ' + logs)), 20000);
          let output = '';
          server.stdout.on('data', data => { output += data; const m = output.match(/ready (\d+)/); if (m) { clearTimeout(timer); resolve(Number(m[1])); } });
          server.once('exit', code => { clearTimeout(timer); reject(new Error('server exited ' + code + ': ' + logs)); });
        });
        page = await browser.newPage();
        const errors = []; page.on('pageerror', e => errors.push(e.message));
        const seen = want => page.waitForFunction(w => document.getElementById('seen').textContent.includes(w), want);
        await page.goto('http://127.0.0.1:' + port);
        // the first mirror: every field in its own type, the family as its pairs
        await seen('cart = [(A, 0), (B, 1)]');
        for (const field of ['n = 0', 'on = False', 'tab = Front', 'pin = ,']) await seen(field);
        // an enumeration set and shown in the page alone
        assert.deepEqual([await page.locator('#front').evaluate(shown), await page.locator('#back').evaluate(shown)], [true, false]);
        await page.locator('#to-back').click();
        assert.deepEqual([await page.locator('#front').evaluate(shown), await page.locator('#back').evaluate(shown)], [false, true]);
        await seen('tab = Back');
        // a whole number: text that is not one is marked and not taken
        await page.locator('#n').fill('12'); await seen('n = 12');
        assert.equal(await page.locator('#n').getAttribute('aria-invalid'), null);
        await page.locator('#n').fill('1x');
        assert.equal(await page.locator('#n').getAttribute('aria-invalid'), 'true');
        await page.locator('#n').fill('-007'); await seen('n = -7');
        assert.equal(await page.locator('#n').getAttribute('aria-invalid'), null);
        await page.locator('#n').fill('12'); await seen('n = 12');
        // a Bool turned over
        assert.equal(await page.locator('#lit').evaluate(shown), false);
        await page.locator('#flip').click();
        assert.equal(await page.locator('#lit').evaluate(shown), true);
        await seen('on = True');
        // a password field is mirrored as it was declared, never as typed
        await page.locator('#pin').fill('secret 1234');
        await page.locator('#flip').click(); await seen('on = False');
        assert.equal((await page.locator('#seen').textContent()).includes('secret'), false);
        // a family entry stepped within its bounds, shown while it is not 0
        assert.equal(await page.locator('#a-line').evaluate(shown), false);
        for (let i = 0; i < 3; i++) await page.locator('#a-plus').click();
        assert.deepEqual([await page.locator('#a-line').evaluate(shown), await page.locator('#a-line').textContent()], [true, '2']);
        await seen('cart = [(A, 2), (B, 1)]');
        // two fields from the page, typed, in order
        await page.locator('#note').fill('hello | world');
        await page.locator('#send').click();
        await page.waitForFunction(() => document.getElementById('got').textContent === '12 hello | world');
        // the server's assignment reaches the input that has the focus
        await page.locator('#note').fill('typed here');
        await page.locator('#note').press('Enter');
        await page.waitForFunction(() => document.getElementById('got').textContent === 'note typed here');
        await page.waitForFunction(() => document.getElementById('note').value === '');
        assert.equal(await page.evaluate(() => document.activeElement === document.getElementById('note')), true);
        assert.deepEqual([await page.locator('#b-line').evaluate(shown), await page.locator('#b-line').textContent()], [true, '3']);
        await seen('cart = [(A, 2), (B, 3)]'); await seen('note = ,');
        assert.equal(await page.locator('#refused').textContent(), '');
        assert.deepEqual(errors, []);
        console.log('PASS: typed client state on ' + harts + ' hart(s): enumeration, whole-number input refusing other text, toggle, password mirrored as declared, bounded family steps, two-field send, server assignment into a focused input');
      } finally {
        if (page) await page.close();
        if (server.exitCode === null && server.signalCode === null) {
          const exited = new Promise(resolve => server.once('exit', resolve)); server.kill('SIGTERM'); await exited;
        }
      }
    }
  } finally {
    if (browser) await browser.close();
    fs.rmSync(tmp, {recursive: true, force: true});
  }
})().catch(error => { console.error(error); process.exit(1); });
