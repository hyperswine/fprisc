#!/usr/bin/env node
// Actual hosted apps and generated-client failure/lifecycle checks. Everything
// runs from disposable copies; no real account, printer or existing store used.
const {chromium}=require('playwright');
const assert=require('node:assert/strict');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {spawn,spawnSync}=require('node:child_process');
const root=path.resolve(__dirname,'..'),tmp=fs.mkdtempSync(path.join(os.tmpdir(),'sol-web-'));
const processes=[];
async function start(name,source) {
 const file=path.join(tmp,name+'.sol');fs.writeFileSync(file,source);
 const child=spawn(path.join(root,'fpr'),['sol',file],{cwd:tmp,env:{...process.env,
  FPR_HOME:root,PATH:'/nonexistent',SOL_VERBOSE:'1',SOL_JIT:'0',SOL_GPU:'0',SOL_CACHE_DIR:path.join(tmp,'cache')},stdio:['ignore','pipe','pipe']});
 processes.push(child);let error='';child.stderr.on('data',b=>{error=(error+b).slice(-12000);});
 const port=await new Promise((resolve,reject)=>{const timeout=setTimeout(()=>reject(Error('startup: '+error)),30000);
  child.stderr.on('data',()=>{const m=error.match(/serving MVU app on http:\/\/localhost:(\d+)/);if(m){clearTimeout(timeout);resolve(Number(m[1]));}});
  child.once('exit',code=>{clearTimeout(timeout);reject(Error(name+' exited '+code+': '+error));});});
 return {child,url:'http://127.0.0.1:'+port};
}
async function stop(child) {
 if(child.exitCode!==null||child.signalCode!==null)return;
 await new Promise((resolve,reject)=>{const timer=setTimeout(()=>{child.kill('SIGKILL');reject(Error('shutdown timeout'));},5000);
  child.once('exit',()=>{clearTimeout(timer);resolve();});child.kill('SIGTERM');});
}
function source(name) {return fs.readFileSync(path.join(root,'sol/examples',name+'.sol'),'utf8')
 .replaceAll('use "../lib/','use "'+root+'/sol/lib/').replace(/View\.serve \d+ /,'View.serve 0 ');}
