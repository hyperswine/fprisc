#!/usr/bin/env node
// Generated inventory console/history and scrolling. The real inventory view
// and Live client use presentation-only updates, with isolated browser storage.
const {chromium}=require('playwright');
const assert=require('node:assert/strict');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {execFileSync,spawnSync,spawn}=require('node:child_process');
const root=path.resolve(__dirname,'..'),tmp=fs.mkdtempSync(path.join(os.tmpdir(),'fpr-inventory-console-'));
const env={...process.env,FPR_HOME:root,XDG_CACHE_HOME:path.join(tmp,'cache')};
const build=(source,out)=>execFileSync(path.join(root,'fpr'),['build',source,'-o',out],{cwd:root,env,timeout:180000,stdio:'pipe'});
async function stop(child) {
  if(child.exitCode!==null||child.signalCode!==null)return;
  await new Promise((resolve,reject)=>{
    const timer=setTimeout(()=>{child.kill('SIGKILL');reject(Error('fixture shutdown timeout'));},10000);
    child.once('exit',()=>{clearTimeout(timer);resolve();});child.kill('SIGTERM');
  });
}
async function start(binary,harts) {
  const dir=path.join(tmp,'server-'+harts);fs.mkdirSync(dir);
  const child=spawn(binary,['serve'],{cwd:dir,env:{...env,FPR_HARTS:harts},stdio:['ignore','pipe','pipe']});
  let logs='';child.stderr.on('data',b=>logs=(logs+b).slice(-8000));
  try {
    const port=await new Promise((resolve,reject)=>{
      let out='';const timer=setTimeout(()=>reject(Error('startup timeout: '+logs)),30000);
      child.stdout.on('data',b=>{out+=b;const m=out.match(/ready (\d+)/);if(m){clearTimeout(timer);resolve(Number(m[1]));}});
      child.once('error',e=>{clearTimeout(timer);reject(e);});
      child.once('exit',code=>{clearTimeout(timer);reject(Error('fixture exit '+code+': '+logs));});
    });return {child,url:'http://127.0.0.1:'+port};
  } catch(e){await stop(child);throw e;}
}
(async()=>{
  let browser;
  try {
    const calc=path.join(tmp,'console-calc');build('tests/std/browserconsole.fpr',calc);
    assert.equal(execFileSync(calc,{encoding:'utf8'}),fs.readFileSync(path.join(root,'tests/std/browserconsole.expected'),'utf8'));
    for(const [arg,why] of [['bad-limit','limit must be positive'],['bad-take','negative count'],['bad-delay','delay 0'],['bad-defer','require program']]) {
      const p=spawnSync(calc,[arg],{encoding:'utf8',timeout:10000});assert.equal(p.status,1,arg);assert.match(p.stdout+p.stderr,new RegExp(why));
    }
    const vectors=JSON.parse(execFileSync(calc,['snapshot'],{encoding:'utf8'}));
    for(const row of vectors.vectors) {
      const value=new Function('_number','_string','_textSequence',vectors.runtime+'return '+row.code+';')(
        ()=>BigInt(row.cursor),()=>row.command,()=>row.history);
      assert.equal(value,row.want,row.code);
    }
    console.log('PASS: '+vectors.vectors.length+' native/generated text-history, cursor and Unicode-trim cases; invalid limits, tails and delay ownership refuse');

    const source=fs.readFileSync(path.join(root,'examples/inventory.fpr'),'utf8');
    const consoleBlock=source.slice(source.indexOf('consoleScript ='),source.indexOf('# Never frozen.'));
    assert.match(consoleBlock,/Console\.script/);assert.match(consoleBlock,/Console\.pager/);
    assert.doesNotMatch(consoleBlock,/function\s*\(|MutationObserver|setTimeout|querySelector|scrollTop|localStorage/);
    const sample=path.join(tmp,'inventory-sample.fpr'),binary=path.join(tmp,'inventory');
    fs.writeFileSync(sample,source.replace(/^main =/m,'applicationMain =')+'\n'+fs.readFileSync(path.join(root,'tests/inventoryconsole.fprinc'),'utf8'));
    build(sample,binary);const scripts=JSON.parse(execFileSync(binary,{encoding:'utf8'}));
    browser=await chromium.launch({headless:true,...(process.env.CHROME_BIN?{executablePath:process.env.CHROME_BIN}:{})});
    async function fixture(seed='[]',blocked=false) {
      const page=await browser.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
      await page.route('http://console.test/**',r=>r.fulfill({contentType:'text/html',body:'<!doctype html><div id="lv-root"><section data-console-scope><input data-console><button data-console-run><span>run</span></button><div data-console-output style="height:50px;overflow:auto;white-space:pre"></div></section><button data-pager>next</button><div id="inv-list" data-version="old">list</div></div><input id="unrelated" data-console>'}));
      await page.goto('http://console.test/');
      await page.evaluate(({seed,blocked})=>{
        if(blocked)Object.defineProperty(window,'localStorage',{get(){throw Error('storage unavailable');}});
        else localStorage.setItem('inventory-console',seed);
        window.delivered=[];const input=document.querySelector('[data-console-scope] input');
        input.onkeydown=e=>{if(e.key==='Enter')delivered.push(input.value);};
        document.querySelector('[data-console-run]').onclick=()=>delivered.push(input.value);
        window.scrolls=[];Element.prototype.scrollIntoView=function(options){scrolls.push([this.id,this.dataset.version,options]);};
      },{seed,blocked});
      await page.addScriptTag({content:scripts.console+scripts.pager});
      return {page,errors,input:page.locator('[data-console-scope] input')};
    }
    const f=await fixture();const p=f.page,input=f.input;
    await input.fill('  help  ');await input.press('Enter');await p.waitForFunction(()=>document.querySelector('[data-console-scope] input').value==='');
    assert.deepEqual(await p.evaluate(()=>delivered),['  help  ']);
    assert.deepEqual(await p.evaluate(()=>JSON.parse(localStorage.getItem('inventory-console'))),['help']);
    await input.fill(' help ');await p.locator('[data-console-run] span').click();
    await p.waitForFunction(()=>document.querySelector('[data-console-scope] input').value==='');
    assert.deepEqual(await p.evaluate(()=>JSON.parse(localStorage.getItem('inventory-console'))),['help']);
    await input.focus();await input.press('ArrowUp');assert.equal(await input.inputValue(),'help');
    await input.press('ArrowUp');assert.equal(await input.inputValue(),'help');
    await input.press('ArrowDown');assert.equal(await input.inputValue(),'');
    // Recall writes an input event so Live's local mirror can send the recalled command.
    await p.evaluate(()=>{window.recalled=[];document.querySelector('[data-console-scope] input').addEventListener('input',e=>recalled.push(e.target.value));});
    await input.press('ArrowUp');assert.equal(await p.evaluate(()=>recalled.at(-1)),'help');
    await input.fill(' \t ');await input.press('Enter');await p.waitForFunction(()=>document.querySelector('[data-console-scope] input').value==='');
    assert.deepEqual(await p.evaluate(()=>JSON.parse(localStorage.getItem('inventory-console'))),['help']);
    await p.evaluate(()=>{const el=document.querySelector('[data-console-scope] input');for(let i=1;i<=55;i++){el.value='command '+i;el.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));}});
    await p.waitForFunction(()=>document.querySelector('[data-console-scope] input').value==='');
    const history=await p.evaluate(()=>JSON.parse(localStorage.getItem('inventory-console')));
    assert.equal(history.length,50);assert.equal(history[0],'command 6');assert.equal(history.at(-1),'command 55');
    await input.focus();for(let i=0;i<55;i++)await input.press('ArrowUp');assert.equal(await input.inputValue(),'command 6');
    for(let i=0;i<55;i++)await input.press('ArrowDown');assert.equal(await input.inputValue(),'');
    await input.fill('original');
    await input.evaluate(el=>{el.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}));el.value='new draft';});
    await p.waitForTimeout(20);assert.equal(await input.inputValue(),'new draft');
    await input.evaluate(el=>{el.value='detached';el.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}));const next=el.cloneNode();next.value='replacement draft';el.replaceWith(next);});
    await p.waitForTimeout(20);assert.equal(await input.inputValue(),'replacement draft');
    const unrelated=p.locator('#unrelated');await unrelated.fill('leave alone');await unrelated.press('ArrowUp');assert.equal(await unrelated.inputValue(),'leave alone');
    // Explicit frame/local events scroll only the owned visible console output.
    await p.evaluate(()=>{const out=document.querySelector('[data-console-output]');out.textContent=Array.from({length:50},(_,i)=>'line '+i).join('\n');out.scrollTop=0;document.dispatchEvent(new Event('live:frame'));});
    assert.equal(await p.locator('[data-console-output]').evaluate(el=>Math.abs(el.scrollHeight-el.clientHeight-el.scrollTop)<2),true);
    // Pager delay reacquires the current list after a frame replaced it.
    await p.locator('[data-pager]').click();
    await p.locator('#inv-list').evaluate(el=>{const next=el.cloneNode(true);next.dataset.version='new';el.replaceWith(next);});
    await p.waitForFunction(()=>scrolls.length===1);
    assert.deepEqual(await p.evaluate(()=>scrolls[0]),['inv-list','new',{block:'start',behavior:'smooth'}]);
    await p.locator('[data-pager]').click();
    await p.evaluate(()=>window.dispatchEvent(new PageTransitionEvent('pagehide',{persisted:true})));
    await p.waitForTimeout(180);assert.equal(await p.evaluate(()=>scrolls.length),1);
    await p.evaluate(()=>{window.dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true}));window.dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true}));});
    await input.focus();await input.press('ArrowUp');assert.equal(await input.inputValue(),'detached');
    await p.locator('[data-pager]').click();await p.waitForFunction(()=>scrolls.length===2);
    assert.deepEqual(f.errors,[]);await p.close();
    for(const seed of ['not json','{}','["ok",7]']) {
      const bad=await fixture(seed);await bad.input.fill('draft');await bad.input.press('ArrowUp');assert.equal(await bad.input.inputValue(),'draft');
      await bad.input.press('Enter');await bad.page.waitForFunction(()=>document.querySelector('[data-console-scope] input').value==='');
      assert.deepEqual(await bad.page.evaluate(()=>JSON.parse(localStorage.getItem('inventory-console'))),['draft']);assert.deepEqual(bad.errors,[]);await bad.page.close();
    }
    const unavailable=await fixture('[]',true);await unavailable.input.fill('offline history');await unavailable.input.press('Enter');
    await unavailable.page.waitForFunction(()=>document.querySelector('[data-console-scope] input').value==='');
    await unavailable.input.press('ArrowUp');assert.equal(await unavailable.input.inputValue(),'offline history');assert.deepEqual(unavailable.errors,[]);await unavailable.page.close();
    const oversized=await fixture(JSON.stringify(Array.from({length:60},(_,i)=>'loaded '+i)));
    await oversized.input.focus();for(let i=0;i<55;i++)await oversized.input.press('ArrowUp');assert.equal(await oversized.input.inputValue(),'loaded 10');await oversized.page.close();
    console.log('PASS: generated console keeps 50 commands, trims/deduplicates, recalls and clears after delivery, preserves newer/replacement drafts, scopes hooks, tolerates bad/unavailable storage; pager reacquires targets and cancels/restores owned delays');

    for(const harts of ['1','4']) {
      const server=await start(binary,harts);const a=await browser.newPage(),b=await browser.newPage(),errors=[];
      for(const page of [a,b]) {
        page.on('pageerror',e=>errors.push(e.message));
        await page.addInitScript(()=>{window.commands=[];document.addEventListener('live:console-observed',e=>commands.push(e.detail));});
      }
      try {
        await a.goto(server.url);await b.goto(server.url);
        for(const page of [a,b])await page.getByRole('button',{name:'admin',exact:true}).click();
        const cmd=a.locator('[data-console]'),other=b.locator('[data-console]');
        await cmd.fill('  help  ');await cmd.press('Enter');await a.waitForFunction(()=>commands.includes('  help  '));
        await a.waitForFunction(()=>document.querySelector('[data-console]').value==='');
        await a.waitForFunction(()=>{const el=document.querySelector('[data-console-output]');return el.scrollHeight>el.clientHeight&&Math.abs(el.scrollHeight-el.clientHeight-el.scrollTop)<2;});
        assert.deepEqual(await a.evaluate(()=>JSON.parse(localStorage.getItem('inventory-console'))),['help']);
        await cmd.press('ArrowUp');assert.equal(await cmd.inputValue(),'help');await cmd.press('Enter');await a.waitForFunction(()=>commands.includes('help'));
        await cmd.fill('unfinished draft');await cmd.evaluate(el=>{window.savedCommand=el;el.setSelectionRange(2,8);});
        await other.fill('from second register');await b.getByRole('button',{name:'run',exact:true}).click();
        await b.waitForFunction(()=>commands.includes('from second register'));
        await a.waitForFunction(()=>document.querySelector('[data-console-output]')?.textContent.includes('from second register'));
        assert.deepEqual(await cmd.evaluate(el=>[el===savedCommand,el===document.activeElement,el.value,el.selectionStart,el.selectionEnd]),[true,true,'unfinished draft',2,8]);
        await cmd.press('ArrowUp');assert.equal(await cmd.inputValue(),'help','other page imported history');
        await a.reload();await a.getByRole('button',{name:'admin',exact:true}).click();await a.locator('[data-console]').focus();
        await a.locator('[data-console]').press('ArrowUp');assert.equal(await a.locator('[data-console]').inputValue(),'help');
        await a.getByRole('button',{name:'items',exact:true}).click();
        await a.evaluate(()=>{window.pageScrolls=[];const original=Element.prototype.scrollIntoView;Element.prototype.scrollIntoView=function(opts){pageScrolls.push([this.id,opts]);return original.call(this,opts);};});
        await a.getByRole('button',{name:'next',exact:true}).click();
        await a.getByText('page 2 of 3',{exact:true}).waitFor();await a.waitForFunction(()=>pageScrolls.some(x=>x[0]==='inv-list'));
        assert.deepEqual(await a.evaluate(()=>pageScrolls.at(-1)),['inv-list',{block:'start',behavior:'smooth'}]);
        assert.deepEqual(errors,[]);
        console.log('PASS: inventory '+harts+' hart(s), raw command delivered before clearing, recalled command mirrored/sent, actual output scroll, focus/draft preserved across another page frame, reload history, pager frame and smooth scroll');
      } finally {await a.close();await b.close();await stop(server.child);}
    }
  } finally {if(browser)await browser.close();fs.rmSync(tmp,{recursive:true,force:true});}
})().catch(e=>{console.error(e);process.exitCode=1;});
