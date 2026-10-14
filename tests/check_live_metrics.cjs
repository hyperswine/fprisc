#!/usr/bin/env node
// Native/generated statistics and deterministic Chromium transport/lifecycle
// checks. The real Live client runs against a controlled WebSocket boundary.
const {chromium}=require('playwright');
const assert=require('node:assert/strict');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {execFileSync,spawnSync}=require('node:child_process');
const root=path.resolve(__dirname,'..'),tmp=fs.mkdtempSync(path.join(os.tmpdir(),'fpr-live-metrics-'));
const env={...process.env,FPR_HOME:root,XDG_CACHE_HOME:path.join(tmp,'cache')};
(async()=>{
  let browser;
  try {
    const binary=path.join(tmp,'metrics');
    execFileSync(path.join(root,'fpr'),['build','tests/std/livemetrics.fpr','-o',binary],{cwd:root,env,timeout:180000,stdio:'pipe'});
    assert.equal(execFileSync(binary,{encoding:'utf8'}),fs.readFileSync(path.join(root,'tests/std/livemetrics.expected'),'utf8'));
    for(const [arg,why] of [['bad-take','negative count'],['bad-at','index out of bounds'],['bad-sum','Int overflow'],['bad-interval','interval 1']]) {
      const p=spawnSync(binary,[arg],{encoding:'utf8',timeout:10000});assert.equal(p.status,1,arg);
      assert.match(p.stdout+p.stderr,new RegExp(why));
    }
    const data=JSON.parse(execFileSync(binary,['snapshot'],{encoding:'utf8'}));
    const bindings="function _sequence(k){return [9007199254740993n,4n,-2n,9007199254740992n];}\n";
    for(const {code,want} of data.vectors)
      assert.equal(new Function(data.runtime+bindings+'return '+code+';')(),want,code);
    for(const code of data.errors)assert.throws(()=>new Function(data.runtime+'return '+code+';')(),/bounds|overflow/);
    assert.doesNotMatch(data.script,/WebSocket|\.prototype|toFixed|Array\.prototype/);
    for(const app of ['pos1','inventory']) {
      const source=fs.readFileSync(path.join(root,'examples',app+'.fpr'),'utf8');
      assert.match(source,/rttScript = Metrics\.script/);assert.doesNotMatch(source,/WebSocket\.prototype|inv:frame/);
    }
    console.log('PASS: '+data.vectors.length+' native/generated list/statistic/rounding cases, immutable exact-integer sorting, checked reductions, invalid indices/timers and generated app adoption');

    browser=await chromium.launch({headless:true,...(process.env.CHROME_BIN?{executablePath:process.env.CHROME_BIN}:{})});
    async function fixture(withTransport=false) {
      const page=await browser.newPage(),errors=[];page.on('pageerror',error=>errors.push(String(error)));
      await page.evaluate(()=>{
        window.testNow=0;Object.defineProperty(performance,'now',{value:()=>testNow});
        window.intervals=new Map();window.timeouts=new Map();let next=0;
        window.setInterval=(fn,ms)=>{const id=++next;intervals.set(id,{fn,ms});return id;};
        window.clearInterval=id=>intervals.delete(id);
        window.setTimeout=(fn,ms)=>{const id=++next;timeouts.set(id,{fn,ms});return id;};
        window.clearTimeout=id=>timeouts.delete(id);
        window.tick=()=>{for(const {fn} of [...intervals.values()])fn();};
        window.emit=name=>document.dispatchEvent(new Event(name));
        window.sockets=[];
        class FakeSocket {
          constructor(url){this.url=url;this.readyState=0;this.sent=[];sockets.push(this);}
          send(data){if(this.fail)throw Error('controlled send failure');this.sent.push(data);}
          close(code=1000){this.readyState=3;this.onclose?.({code});}
        }
        window.WebSocket=FakeSocket;window.originalSend=FakeSocket.prototype.send;
      });
      await page.setContent('<!doctype html><div id="lv-root"></div><span id="rtt">measuring</span><div id="rollback">unchanged</div>');
      await page.evaluate(()=>{window.projectionErrors=[];document.addEventListener('fpr:client-error',e=>projectionErrors.push(e.detail.message));});
      await page.addScriptTag({content:data.script});
      if(withTransport) {
        await page.evaluate(()=>{
          window.observed=[];
          for(const name of ['live:sent','live:frame','live:disconnected'])document.addEventListener(name,e=>observed.push([name,e.detail]));
          window.__LV__={s:['<button data-click="Bump">bump</button><input data-input="draft" x-data="draft=">'],d:[]};
        });
        await page.addScriptTag({content:data.transport});
        await page.evaluate(()=>{const s=sockets[0];s.readyState=1;s.onopen({});});
      }
      return {page,errors};
    }
    const {page,errors}=await fixture();
    await page.evaluate(()=>tick());assert.equal(await page.locator('#rtt').textContent(),'no round trips yet');
    // An unsolicited frame is not a latency sample. A send at time zero is.
    await page.evaluate(()=>{emit('live:frame');emit('live:sent');testNow=.05;emit('live:frame');emit('live:frame');tick();});
    assert.equal(await page.locator('#rtt').textContent(),'last 0.1 ms, median of the last 1 0.1 ms, avg 0.1 ms, max 0.1 ms, over 1');
    // Multiple sends replace the pending timestamp; one accepted frame samples once.
    await page.evaluate(()=>{testNow=1;emit('live:sent');testNow=5;emit('live:sent');testNow=8;emit('live:frame');tick();});
    assert.equal(await page.locator('#rtt').textContent(),'last 3.0 ms, median of the last 2 3.0 ms, avg 1.5 ms, max 3.0 ms, over 2');
    await page.evaluate(()=>{testNow=9;emit('live:sent');emit('live:disconnected');testNow=100;emit('live:frame');tick();});
    assert.match(await page.locator('#rtt').textContent(),/over 2$/);
    // Hidden metrics skip DOM work, then render the retained statistics when shown.
    await page.locator('#rtt').evaluate(el=>el.style.display='none');
    await page.evaluate(()=>{testNow=101;emit('live:sent');testNow=102;emit('live:frame');tick();});
    assert.match(await page.locator('#rtt').textContent(),/over 2$/);
    await page.locator('#rtt').evaluate(el=>el.style.display='');await page.evaluate(()=>tick());
    assert.match(await page.locator('#rtt').textContent(),/over 3$/);
    await page.evaluate(()=>{testNow=103;emit('live:sent');window.dispatchEvent(new PageTransitionEvent('pagehide',{persisted:true}));});
    assert.equal(await page.evaluate(()=>intervals.size),0);
    await page.evaluate(()=>{testNow=200;emit('live:sent');testNow=205;emit('live:frame');window.dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true}));
      window.dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true}));emit('live:frame');tick();});
    assert.equal(await page.evaluate(()=>intervals.size),1);assert.match(await page.locator('#rtt').textContent(),/over 3$/);
    await page.evaluate(()=>{testNow=206;emit('live:sent');testNow=208;emit('live:frame');tick();});
    assert.match(await page.locator('#rtt').textContent(),/over 4$/);
    await page.addScriptTag({content:data.rollback});
    await page.evaluate(()=>emit('test:bad'));assert.equal(await page.locator('#rollback').textContent(),'unchanged');
    await page.evaluate(()=>emit('test:show'));assert.equal(await page.locator('#rollback').textContent(),'0:0');
    assert.match((await page.evaluate(()=>projectionErrors))[0],/overflow/);assert.deepEqual(errors,[]);await page.close();
    const bounded=await fixture();
    await bounded.page.evaluate(()=>{for(let i=1;i<=40;i++){testNow=i*100;emit('live:sent');testNow+=i;emit('live:frame');}tick();});
    assert.equal(await bounded.page.locator('#rtt').textContent(),'last 40.0 ms, median of the last 32 25.0 ms, avg 20.5 ms, max 40.0 ms, over 40');
    assert.deepEqual(bounded.errors,[]);await bounded.page.close();
    const ordered=await fixture();
    await ordered.page.evaluate(()=>{
      const samples=[...Array.from({length:32},(_,i)=>100-i),1,2,3,4,5,6,7,8];
      for(let i=0;i<samples.length;i++){testNow=i*200;emit('live:sent');testNow+=samples[i];emit('live:frame');tick();}
    });
    assert.equal(await ordered.page.locator('#rtt').textContent(),'last 8.0 ms, median of the last 32 77.0 ms, avg 68.5 ms, max 100.0 ms, over 40');
    assert.deepEqual(ordered.errors,[]);await ordered.page.close();
    console.log('PASS: generated monitor at time zero, overlapping sends, unsolicited frames, disconnect reset, 32-sample upper median, all-time average/max, hidden output, page suspension/restoration and atomic state/DOM rollback');

    const real=await fixture(true),p=real.page;
    await p.evaluate(()=>{testNow=10;document.querySelector('button').click();testNow=12;sockets[0].onmessage({data:'{"d":{}}'});tick();});
    assert.match(await p.locator('#rtt').textContent(),/last 2\.0 ms.*over 1$/);
    assert.equal(await p.evaluate(()=>WebSocket.prototype.send===originalSend),true);
    assert.equal(await p.evaluate(()=>Object.hasOwn(WebSocket.prototype,'onmessage')),false);
    await p.evaluate(()=>{const other=new WebSocket('ws://unrelated');other.readyState=1;other.send('unrelated');tick();});
    assert.equal(await p.evaluate(()=>observed.filter(x=>x[0]==='live:sent').length),1);
    // Accepted commands also finish observations; callbacks see the applied frame.
    await p.evaluate(()=>{testNow=20;document.querySelector('button').click();testNow=24;sockets[0].onmessage({data:'{"emit":"test","detail":"done"}'});tick();});
    assert.match(await p.locator('#rtt').textContent(),/over 2$/);
    await p.evaluate(()=>{sockets[0].fail=true;try{document.querySelector('button').onclick();}catch(e){window.failed=e.message;}tick();});
    assert.equal(await p.evaluate(()=>failed),'controlled send failure');
    assert.equal(await p.evaluate(()=>observed.filter(x=>x[0]==='live:sent').length),2);
    await p.evaluate(()=>{sockets[0].fail=false;testNow=30;document.querySelector('button').click();sockets[0].onmessage({data:'invalid json'});tick();});
    assert.equal(await p.evaluate(()=>observed.filter(x=>x[0]==='live:frame').length),2);
    assert.equal(await p.evaluate(()=>observed.filter(x=>x[0]==='live:disconnected').length),1);
    // Reconnect initial frames cannot finish the old socket's pending sample.
    await p.evaluate(()=>{const reconnect=[...timeouts.values()][0];timeouts.clear();reconnect.fn();
      const s=sockets.at(-1);s.readyState=1;s.onopen({});testNow=100;s.onmessage({data:'{"d":{}}'});tick();});
    assert.match(await p.locator('#rtt').textContent(),/over 2$/);
    // A rejected structural patch does not dispatch the accepted-frame event.
    await p.evaluate(()=>{testNow=110;document.querySelector('button').click();sockets.at(-1).onmessage({data:'{"p":99,"s":[],"d":[]}'});tick();});
    assert.equal(await p.evaluate(()=>observed.filter(x=>x[0]==='live:frame').length),3);
    assert.equal(await p.evaluate(()=>observed.every(x=>x[1]===undefined)),true,'transport observation exposed payload');
    assert.deepEqual(real.errors,[]);await p.close();
    console.log('PASS: actual Live send/accepted-frame/disconnect hooks, failed send, malformed/rejected frame, reconnect isolation, unrelated sockets, unchanged WebSocket prototype and payload-free observations');
  } finally {if(browser)await browser.close();fs.rmSync(tmp,{recursive:true,force:true});}
})().catch(error=>{console.error(error);process.exitCode=1;});
