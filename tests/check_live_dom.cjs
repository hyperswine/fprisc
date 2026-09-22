#!/usr/bin/env node
// Starts its own isolated logbook instance and temporary store.
// NODE_PATH may point at a Playwright installation.
const {chromium} = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawn} = require('node:child_process');
(async () => {
  const binary = process.argv[2];
  if (!binary) throw new Error('usage: node tests/check_live_dom.cjs /path/to/built-logbook');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fpr-live-dom-'));
  const server = spawn(path.resolve(binary), ['--port=0', '--store='+path.join(dir,'store.kvlog')], {stdio:['ignore','pipe','pipe']});
  let logs = '', browser;
  server.stderr.on('data', b => {logs = (logs + b).slice(-8000);});
  try {
    const port = await new Promise((resolve,reject) => {
      const timer = setTimeout(()=>reject(new Error('server startup timeout: '+logs)),20000);
      let out='';
      server.stdout.on('data', b => {
        out=(out+b).slice(-8000);
        const match=out.match(/ready (\d+)/);
        if(match) {clearTimeout(timer);resolve(Number(match[1]));}
      });
      server.once('error', e=>{clearTimeout(timer);reject(e);});
      server.once('exit', code=>{clearTimeout(timer);reject(new Error('server exited '+code+': '+logs));});
    });
    const url='http://127.0.0.1:'+port;
    browser = await chromium.launch({headless: true, ...(process.env.CHROME_BIN ? {executablePath:process.env.CHROME_BIN} : {})});
    const page = await browser.newPage();
    const errors = [];
    page.on('pageerror', e => errors.push(e.message));
    await page.goto(url);
    await page.waitForFunction(() => document.querySelector('[data-input="draft"]'));
    const draft = page.locator('[data-input="draft"]');
    await draft.fill('first entry');
    await page.getByRole('button', {name:'add entry', exact:true}).click();
    await page.locator('[data-lv-key="entry-1"]').waitFor();
    await page.evaluate(() => { window.firstCard = document.querySelector('[data-lv-key="entry-1"]'); window.draftNode = document.querySelector('[data-input="draft"]'); });
    const other = await browser.newPage();
    await other.goto(url);
    await other.locator('[data-input="draft"]').fill('second entry');
    await draft.fill('unfinished local draft');
    await draft.evaluate(el => {el.focus(); el.setSelectionRange(4, 9);});
    await other.getByRole('button', {name:'add entry', exact:true}).click();
    await page.locator('[data-lv-key="entry-2"]').waitFor();
    assert.deepEqual(await draft.evaluate(el => [el===window.draftNode, document.activeElement===el, el.value, el.selectionStart,el.selectionEnd]), [true,true,'unfinished local draft',4,9]);
    assert(await page.evaluate(() => firstCard===document.querySelector('[data-lv-key="entry-1"]')));
    assert.deepEqual(await page.locator('[data-lv-key="entries"] > [data-lv-key]').evaluateAll(es=>es.map(e=>e.dataset.lvKey)), ['entry-2','entry-1']);
    // Edit a card, then change another card from the second session. The local
    // edit textarea, selection, and draft must survive the incoming snapshot.
    await page.locator('[data-lv-key="entry-1"]').getByRole('button',{name:'edit',exact:true}).click();
    const edit = page.locator('[data-input="edit"]');
    await edit.fill('local edit draft');
    await edit.evaluate(el=>{window.editNode=el;el.focus();el.setSelectionRange(2,5);});
    await other.locator('[data-lv-key="entry-2"]').getByRole('button',{name:'edit',exact:true}).click();
    await other.getByRole('button',{name:'delete',exact:true}).click();
    await page.locator('[data-lv-key="entry-2"]').waitFor({state:'detached'});
    assert.deepEqual(await edit.evaluate(el=>[el===window.editNode,document.activeElement===el,el.value,el.selectionStart,el.selectionEnd]),[true,true,'local edit draft',2,5]);
    await page.getByRole('button',{name:'save',exact:true}).click();
    await page.getByText('local edit draft',{exact:true}).waitFor();
    await other.getByText('local edit draft',{exact:true}).waitFor();
    assert(await page.evaluate(() => firstCard===document.querySelector('[data-lv-key="entry-1"]')));
    // Text deltas after structural slot renumbering must reach the right card.
    await page.locator('[data-lv-key="entry-1"]').getByRole('button',{name:'edit',exact:true}).click();
    await page.locator('[data-input="edit"]').fill('<script>not markup</script>');
    await page.getByRole('button',{name:'save',exact:true}).click();
    await other.getByText('<script>not markup</script>',{exact:true}).waitFor();
    assert.equal(await other.locator('#lv-root script').count(),0);
    assert.deepEqual(errors,[]);
    console.log('Keyed cards, insertion/deletion, identity, drafts, focus/selection, updated handlers and text deltas: PASS');
  } finally {
    if(browser) await browser.close();
    if(server.exitCode === null && server.signalCode === null) {
      const exited = new Promise(resolve=>server.once('exit',resolve));
      server.kill('SIGTERM');
      await exited;
    }
    fs.rmSync(dir,{recursive:true,force:true});
  }
})().catch(e=>{console.error(e);process.exitCode=1;});
