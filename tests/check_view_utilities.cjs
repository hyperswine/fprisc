#!/usr/bin/env node
// Generated CSS in a real browser. NODE_PATH may point to Playwright;
// CHROME_BIN may select an installed Chromium. Live checks use disposable
// loopback servers and stores, on one and four harts.
const {chromium} = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {execFileSync, spawnSync, spawn} = require('node:child_process');
const root = path.resolve(__dirname, '..');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'fpr-utilities-'));
const binary = path.join(tmp, 'utilities');
const liveBinary = path.join(tmp, 'liveutilities');
const inventoryBinary = path.join(tmp, 'inventorystyles');
const env = {...process.env, FPR_HOME: root, XDG_CACHE_HOME: path.join(tmp, 'cache')};
(async () => {
  let browser;
  try {
    execFileSync(path.join(root, 'fpr'), ['build', 'tests/std/viewutilities.fpr', '-o', binary],
      {cwd: root, env, timeout: 180000, stdio: 'pipe'});
    assert.match(execFileSync(binary, {encoding:'utf8'}), /cached CSS PASS/);
    for (const [arg, why] of [['bad-prop', 'Prop is a legacy escape hatch'],
      ['bad-rgb', 'expected channels 0..255'], ['bad-opacity', 'expected 0..100'],
      ['bad-rgba', 'expected channels 0..255'], ['bad-weight', 'expected 1..1000']]) {
      const p = spawnSync(binary, [arg], {encoding:'utf8', timeout:10000});
      assert.equal(p.status, 1, arg);
      assert.match(p.stdout+p.stderr, new RegExp(why), arg);
    }
    const html = execFileSync(binary, ['page'], {encoding:'utf8'});
    browser = await chromium.launch({headless:true,
      ...(process.env.CHROME_BIN ? {executablePath:process.env.CHROME_BIN} : {})});
    const page = await browser.newPage({viewport:{width:1200,height:800}});
    await page.setContent(html);
    const primary = page.locator('#primary');
    const sibling = page.locator('#sibling');
    const style = el => el.evaluate(node => {
      const s = getComputedStyle(node);
      return [s.width, s.paddingLeft, s.paddingRight, s.display, s.color];
    });
    assert.deepEqual(await style(primary), ['240px','3px','8px','block','rgb(1, 2, 3)']);
    assert.deepEqual(await page.locator('#layout').evaluate(el => {
      const s=getComputedStyle(el);
      return [s.alignItems,s.justifyContent,s.flexWrap,s.marginLeft,s.marginRight,
        s.overflowX,s.overflowY,s.whiteSpace,s.position,s.left,s.zIndex,
        s.transform,s.fontWeight,s.fontSize,s.lineHeight,s.overflowWrap,s.boxShadow];
    }), ['center','space-between','wrap','9px','4px','hidden','auto','pre',
      'relative','10px','2','matrix(1, 0, 0, 1, 3, 4)','600','14px','21px','anywhere',
      'rgba(0, 0, 0, 0.267) 0px 6px 24px 0px']);
    for (const [id,colour] of [['inherited','rgb(40, 50, 60)'],['scoped','rgb(200, 100, 50)']]) {
      assert.deepEqual(await page.locator('#'+id).evaluate(el=>{
        const s=getComputedStyle(el);return [s.color,s.backgroundColor];
      }), [colour,'rgb(10, 20, 30)']);
    }
    assert.equal((await style(sibling))[0], '180px');
    await page.setViewportSize({width:390,height:844});
    assert.equal((await style(primary))[0], '100px');
    assert.equal((await style(sibling))[0], '180px');
    await page.setViewportSize({width:1200,height:800});
    await primary.hover();
    assert.equal((await style(primary))[4], 'rgb(200, 0, 0)');
    await page.keyboard.press('Tab');
    assert.equal(await primary.evaluate(el => el.matches(':focus-visible')), true);
    assert.equal((await style(primary))[4], 'rgb(0, 0, 200)');
    await primary.evaluate(el => {el.disabled=true;});
    assert.equal((await style(primary))[4], 'rgb(0, 100, 0)');
    // Reverse DOM and rule order within each precedence tier.
    // Competing declarations were removed locally before either was emitted.
    await page.evaluate(() => {
      const a=document.querySelector('#primary'), b=document.querySelector('#sibling');
      a.disabled=false; a.blur(); a.parentNode.insertBefore(b,a);
      const sheet=document.styleSheets[0];
      const all=Array.from(sheet.cssRules, r=>r.cssText);
      const rules=all.filter(r=>!r.includes('fpr-u-'));
      for(let scope=0;scope<6;scope++) {
        rules.push(...all.filter(r=>r.includes('fpr-u-'+scope+'-')).reverse());
      }
      while (sheet.cssRules.length) sheet.deleteRule(0);
      for (const rule of rules) sheet.insertRule(rule,sheet.cssRules.length);
    });
    await page.mouse.move(1100,700);
    assert.deepEqual((await style(primary)).slice(0,4), ['240px','3px','8px','block']);
    assert.equal((await style(sibling))[0], '180px');
    assert.equal((await style(sibling))[4], 'rgb(1, 2, 3)');
    console.log('PASS: generated local CSS in Chromium: overrides, padding, viewport, hover, keyboard focus, disabled, sibling isolation, rule order; invalid values refused');
    const inventorySource=fs.readFileSync(path.join(root,'examples/inventory.fpr'),'utf8');
    assert.equal((inventorySource.match(/^main =/gm)||[]).length,1);
    const sampleSource=path.join(tmp,'inventory-sample.fpr');
    fs.writeFileSync(sampleSource,inventorySource.replace(/^main =/m,'applicationMain =')+'\n'+
      fs.readFileSync(path.join(root,'tests/inventorystyles.fprinc'),'utf8'));
    execFileSync(path.join(root,'fpr'), ['build',sampleSource,'-o',inventoryBinary],
      {cwd:root,env,timeout:180000,stdio:'pipe'});
    const snapshot=JSON.parse(execFileSync(inventoryBinary,{encoding:'utf8'}));
    const markup=snapshot.s.map((s,i)=>s+(i<snapshot.d.length?'<span data-slot="'+i+'"></span>':'')).join('');
    const inventoryPage=await browser.newPage();
    for(const [width,height] of [[1200,800],[390,844]]) {
      await inventoryPage.setViewportSize({width,height});
      await inventoryPage.setContent('<!doctype html><style>'+snapshot.css+'</style>'+markup);
      await inventoryPage.locator('[data-slot]').evaluateAll((els,ds)=>{
        for(const el of els)el.textContent=ds[Number(el.dataset.slot)];
      },snapshot.d);
      assert.deepEqual(await inventoryPage.locator('[x-data]').evaluate(el=>{
        const s=getComputedStyle(el);return [s.width,s.paddingTop,s.paddingBottom];
      }),[Math.min(width,760)+'px','14px','48px']);
      for(const selector of ['[data-console]','[data-ac="loc"]']) {
        assert.deepEqual(await inventoryPage.locator(selector).evaluate(el=>{
          const s=getComputedStyle(el);return [s.fontSize,s.minHeight];
        }),['16px','44px']);
      }
      assert.deepEqual(await inventoryPage.locator('.console').evaluate(el=>{
        const s=getComputedStyle(el);return [s.minHeight,s.maxHeight,s.overflowX,s.overflowY];
      }),['120px',height/2+'px','auto','auto']);
      assert.deepEqual(await inventoryPage.locator('[data-pager]').first().evaluate(el=>{
        const s=getComputedStyle(el);return [s.opacity,s.pointerEvents,s.minHeight];
      }),['0.35','none','44px']);
      assert.deepEqual(await inventoryPage.locator('[data-on="pane:items"]').evaluate(el=>{
        const s=getComputedStyle(el.parentElement.firstElementChild);return [s.flexBasis];
      }),[width<761?'100%':'0%']);
      assert.deepEqual(await inventoryPage.locator('.fpr-reload-notice').evaluate(el=>{
        const s=getComputedStyle(el);return [s.position,s.bottom,s.zIndex,s.backgroundColor,s.color,
          s.fontSize,s.lineHeight,s.paddingTop,s.paddingLeft,s.pointerEvents];
      }),['fixed','20px','10000','rgb(23, 33, 50)','rgb(255, 255, 255)','13px','19.5px','12px','18px','none']);
      assert.equal(await inventoryPage.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
    }
    await inventoryPage.close();
    console.log('PASS: actual inventory sample and reload notice: typed dimensions, input sizes, overflow, pager, responsive header, desktop/phone bounds');
    execFileSync(path.join(root,'fpr'), ['build','tests/liveutilities.fpr','-o',liveBinary],
      {cwd:root,env,timeout:180000,stdio:'pipe'});
    for (const harts of ['1','4']) {
      const directory=path.join(tmp,'live-'+harts);fs.mkdirSync(directory);
      const server=spawn(liveBinary,[],{cwd:directory,env:{...env,FPR_HARTS:harts},stdio:['ignore','pipe','pipe']});
      let logs='', a, b;
      server.stderr.on('data',data=>{logs=(logs+data).slice(-8000);});
      try {
        const port=await new Promise((resolve,reject)=>{
          const timer=setTimeout(()=>reject(new Error('startup timeout: '+logs)),20000);
          let output='';
          server.stdout.on('data',data=>{
            output+=data;const match=output.match(/ready (\d+)/);
            if(match){clearTimeout(timer);resolve(Number(match[1]));}
          });
          server.once('error',error=>{clearTimeout(timer);reject(error);});
          server.once('exit',code=>{clearTimeout(timer);reject(new Error('server exited '+code+': '+logs));});
        });
        a=await browser.newPage();b=await browser.newPage();
        const errors=[];a.on('pageerror',e=>errors.push(e.message));b.on('pageerror',e=>errors.push(e.message));
        await a.goto('http://127.0.0.1:'+port);await b.goto('http://127.0.0.1:'+port);
        await a.locator('#draft').waitFor();await b.locator('#draft').waitFor();
        assert.equal(await a.locator('[data-lv-local-css]').textContent(),'');
        await a.locator('#draft').fill('unfinished draft');
        await a.locator('#draft').evaluate(el=>{
          window.draftNode=el;window.sheetNode=document.querySelector('[data-lv-local-css]');
          el.focus();el.setSelectionRange(2,6);
        });
        await b.getByRole('button',{name:'bump',exact:true}).click();
        await a.waitForFunction(()=>getComputedStyle(document.querySelector('#probe')).width==='201px');
        assert.deepEqual(await a.locator('#draft').evaluate(el=>[el===draftNode,document.activeElement===el,
          el.value,el.selectionStart,el.selectionEnd]),[true,true,'unfinished draft',2,6]);
        assert.equal(await a.evaluate(()=>sheetNode===document.querySelector('[data-lv-local-css]')),true);
        assert.equal(await a.locator('[data-lv-local-css]').count(),1);
        await a.locator('#probe').hover();
        assert.equal(await a.locator('#probe').evaluate(el=>getComputedStyle(el).backgroundColor),'rgb(100, 80, 60)');
        await b.getByRole('button',{name:'reset',exact:true}).click();
        await a.waitForFunction(()=>document.querySelector('[data-lv-local-css]').textContent==='');
        assert.equal(await a.locator('#draft').inputValue(),'unfinished draft');
        assert.equal(await a.evaluate(()=>sheetNode===document.querySelector('[data-lv-local-css]')),true);
        await b.getByRole('button',{name:'bump',exact:true}).click();
        await b.getByRole('button',{name:'bump',exact:true}).click();
        await a.waitForFunction(()=>getComputedStyle(document.querySelector('#probe')).width==='202px');
        assert.equal(await a.locator('[data-lv-local-css]').count(),1);
        assert.deepEqual(errors,[]);
        console.log('PASS: Live local CSS on '+harts+' hart(s): new cached styles, hover, removal/reappearance, two tabs, stable style node and preserved focused draft');
      } finally {
        if(a)await a.close();if(b)await b.close();
        if(server.exitCode===null&&server.signalCode===null){
          const exited=new Promise(resolve=>server.once('exit',resolve));server.kill('SIGTERM');await exited;
        }
      }
    }
  } finally {
    if (browser) await browser.close();
    fs.rmSync(tmp, {recursive:true,force:true});
  }
})().catch(e => {console.error(e);process.exitCode=1;});