async function localStyles(page) {
 const selectors=await page.evaluate(()=>{
  const visit=rules=>Array.from(rules).flatMap(rule=>rule.selectorText?[rule.selectorText]:rule.cssRules?visit(rule.cssRules):[]);
  return Array.from(document.styleSheets).flatMap(sheet=>visit(sheet.cssRules));});
 assert(selectors.length>100,'generated stylesheet has '+selectors.length+' selectors: '+JSON.stringify(await page.evaluate(()=>Array.from(document.styleSheets).map(s=>({href:s.href,rules:s.cssRules.length})))));
 assert(selectors.every(s=>/^\.fpr-u-[0-6]-[0-9a-f]+(?::(?:hover|focus-visible|disabled))?$/.test(s)),selectors.filter(s=>!s.startsWith('.fpr-u-')));
 assert.equal(await page.locator('body').evaluate(e=>getComputedStyle(e).margin),'0px');
 assert.equal(await page.locator('[style]').count(),0);
}
(async()=>{
 let browser;
 try {
  const host=fs.readFileSync(path.join(root,'compiler/Sol/Web.hs'),'utf8');
  assert.doesNotMatch(host.replace(/^\s*--.*$/gm,''),/<script|<style|document\.|window\.|className|\.tbl\b/);
  assert.match(host,/Sol.WebAssets/);
  const bad=path.join(tmp,'bad-style.sol');
  fs.writeFileSync(bad,'ui = use "'+root+'/sol/lib/ui".\n> print (ui.div ["card"] []).\n');
  const refused=spawnSync(path.join(root,'fpr'),['sol',bad],{env:{...process.env,SOL_CACHE_DIR:path.join(tmp,'cache')},encoding:'utf8',timeout:30000});
  assert.notEqual(refused.status,0);assert.match(refused.stderr,/cannot unify.*(?:Appearance|String)/);
  browser=await chromium.launch({headless:true,...(process.env.CHROME_BIN?{executablePath:process.env.CHROME_BIN}:{})});
  let client,css;
  for(const name of ['blog','dash','pos','pos2','todo','todo2','terra']) {
   const app=await start(name,source(name));const page=await browser.newPage({viewport:{width:1200,height:900}}),errors=[];
   page.on('pageerror',e=>errors.push(e.message));await page.goto(app.url);
   await page.waitForFunction(()=>document.getElementById('root').childNodes.length>0);
   await localStyles(page);
   if(!client){client=await (await page.request.get(app.url+'/_sol/client.js')).text();css=await (await page.request.get(app.url+'/_sol/style.css')).text();}
   assert.equal((await page.request.get(app.url+'/missing')).status(),404);
   if(name==='blog') {
    await page.getByPlaceholder('write a comment...').fill('λ😀 </script> & text');
    await page.getByRole('button',{name:'Post',exact:true}).click();
    await page.getByText('λ😀 </script> & text',{exact:true}).waitFor();
    await page.reload();await page.getByText('λ😀 </script> & text',{exact:true}).waitFor();
    assert.equal(await page.locator('#root script').count(),0);
   }
   if(name==='pos2'||name==='todo2') {
    if(name==='pos2') {
     assert.equal(await page.getByText('Sol POS',{exact:true}).evaluate(e=>getComputedStyle(e).backgroundClip),'text');
     assert.equal(await page.locator('form[data-sol-form="login"]').locator('..').evaluate(e=>getComputedStyle(e).backdropFilter),'blur(8px)');
     const button=page.getByRole('button',{name:'Sign in',exact:true});await button.hover();
     assert.equal(await button.evaluate(e=>getComputedStyle(e).filter),'brightness(1.08)');
    }
    const form=page.locator('form[data-sol-form="register"]');
    await form.locator('[data-sol-field="username"]').fill('test');await form.locator('[data-sol-field="password"]').fill('test-only');
    assert.equal(await form.locator('[data-sol-field="password"]').getAttribute('type'),'password');
    await form.getByRole('button',{name:'Create account'}).click();await page.getByRole('button',{name:'sign out',exact:true}).waitFor();
    assert.equal(await page.getByRole('button',{name:'sign out',exact:true}).evaluate(e=>getComputedStyle(e).userSelect),'none');
    if(name==='pos2') {
     await page.getByRole('button').filter({hasText:/^flat white/}).click();
     await page.getByRole('button',{name:'Charge $5',exact:true}).click();
     await page.getByRole('button',{name:'Receipts',exact:true}).click();await page.getByText('1 sales, $5 all-time',{exact:true}).waitFor();
     await page.getByRole('button',{name:'Inventory',exact:true}).click();
     assert.equal(await page.locator('table').evaluate(e=>getComputedStyle(e).borderCollapse),'collapse');
    } else {
     await page.getByPlaceholder('what needs doing?').fill('generated todo');await page.getByRole('button',{name:'Add',exact:true}).click();
     await page.getByText('generated todo',{exact:false}).waitFor();
    }
    await page.reload();await page.getByRole('button',{name:'sign out',exact:true}).waitFor();
   }
   for(const width of [1200,390]) {await page.setViewportSize({width,height:900});
    assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),name+' overflow at '+width);}
   assert.deepEqual(errors,[],name);await page.close();await stop(app.child);
   console.log('PASS actual Sol '+name+': generated assets, local CSS, responsive view and live session');
  }
  // A controlled socket drives hostile text, changed handlers, draft identity,
  // storage refusal, reconnect and BFCache without relying on timer luck.
  const page=await browser.newPage();await page.route('http://sol.test/**',route=>route.fulfill({body:'<!doctype html><style>'+css+'</style><div id="root"></div>'}));
  await page.goto('http://sol.test/');
  await page.evaluate(()=>{
   window.sockets=[];window.sent=[];window.pending=new Set();
   window.WebSocket=class {constructor(){this.readyState=1;sockets.push(this);}send(value){sent.push(JSON.parse(value));}close(){this.readyState=3;this.onclose?.();}};
   Object.defineProperty(window,'localStorage',{configurable:true,get(){throw Error('storage refused');}});
   const set=window.setTimeout.bind(window),clear=window.clearTimeout.bind(window);
   window.setTimeout=(fn,ms)=>{let id=set(()=>{pending.delete(id);fn();},ms);pending.add(id);return id;};
   window.clearTimeout=id=>{pending.delete(id);clear(id);};
  });
  await page.addScriptTag({content:client});
  await page.evaluate(()=>sockets[0].onopen());assert.deepEqual(await page.evaluate(()=>sent),[{hello:null}]);
  const text='λ😀 </script><img src=x onerror=alert(1)>';
  await page.evaluate(text=>sockets[0].onmessage({data:JSON.stringify({token:'test',view:{dyn:'quote"[]',node:[{key:'edit',node:{form:'first',fields:['draft'],btn:'Save'}},{key:'label',node:{text}}]}})}),text);
  const input=page.locator('input');await input.fill('unfinished');await input.evaluate(e=>{window.original=e;e.focus();e.setSelectionRange(2,6);});
  await page.evaluate(text=>sockets[0].onmessage({data:JSON.stringify({patch:{'quote"[]':[{key:'label',node:{text:text+' new'}},{key:'edit',node:{form:'second',fields:['draft'],btn:'Save'}}]}})}),text);
  assert.deepEqual(await input.evaluate(e=>[e===original,e.value,document.activeElement===e,e.selectionStart,e.selectionEnd]),[true,'unfinished',true,2,6]);
  await page.getByRole('button',{name:'Save',exact:true}).click();
  assert.deepEqual(await page.evaluate(()=>sent.at(-1)),{ev:'second',val:'unfinished'});assert.equal(await input.inputValue(),'');
  assert.equal(await page.locator('#root img').count(),0);
  await page.evaluate(()=>sockets[0].onclose());await page.waitForFunction(()=>sockets.length===2);
  await page.evaluate(()=>sockets[1].onopen());assert.deepEqual(await page.evaluate(()=>sent.at(-1)),{hello:'test'});
  await page.evaluate(()=>window.dispatchEvent(new PageTransitionEvent('pagehide',{persisted:true})));
  assert.equal(await page.evaluate(()=>pending.size),0);
  await page.evaluate(()=>window.dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true})));
  assert.equal(await page.evaluate(()=>sockets.length),3);
  // A stale socket's update cannot overwrite the resumed page.
  await page.evaluate(()=>sockets[1].onmessage({data:JSON.stringify({token:'stale',view:{text:'stale'}})}));
  assert.equal(await page.getByText('stale',{exact:true}).count(),0);
  await page.evaluate(()=>sockets[2].onopen());
  const before=await page.locator('#root').textContent();
  await page.evaluate(()=>sockets[2].onmessage({data:JSON.stringify({token:'bad',view:{tag:'div',classes:['card'],kids:[]}})}));
  assert.equal(await page.locator('#root').textContent(),before,'invalid style changed the page');
  await page.evaluate(()=>window.dispatchEvent(new PageTransitionEvent('pagehide',{persisted:true})));
  assert.equal(await page.evaluate(()=>pending.size),0);
  await page.close();console.log('PASS generated Sol client: text/Unicode, storage refusal, draft/focus identity, updated handlers, reconnect and BFCache/stale-socket cleanup');
 } finally {if(browser)await browser.close();for(const child of processes)await stop(child);fs.rmSync(tmp,{recursive:true,force:true});}
})().catch(e=>{console.error(e);process.exitCode=1;});
