#!/usr/bin/env node
// Generated pending feedback: lifecycle and initial Live data escaping.
const {chromium}=require('playwright');
const assert=require('node:assert/strict');
const {execFileSync}=require('node:child_process');
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.CHROME_BIN?{executablePath:process.env.CHROME_BIN}:{})});
 try {
  for(const harts of [1,4]) {
   const data=JSON.parse(execFileSync(process.argv[2],{encoding:'utf8',env:{...process.env,FPR_HARTS:String(harts)}}));
   const page=await browser.newPage();
   const errors=[];page.on('pageerror',e=>errors.push(e.message));
   await page.setContent(data.page);
   assert.equal(await page.title(),data.payload);
   assert.equal(await page.evaluate(()=>!!window.injected),false);
   assert.equal(await page.evaluate(()=>window.__LV__.d[0]),data.payload);
   await page.setContent('<!doctype html><style>'+data.css+'</style><div id="lv-root">'+data.html+'</div>');
   await page.evaluate(()=>{
    window.pendingTimers=new Set();
    const set=window.setTimeout.bind(window),clear=window.clearTimeout.bind(window);
    window.setTimeout=(fn,ms,...args)=>{let id=set(()=>{pendingTimers.delete(id);fn(...args);},ms);pendingTimers.add(id);return id;};
    window.clearTimeout=id=>{pendingTimers.delete(id);clear(id);};
   });
   await page.addScriptTag({content:data.script});
   const bar=page.locator('body > [data-pending-bar]');
   const click=()=>page.locator('button').dispatchEvent('click');
   await click();
   await page.waitForFunction(()=>document.querySelector('body > [data-pending-bar]').style.display==='block');
   assert(await page.evaluate(()=>document.getAnimations().some(a=>a.effect.getTiming().iterations===Infinity)));
   await page.evaluate(()=>window.dispatchEvent(new PageTransitionEvent('pagehide',{persisted:true})));
   assert.equal(await bar.evaluate(e=>e.style.display),'none');
   assert.equal(await page.evaluate(()=>pendingTimers.size),0);
   assert.equal(await page.evaluate(()=>document.getAnimations().filter(a=>a.effect.getTiming().iterations===Infinity).length),0);
   await click();assert.equal(await page.evaluate(()=>pendingTimers.size),0,'suspended page refuses new timers');
   await page.evaluate(()=>window.dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true})));
   await click();
   await page.waitForFunction(()=>document.querySelector('body > [data-pending-bar]').style.display==='block');
   await page.evaluate(()=>document.dispatchEvent(new Event('live:frame')));
   assert.equal(await bar.evaluate(e=>e.style.display),'none');
   assert.equal(await page.evaluate(()=>pendingTimers.size),0);
   assert.equal(await page.locator('[data-lv-key="items"]').evaluate(e=>e.style.opacity),'');
   await page.evaluate(()=>{document.getElementById('lv-link').textContent='offline';});
   await page.waitForFunction(()=>document.getElementById('lv-link').textContent==='reconnecting');
   assert.deepEqual(errors,[]);await page.close();
  }
  console.log('PASS generated pending feedback: delayed animation, frame completion, pagehide timer/animation cleanup, suspension/BFCache resume; Live bootstrap/title script escaping; 1/4 harts');
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
