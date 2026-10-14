#!/usr/bin/env node
// Differential native/generated computations, scoped DOM effects and actual
// POS carts/checkout. All stores and listeners belong to disposable fixtures.
const {chromium}=require('playwright');
const assert=require('node:assert/strict');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {execFileSync,spawnSync,spawn}=require('node:child_process');
const root=path.resolve(__dirname,'..');
const tmp=fs.mkdtempSync(path.join(os.tmpdir(),'fpr-client-calculations-'));
const env={...process.env,FPR_HOME:root,XDG_CACHE_HOME:path.join(tmp,'cache')};
const build=(source,out)=>execFileSync(path.join(root,'fpr'),['build',source,'-o',out],
  {cwd:root,env,timeout:180000,stdio:'pipe'});
async function stop(child) {
  if(child.exitCode!==null||child.signalCode!==null)return;
  await new Promise((resolve,reject)=>{
    const timer=setTimeout(()=>{child.kill('SIGKILL');reject(Error('fixture did not shut down'));},10000);
    child.once('exit',()=>{clearTimeout(timer);resolve();});child.kill('SIGTERM');
  });
}
async function start(binary,harts) {
  const directory=path.join(tmp,'server-'+harts);fs.mkdirSync(directory);
  const store=path.join(directory,'pos.log');
  const child=spawn(binary,{cwd:directory,env:{...env,FPR_HARTS:harts,
    POS1_PORT:'0',POS1_STORE:store,POS1_VIEW_VERIFY:'1'},stdio:['ignore','pipe','pipe']});
  let logs='';child.stderr.on('data',data=>{logs=(logs+data).slice(-8000);});
  try {
    const port=await new Promise((resolve,reject)=>{
      let out='';const timer=setTimeout(()=>reject(Error('startup timeout: '+logs)),30000);
      child.stdout.on('data',data=>{out+=data;const match=out.match(/ready (\d+)/);
        if(match){clearTimeout(timer);resolve(Number(match[1]));}});
      child.once('error',e=>{clearTimeout(timer);reject(e);});
      child.once('exit',code=>{clearTimeout(timer);reject(Error('fixture exited '+code+': '+logs));});
    });
    return {child,url:'http://127.0.0.1:'+port,store};
  } catch(e) {await stop(child);throw e;}
}
async function total(page,want) {
  await page.waitForFunction(want=>document.getElementById('cart-total')?.textContent===want,want);
}
async function login(page,url,name,pin) {
  await page.goto(url);await page.getByPlaceholder('cashier',{exact:true}).fill(name);
  await page.getByPlaceholder('PIN',{exact:true}).fill(pin);
  await page.getByRole('button',{name:'open register',exact:true}).click();
  await total(page,'$0.00');
}
(async()=>{
  let browser;
  try {
    const calc=path.join(tmp,'calc');build('tests/std/clientcalc.fpr',calc);
    assert.equal(execFileSync(calc,{encoding:'utf8'}),fs.readFileSync(path.join(root,'tests/std/clientcalc.expected'),'utf8'));
    for(const [arg,why] of [['bad-overflow','Int overflow'],['bad-intermediate','Int overflow'],
      ['bad-divide','division by zero'],['bad-pad','negative width']]) {
      const p=spawnSync(calc,[arg],{encoding:'utf8',timeout:10000});
      assert.equal(p.status,1,arg);assert.match(p.stdout+p.stderr,new RegExp(why));
    }
    const data=JSON.parse(execFileSync(calc,['snapshot'],{encoding:'utf8'}));
    for(const {code,want} of data.vectors)
      assert.equal(new Function(data.runtime+'return '+code+';')(),want,code);
    for(const code of data.errors)
      assert.throws(()=>new Function(data.runtime+'return '+code+';')(),/overflow|zero/);
    assert.doesNotMatch(data.effects,/<\/script/i);
    console.log('PASS: '+data.vectors.length+' native/generated results agree, including signed/min/max Int, >2^53, rounding, lazy branches, escaping; overflow/zero division refuse');

    browser=await chromium.launch({headless:true,...(process.env.CHROME_BIN?{executablePath:process.env.CHROME_BIN}:{})});
    const page=await browser.newPage();const errors=[];page.on('pageerror',error=>errors.push(String(error)));
    await page.setContent('<!doctype html><div id="probe"></div><script>'+data.effects+'</script>');
    await page.evaluate(()=>document.dispatchEvent(new CustomEvent('live:locals',{detail:{}})));
    const tricky=data.vectors.find(v=>v.want.startsWith('</script>')).want;
    assert.equal(await page.locator('#probe').textContent(),'42'+tricky);
    assert.equal(await page.locator('img').count(),0);

    const source=fs.readFileSync(path.join(root,'examples/pos1.fpr'),'utf8');
    const cart=source.slice(source.indexOf('cartScript ='),source.indexOf('rttScript = Metrics.script'));
    assert.match(cart,/cartScript = B.onLocals/);assert.doesNotMatch(cart,/Math\.floor|function\s*\(|document\./);
    const sample=path.join(tmp,'pos-sample.fpr'),snapshotBinary=path.join(tmp,'snapshot');
    fs.copyFileSync(path.join(root,'examples/pos1_pricing.fpr'),path.join(tmp,'pos1_pricing.fpr'));
    fs.writeFileSync(sample,source.replace(/^main =/m,'applicationMain =')+'\n'+fs.readFileSync(path.join(root,'tests/poscalculations.fprinc'),'utf8'));
    build(sample,snapshotBinary);
    const snapshot=JSON.parse(execFileSync(snapshotBinary,{encoding:'utf8'}));
    const markup=snapshot.s.map((s,i)=>s+(i<snapshot.d.length?'<span data-slot="'+i+'"></span>':'')).join('');
    await page.setContent('<!doctype html><style>'+snapshot.css+'</style>'+markup+'<script>'+snapshot.script+'</script>');
    await page.locator('[data-slot]').evaluateAll((els,ds)=>{for(const el of els)el.textContent=ds[Number(el.dataset.slot)];},snapshot.d);
    await page.evaluate(()=>{
      window.projectionErrors=[];
      document.addEventListener('fpr:client-error',e=>projectionErrors.push(e.detail.message));
      const outside=document.createElement('div');outside.dataset.line='FW';outside.dataset.price='999';document.body.append(outside);
    });
    const paint=quantities=>page.evaluate(detail=>document.dispatchEvent(new CustomEvent('live:locals',{detail})),quantities);
    await paint({q_FW:'2',q_BR:'1'});await total(page,'$17.60');
    assert.equal(await page.locator('[data-line="FW"] [data-line-total]').textContent(),'$10.00');
    await page.locator('[data-tax]').evaluate(el=>{
      const clone=el.cloneNode(true);clone.setAttribute('data-copy','');clone.querySelector('[data-line="FW"]').dataset.price='700';el.after(clone);
    });
    await paint({q_FW:'2'});
    assert.equal(await page.locator('[data-tax]:not([data-copy]) #cart-total').textContent(),'$11.00');
    assert.equal(await page.locator('[data-copy] #cart-total').textContent(),'$15.40');
    await page.locator('[data-copy]').evaluate(el=>el.remove());
    await page.locator('[data-tax] [data-line="FW"][data-price]').evaluate(el=>el.dataset.price='5');
    await paint({q_FW:'1'});await total(page,'$0.06');
    await paint({q_FW:'0'});await total(page,'$0.00');assert.equal(await page.locator('#cart-empty').isVisible(),true);
    await paint({q_FW:'1.5'});await total(page,'$0.00');
    await paint({q_FW:'1\n'});await total(page,'$0.00');
    await page.locator('[data-tax]').evaluate(el=>{el.dataset.tax='0';el.querySelector('[data-line="FW"]').dataset.price='9007199254740993';});
    await paint({q_FW:'1'});await total(page,'$90071992547409.93');
    const before=await page.locator('[data-tax]').textContent();
    await paint({q_FW:'4611686018427387903'});
    assert.equal(await page.locator('[data-tax]').textContent(),before,'overflow partially painted the cart');
    await paint({q_FW:'4611686018427387904'});
    await page.locator('[data-tax]').evaluate(el=>el.dataset.tax='bad');await paint({q_FW:'0'});
    assert.equal(await page.locator('[data-tax]').textContent(),before,'invalid input partially painted the cart');
    assert.equal((await page.evaluate(()=>projectionErrors)).length,3);
    await page.locator('[data-tax]').evaluate(el=>el.dataset.tax='0');await paint({q_FW:'0'});await total(page,'$0.00');
    assert.deepEqual(errors,[]);await page.close();
    console.log('PASS: real POS projection, scoped repeated panels, half-cent rounding, large exact cents, empty state, malformed locals, atomic refusal and recovery; text stays text');

    const binary=path.join(tmp,'pos');build('examples/pos1.fpr',binary);
    for(const harts of ['1','4']) {
      const server=await start(binary,harts);
      const a=await browser.newPage(),b=await browser.newPage();const pageErrors=[];
      for(const p of [a,b])p.on('pageerror',e=>pageErrors.push(String(e)));
      for(const p of [a,b])await p.addInitScript(()=>{window.originalSocketSend=WebSocket.prototype.send;});
      try {
        await login(a,server.url,'ana','1234');await login(b,server.url,'ben','2222');
        await a.locator('[data-set="q_FW"][data-val="+1"]').first().click({clickCount:2});await total(a,'$11.00');
        await b.locator('[data-set="q_BR"][data-val="+1"]').first().click();await total(b,'$6.60');
        const tender=a.getByPlaceholder('cash tendered');await tender.fill('20.00');
        await tender.evaluate(el=>{window.savedTender=el;el.focus();el.setSelectionRange(0,2);});
        await b.getByRole('button',{name:'Admin',exact:true}).click();
        const command=b.locator('[data-input="cmd"]');await command.fill('set price FW 650');await command.press('Enter');
        await total(a,'$14.30');
        await b.waitForFunction(()=>/over [1-9][0-9]* /.test(document.getElementById('pos-rtt')?.textContent||''));
        assert.equal(await b.evaluate(()=>WebSocket.prototype.send===originalSocketSend),true);
        assert.deepEqual(await tender.evaluate(el=>[el===savedTender,el===document.activeElement,el.value,el.selectionStart,el.selectionEnd]),[true,true,'20.00',0,2]);
        await b.getByRole('button',{name:'Register',exact:true}).click();await total(b,'$6.60');
        await a.getByRole('button',{name:'card',exact:true}).click();await total(a,'$0.00');await total(b,'$6.60');
        await b.getByRole('button',{name:'card',exact:true}).click();await total(b,'$0.00');
        const sales=fs.readFileSync(server.store,'utf8').split('\n').filter(line=>line.startsWith('sale '));
        assert.equal(sales.length,2);assert.match(sales[0],/ 1430 130 FW=2=650/);assert.match(sales[1],/ 660 60 BR=1=600/);
        assert.deepEqual(pageErrors,[]);
        console.log('PASS: POS '+harts+' hart(s), two independent real browser carts, live price changes, focused draft/selection retained, native receipts agree and checkout clears only its cart');
      } finally {await a.close();await b.close();await stop(server.child);}
    }
  } finally {if(browser)await browser.close();fs.rmSync(tmp,{recursive:true,force:true});}
})().catch(e=>{console.error(e);process.exitCode=1;});
