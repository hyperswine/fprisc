#!/usr/bin/env node
// Explicit themes and the actual inventory autocomplete. The sample server
// never runs account/persistence updates. NODE_PATH/CHROME_BIN select Playwright.
const {chromium}=require('playwright');
const assert=require('node:assert/strict');
const fs=require('node:fs'), os=require('node:os'), path=require('node:path');
const {execFileSync,spawnSync,spawn}=require('node:child_process');
const root=path.resolve(__dirname,'..');
const tmp=fs.mkdtempSync(path.join(os.tmpdir(),'fpr-theme-autocomplete-'));
const env={...process.env,FPR_HOME:root,XDG_CACHE_HOME: process.env.XDG_CACHE_HOME || path.join(tmp,'cache')};
const build=(source,out)=>execFileSync(path.join(root,'fpr'),['build',source,'-o',out],
  {cwd:root,env,timeout:180000,stdio:'pipe'});
async function mount(page,snapshot) {
  const markup=snapshot.s.map((s,i)=>s+(i<snapshot.d.length?'<span data-slot="'+i+'"></span>':'')).join('');
  await page.setContent('<!doctype html><head><style>'+snapshot.css+'</style></head><body'+(snapshot.body||'')+'>'+markup+'</body>');
  await page.locator('[data-slot]').evaluateAll((els,ds)=>{
    for(const el of els)el.textContent=ds[Number(el.dataset.slot)];
  },snapshot.d);
}
async function start(binary,harts) {
  const directory=path.join(tmp,'server-'+harts);fs.mkdirSync(directory);
  const child=spawn(binary,['serve'],{cwd:directory,env:{...env,FPR_HARTS:harts},stdio:['ignore','pipe','pipe']});
  let logs='';child.stderr.on('data',data=>{logs=(logs+data).slice(-8000);});
  try {
    const port=await new Promise((resolve,reject)=>{
      let out='';const timer=setTimeout(()=>reject(new Error('startup timeout: '+logs)),20000);
      child.stdout.on('data',data=>{out+=data;const match=out.match(/ready (\d+)/);
        if(match){clearTimeout(timer);resolve(Number(match[1]));}});
      child.once('error',e=>{clearTimeout(timer);reject(e);});
      child.once('exit',code=>{clearTimeout(timer);reject(new Error('server exited '+code+': '+logs));});
    });
    return {child,url:'http://127.0.0.1:'+port};
  } catch(e) {await stop(child);throw e;}
}
async function stop(child) {
  if(child.exitCode===null&&child.signalCode===null) {
    const exited=new Promise(resolve=>child.once('exit',resolve));child.kill('SIGTERM');await exited;
  }
}
(async()=>{
  let browser;
  try {
    const themeBinary=path.join(tmp,'themes');build('tests/themes.fpr',themeBinary);
    for(const [arg,why] of [['bad-token','View.NamedToken'],['bad-gradient','at least two stops'],['bad-alpha','alpha 0..100']]) {
      const p=spawnSync(themeBinary,[arg],{encoding:'utf8',timeout:10000});
      assert.equal(p.status,1,arg);assert.match(p.stdout+p.stderr,new RegExp(why),arg);
    }
    const snapshot=JSON.parse(execFileSync(themeBinary,{encoding:'utf8'}));
    assert.doesNotMatch(snapshot.css,/:root\s*\{|\.day\s*\{|\.night\s*\{|body:has\(\.day\)/);
    browser=await chromium.launch({headless:true,...(process.env.CHROME_BIN?{executablePath:process.env.CHROME_BIN}:{})});
    const page=await browser.newPage();await mount(page,snapshot);
    const colours=selector=>page.locator(selector).evaluate(el=>{
      const s=getComputedStyle(el);return [s.backgroundColor,s.color];
    });
    assert.deepEqual(await colours('#scope-day'),['rgb(243, 245, 249)','rgb(13, 21, 38)']);
    assert.deepEqual(await colours('#scope-night'),['rgb(6, 10, 18)','rgb(233, 239, 247)']);
    assert.deepEqual(await colours('#ui-day'),['rgb(247, 248, 250)','rgb(26, 29, 35)']);
    assert.deepEqual(await colours('#ui-night'),['rgb(21, 23, 28)','rgb(237, 239, 243)']);
    assert.deepEqual(await colours('#ui-day > div'),['rgb(255, 255, 255)','rgb(26, 29, 35)']);
    assert.deepEqual(await colours('#ui-night > div'),['rgb(29, 32, 39)','rgb(237, 239, 243)']);
    assert.match(await page.locator('#scope-day [data-panel]').evaluate(el=>getComputedStyle(el).backgroundImage),/linear-gradient.*rgb\(255, 255, 255\).*rgb\(238, 242, 248\)/);
    assert.equal((await page.locator('#scope-night').evaluate(el=>getComputedStyle(el).backgroundImage)).match(/radial-gradient/g).length,2);
    assert.match(await page.locator('#ui-day > div').evaluate(el=>getComputedStyle(el).boxShadow),/rgba\(30, 41, 59, 0\.06\).*rgba\(30, 41, 59, 0\.04\)/);
    assert.deepEqual(await page.evaluate(()=>{const s=getComputedStyle(document.body);
      return [s.getPropertyValue('--bg'),s.getPropertyValue('--bg-canvas'),s.backgroundColor];}),['','','rgba(0, 0, 0, 0)']);
    await page.locator('#scope-night').evaluate(el=>el.classList.add('day'));
    assert.deepEqual(await colours('#scope-night'),['rgb(6, 10, 18)','rgb(233, 239, 247)']);
    await page.close();
    console.log('PASS: View/UI theme scopes coexist, gradients/shadows are generated, body has no palette, legacy theme classes have no effect; invalid token/gradient/alpha refused');

    const printerSource=fs.readFileSync(path.join(root,'examples/printers.fpr'),'utf8');
    assert.equal((printerSource.match(/^main =/gm)||[]).length,1);
    const printerSample=path.join(tmp,'printer-sample.fpr'),printerBinary=path.join(tmp,'printer');
    fs.writeFileSync(printerSample,printerSource.replace(/^main =/m,'applicationMain =')+'\n'+
      fs.readFileSync(path.join(root,'tests/printerstyles.fprinc'),'utf8'));
    build(printerSample,printerBinary);
    const printerSnapshot=JSON.parse(execFileSync(printerBinary,{encoding:'utf8'}));
    assert.doesNotMatch(printerSnapshot.css,/:root\s*\{/);
    const printerPage=await browser.newPage();
    for(const [width,height] of [[1200,800],[390,844]]) {
      await printerPage.setViewportSize({width,height});await mount(printerPage,printerSnapshot);
      assert.deepEqual(await printerPage.locator('main').evaluate(el=>{
        const s=getComputedStyle(el.parentElement);return [s.backgroundColor,s.color,s.colorScheme];
      }),['rgb(246, 245, 240)','rgb(38, 51, 46)','light']);
      assert.equal(await printerPage.locator('article').evaluate(el=>getComputedStyle(el).backgroundColor),'rgb(255, 254, 250)');
      assert.equal(await printerPage.evaluate(()=>getComputedStyle(document.body).getPropertyValue('--bg')),'');
      assert.equal(await printerPage.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
    }
    await printerPage.close();
    console.log('PASS: printer dashboard palette belongs to its frame, native colour scheme stays light, desktop/phone layouts stay within viewport');

    const source=fs.readFileSync(path.join(root,'examples/inventory.fpr'),'utf8');
    assert.doesNotMatch(source,/autocompleteStyles|G\.Style|G\.Prop/);
    const autocomplete=fs.readFileSync(path.join(root,'std/browserautocomplete.fpr'),'utf8');
    assert.doesNotMatch(autocomplete,/cssText|className|setProperty|getComputedStyle|chip text/);
    assert.equal((source.match(/^main =/gm)||[]).length,1);
    const sampleSource=path.join(tmp,'inventory-sample.fpr'), inventory=path.join(tmp,'inventory');
    fs.writeFileSync(sampleSource,source.replace(/^main =/m,'applicationMain =')+'\n'+fs.readFileSync(path.join(root,'tests/inventorystyles.fprinc'),'utf8'));
    build(sampleSource,inventory);
    for(const harts of ['1','4']) {
      const {child,url}=await start(inventory,harts);let a,b,mobile;
      try {
        a=await browser.newPage({viewport:{width:1200,height:800}});b=await browser.newPage();
        const errors=[];a.on('pageerror',e=>errors.push(e.message));b.on('pageerror',e=>errors.push(e.message));
        for(const p of [a,b])await p.addInitScript(()=>{window.originalSocketSend=WebSocket.prototype.send;});
        await a.goto(url);await b.goto(url);
        const loc=a.locator('[data-ac="loc"]'),sub=a.locator('[data-ac="sub"]'),tags=a.locator('[data-ac="tags"]');
        const popup=a.locator('body > [data-ac-popup]');
        const options=()=>popup.getByRole('option');
        await loc.fill('st');await options().first().waitFor();
        assert.deepEqual(await options().allTextContents(),['study','Storage room']);
        assert.equal(await options().first().evaluate(el=>getComputedStyle(el).minHeight),'34px');
        await loc.press('ArrowDown');assert.equal(await options().nth(1).getAttribute('aria-selected'),'true');
        await loc.press('Tab');assert.equal(await loc.inputValue(),'Storage room');await popup.waitFor({state:'hidden'});
        await loc.fill('off');await options().first().waitFor();await loc.press('Tab');assert.equal(await loc.inputValue(),'Office');
        await loc.fill('study');await sub.fill('to');await options().first().waitFor();
        assert.equal(await options().first().textContent(),'top drawer');
        await sub.press('ArrowDown');await sub.press('Enter');assert.equal(await sub.inputValue(),'top drawer');
        await tags.fill('cables, el');await options().first().waitFor();assert.deepEqual(await options().allTextContents(),['electronics']);
        await tags.press('Tab');assert.equal(await tags.inputValue(),'cables, electronics, ');
        await tags.fill('<');await options().first().waitFor();assert.equal(await popup.locator('img').count(),0);
        assert.equal(await options().first().textContent(),'<img src=x onerror=alert(1)>');
        await tags.press('Escape');await popup.waitFor({state:'hidden'});
        await loc.fill('wo');await options().first().waitFor();await options().first().click();assert.equal(await loc.inputValue(),'Workshop');
        await loc.fill('st');await options().first().waitFor();
        await loc.evaluate(el=>{window.savedLoc=el;el.setSelectionRange(0,2);});
        assert.equal(await popup.evaluate(el=>getComputedStyle(el).backgroundColor),'rgb(255, 255, 255)');
        await b.getByRole('button',{name:'household',exact:true}).click();
        await b.getByRole('button',{name:'day / night',exact:true}).click();
        await b.getByRole('button',{name:'admin',exact:true}).click();
        await b.waitForFunction(()=>/over [1-9][0-9]*$/.test(document.getElementById('inv-rtt')?.textContent||''));
        assert.equal(await b.evaluate(()=>WebSocket.prototype.send===originalSocketSend),true);
        await a.waitForFunction(()=>document.querySelector('[data-theme]')?.dataset.theme==='night');
        await a.waitForFunction(()=>getComputedStyle(document.querySelector('body > [data-ac-popup]')).backgroundColor==='rgb(10, 17, 32)');
        assert.deepEqual(await loc.evaluate(el=>[el===savedLoc,document.activeElement===el,el.value,el.selectionStart,el.selectionEnd]),[true,true,'st',0,2]);
        assert.deepEqual(await options().first().evaluate(el=>{const s=getComputedStyle(el);return [s.backgroundColor,s.color];}),['rgb(233, 239, 247)','rgb(6, 10, 18)']);
        assert.equal(await a.evaluate(()=>getComputedStyle(document.body).getPropertyValue('--bg')),'');
        await loc.press('Escape');await popup.waitFor({state:'hidden'});
        mobile=await browser.newPage({viewport:{width:390,height:844},hasTouch:true,isMobile:true});
        mobile.on('pageerror',e=>errors.push(e.message));await mobile.goto(url);
        const touchLoc=mobile.locator('[data-ac="loc"]');await touchLoc.tap();
        await mobile.locator('body > [data-ac-popup]').waitFor({state:'visible'});await touchLoc.tap();
        assert.equal(await touchLoc.inputValue(),'study');
        assert.equal(await mobile.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
        assert.deepEqual(errors,[]);
        console.log('PASS: inventory autocomplete on '+harts+' hart(s): ranking, keyboard, contextual spots, comma tags, safe text, pointer/touch selection, explicit popup theme updates and focused draft preservation');
      } finally {
        if(a)await a.close();if(b)await b.close();if(mobile)await mobile.close();await stop(child);
      }
    }
  } finally {if(browser)await browser.close();fs.rmSync(tmp,{recursive:true,force:true});}
})().catch(e=>{console.error(e);process.exitCode=1;});
