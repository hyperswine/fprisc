#!/usr/bin/env node
// Actual FP view in Chromium: local appearance, mobile layout and focus.
const {chromium}=require('playwright');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const os=require('node:os');
const vm=require('node:vm');
const {execFileSync,spawnSync,spawn}=require('node:child_process');
const root=path.resolve(__dirname,'..');
const tmp=fs.mkdtempSync(path.join(os.tmpdir(),'fpr-printer-styles-'));
(async()=>{
 let browser;
 const children=[];
 try {
  const src=fs.readFileSync(path.join(root,'examples/printers.fpr'),'utf8');
  assert.doesNotMatch(src,/cameraScript\s*=\s*"|cssText|G\.Prop|\bCls\b/);
  assert.doesNotMatch(fs.readFileSync(path.join(root,'examples/printer-dashboard/presentation.fpr'),'utf8'),/G\.Prop|G\.Style|cssText/);
  assert.doesNotMatch(fs.readFileSync(path.join(root,'std/javascript.fpr'),'utf8'),/\|\s*Raw\b/);
  const sample=path.join(tmp,'printers.fpr');
  fs.writeFileSync(sample,src.replace(/^main =/m,'applicationMain =')+'\n'+fs.readFileSync(path.join(root,'tests/printerstyles.fprinc'),'utf8'));
  const bin=path.join(tmp,'sample');
  execFileSync(path.join(root,'fpr'),['build',sample,'-o',bin],{cwd:root,env:{...process.env,FPR_HOME:root,XDG_CACHE_HOME: process.env.XDG_CACHE_HOME || path.join(tmp,'cache')},timeout:180000,stdio:'pipe'});
  browser=await chromium.launch({headless:true,...(process.env.CHROME_BIN?{executablePath:process.env.CHROME_BIN}:{})});
  const syntax=path.join(tmp,'syntax');
  execFileSync(path.join(root,'fpr'),['build','tests/std/javascript.fpr','-o',syntax],{cwd:root,env:{...process.env,FPR_HOME:root,XDG_CACHE_HOME: process.env.XDG_CACHE_HOME || path.join(tmp,'cache')},timeout:180000,stdio:'pipe'});
  for(const flag of ['bad-name','reserved','bad-assignment']) {
    const result=spawnSync(syntax,[flag],{encoding:'utf8',timeout:10000});
    assert.equal(result.status,1);assert.match(result.stdout+result.stderr,/JavaScript: invalid/);
  }
  const syntaxPage=await browser.newPage();
  await syntaxPage.addScriptTag({content:execFileSync(syntax,['page'],{encoding:'utf8'})});
  assert.deepEqual(await syntaxPage.evaluate(()=>[window.generated.sum,Object.hasOwn(window.generated,'__proto__'),window.generated.__proto__,!!window.injected]),[6,true,'data',false]);
  assert.equal(await syntaxPage.evaluate(()=>window.generated.text),'</script><script>window.injected=true</script>\u2028');
  await syntaxPage.close();
  const page=await browser.newPage();
  let requests=0,failMedia=false;
  await page.route('**/camera/**',async route=>{requests++;
    if(failMedia){await route.abort('connectionreset');return;}
    await route.fulfill({contentType:'image/png',body:Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a1ioAAAAASUVORK5CYII=','base64')});});
  for (const harts of [1,4]) {
   const v=JSON.parse(execFileSync(bin,{encoding:'utf8',env:{...process.env,FPR_HARTS:String(harts)}}));
   // Execute the actual generated session checker: transient failures retain
   // the page/cookie; only a confirmed 401 returns the user to key login.
   let checkSession,status=503,redirects=0;
   vm.runInNewContext(v.session,{document:{hidden:false,addEventListener(){}},
     setInterval(fn){checkSession=fn;},fetch:async()=>{if(status===0)throw Error('offline');return {status};},
     location:{replace(){redirects++;}}});
   await new Promise(resolve=>setImmediate(resolve));
   assert.equal(redirects,0);
   for(status of [0,503,200]){await checkSession();assert.equal(redirects,0);}
   status=401;await checkSession();assert.equal(redirects,1);
   const markup=v.s.map((s,i)=>s+(i<v.d.length?'<span data-slot="'+i+'"></span>':'')).join('');
   await page.setContent('<!doctype html><head><style>'+v.css+'</style></head><body'+v.body+'><div id="lv-root">'+markup+'</div></body>');
   await page.locator('[data-slot]').evaluateAll((els,ds)=>{for(const e of els)e.textContent=ds[Number(e.dataset.slot)];},v.d);
   const selectors=await page.evaluate(()=>Array.from(document.styleSheets).flatMap(s=>Array.from(s.cssRules)).flatMap(r=>r.type===4?Array.from(r.cssRules):[r]).map(r=>r.selectorText));
   assert(selectors.length>100);
   assert(selectors.every(s=>/^\.fpr-u-[0-5]-[0-9a-f]+(?::focus-visible)?$/.test(s)),selectors.filter(s=>!/^\.fpr-u-/.test(s)));
   assert.equal(await page.locator('article > dl dd').nth(0).innerText(),'220°C');
   assert.equal(await page.locator('article > dl dd').nth(1).innerText(),'60°C');
   assert.equal(await page.locator('article > dl dd').nth(2).innerText(),'0.3Hz');
   for(const width of [1200,390,375,320]) {
    await page.setViewportSize({width,height:900});
    assert.equal(await page.locator('body').evaluate(e=>getComputedStyle(e).margin),'0px');
    assert.equal(await page.locator('body').evaluate(e=>e.scrollWidth),width,'no horizontal document overflow');
    assert.equal(await page.locator('h1').evaluate(e=>getComputedStyle(e).fontSize),width===1200?'48px':'38px');
    assert.equal(await page.locator('[aria-label="Printers"]').evaluate(e=>getComputedStyle(e).gridTemplateColumns.split(' ').length),width===1200?2:1);
    assert.equal(await page.locator('article').evaluate(e=>getComputedStyle(e).padding),width===1200?'26px':'22px');
    assert(await page.locator('article > dl').evaluate(dl=>{
      const cells=Array.from(dl.children).map(e=>e.getBoundingClientRect());
      return Array.from(dl.querySelectorAll('dd')).every((dd,i)=>{
        const box=dd.getBoundingClientRect();
        const range=document.createRange();range.selectNodeContents(dd);
        return Array.from(range.getClientRects()).every(r=>r.left>=box.left-.5 && r.right<=cells[i].right+.5);
      });
    }),'metric text and units stay inside their own grid column');
    const ratio=await page.locator('[role="progressbar"]').evaluate(e=>e.firstChild.getBoundingClientRect().width/e.getBoundingClientRect().width);
    assert(Math.abs(ratio-.37)<.003);
    const camera=await page.locator('[data-camera-id]').boundingBox();
    assert(Math.abs(camera.width/camera.height-16/9)<.01);
   }
   await page.locator('button').first().focus();
   assert.equal(await page.locator('button').first().evaluate(e=>getComputedStyle(e).outlineWidth),'3px');
   assert.equal(await page.locator('[role="switch"] > span').count(),1);
   assert.equal(await page.locator('[aria-label="Printer alerts"]').count(),1);
   assert.equal(await page.locator('[aria-label="Printer alerts"] li').count(),2);
   assert.match(await page.locator('[aria-label="Printer alerts"]').innerText(),/Filament runout reported/);
   assert.match(await page.locator('[aria-label="Printer alerts"]').innerText(),/FFFFFFFF00000001/);
   assert.match(await page.locator('[aria-label="Printer alerts"]').innerText(),/Print paused/);
   assert.equal(await page.locator('[aria-label="Printer alerts"] a').first().getAttribute('rel'),'noopener noreferrer');
   // A conflicting element-local rule cannot affect a sibling component.
   await page.locator('article').evaluate(e=>{e.style.color='rgb(200, 0, 0)';});
   assert.equal(await page.locator('h1').evaluate(e=>getComputedStyle(e).color),'rgb(38, 51, 46)');
   await page.evaluate(()=>{const base=document.createElement('base');base.href='http://media.test/';document.head.append(base);});
   let start=requests;
   await page.addScriptTag({content:v.media});
   const host=page.locator('[data-camera-id]');
   await page.waitForFunction(()=>document.querySelector('[data-camera-status]').textContent.includes('Camera connected'));
   assert.equal(requests,start+1);
   assert.equal(await host.locator('img').evaluate(e=>getComputedStyle(e).objectFit),'contain');
   assert.equal(await host.locator('img').evaluate(e=>e.style.cssText),'');
   // Telemetry morphing the light DOM must preserve the media-owned shadow.
   await page.locator('article h2').evaluate(e=>{e.textContent='Fresh telemetry';});
   await page.waitForTimeout(40);
   assert.equal(requests,start+1);
   await page.locator('#lv-link').evaluate(e=>{e.textContent='offline';});
   await page.waitForFunction(()=>!document.querySelector('[data-camera-id]').shadowRoot.querySelector('img').hasAttribute('src'));
   await page.locator('#lv-link').evaluate(e=>{e.textContent='live';});
   await page.waitForFunction(()=>document.querySelector('[data-camera-status]').textContent.includes('Camera connected'));
   assert.equal(requests,start+2);
   await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,value:true});document.dispatchEvent(new Event('visibilitychange'));});
   await page.waitForFunction(()=>document.querySelector('[data-camera-status]').textContent.includes('Camera paused'));
   assert.equal(await host.locator('img').getAttribute('src'),null);
   await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,value:false});document.dispatchEvent(new Event('visibilitychange'));});
   await page.waitForFunction(()=>document.querySelector('[data-camera-status]').textContent.includes('Camera connected'));
   assert.equal(requests,start+3);
   await host.locator('img').evaluate(e=>e.dispatchEvent(new Event('error')));
   await page.waitForFunction(()=>document.querySelector('[data-camera-status]').textContent.includes('reconnecting'));
   await page.waitForFunction(()=>document.querySelector('[data-camera-status]').textContent.includes('Camera connected'));
   assert.equal(requests,start+4,'native stream reconnects without an off/on toggle');
   // Accelerate only retry timers while checking the generated backoff values.
   // The actual request fails, so every error goes through the image event path.
   const beforeBackoff=requests;
   await page.evaluate(()=>{window.mediaRetryDelays=[];window.mediaSetTimeout=window.setTimeout;
    window.setTimeout=(fn,ms,...args)=>{if(ms>=1000&&ms<=10000){window.mediaRetryDelays.push(ms);return window.mediaSetTimeout(fn,20,...args);}return window.mediaSetTimeout(fn,ms,...args);};});
   failMedia=true;
   await host.locator('img').evaluate(e=>e.dispatchEvent(new Event('error')));
   await page.waitForFunction(()=>window.mediaRetryDelays.length>=6);
   assert.deepEqual(await page.evaluate(()=>window.mediaRetryDelays.slice(0,6)),[1000,2000,4000,8000,10000,10000]);
   failMedia=false;
   await page.waitForFunction(()=>document.querySelector('[data-camera-status]').textContent.includes('Camera connected'));
   const resetAt=await page.evaluate(()=>window.mediaRetryDelays.length);
   await host.locator('img').evaluate(e=>e.dispatchEvent(new Event('error')));
   await page.waitForFunction(n=>window.mediaRetryDelays.length>n,resetAt);
   assert.equal(await page.evaluate(n=>window.mediaRetryDelays[n],resetAt),1000,'successful frame resets retry delay');
   await page.waitForFunction(()=>document.querySelector('[data-camera-status]').textContent.includes('Camera connected'));
   await page.evaluate(()=>{window.setTimeout=window.mediaSetTimeout;});
   start+=requests-beforeBackoff;
   // Off cancels a pending native retry as well as releasing the stream.
   await host.locator('img').evaluate(e=>e.dispatchEvent(new Event('error')));
   await host.evaluate(e=>e.setAttribute('data-camera-on','false'));
   await page.waitForFunction(()=>document.querySelector('[data-camera-status]').textContent==='Camera is off');
   await page.waitForTimeout(1200);
   assert.equal(requests,start+4,'off cancels pending native retry');
   await host.evaluate(e=>e.setAttribute('data-camera-on','true'));
   await page.waitForFunction(()=>document.querySelector('[data-camera-status]').textContent.includes('Camera connected'));
   start++;
   await page.evaluate(()=>window.dispatchEvent(new PageTransitionEvent('pagehide',{persisted:true})));
   assert.equal(await host.locator('img').getAttribute('src'),null);
   await page.evaluate(()=>window.dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true})));
   await page.waitForFunction(()=>document.querySelector('[data-camera-status]').textContent.includes('Camera connected'));
   assert.equal(requests,start+5);
   // Detaching a host releases it and a replacement gets fresh shadow ownership.
   await host.evaluate(e=>{const replacement=e.cloneNode();e.replaceWith(replacement);});
   await page.waitForFunction(()=>document.querySelector('[data-camera-id]').shadowRoot?.querySelector('img').hasAttribute('src'));
   assert.equal(requests,start+6);
   // Snapshot previews recover once per ten seconds. Switching off or hiding
   // the page cancels even a pending retry; native backoff was checked above.
   await host.evaluate(e=>e.setAttribute('data-camera-mode','snapshot'));
   await host.locator('img').evaluate(e=>e.dispatchEvent(new Event('error')));
   await page.waitForFunction(()=>document.querySelector('[data-camera-status]').textContent.includes('retrying in 10s'));
   await page.waitForFunction(()=>document.querySelector('[data-camera-status]').textContent.includes('Snapshot preview'),{},{timeout:15000});
   assert.equal(requests,start+7,'snapshot recovery reconnects once');
   await host.locator('img').evaluate(e=>e.dispatchEvent(new Event('error')));
   await host.evaluate(e=>e.setAttribute('data-camera-on','false'));
   await page.waitForFunction(()=>document.querySelector('[data-camera-status]').textContent==='Camera is off');
   await page.waitForTimeout(10200);
   assert.equal(requests,start+7,'off cancels pending snapshot retry');
   await host.evaluate(e=>e.setAttribute('data-camera-on','true'));
   await page.waitForFunction(()=>document.querySelector('[data-camera-status]').textContent.includes('Snapshot preview'));
   await host.locator('img').evaluate(e=>e.dispatchEvent(new Event('error')));
   await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,value:true});document.dispatchEvent(new Event('visibilitychange'));});
   await page.waitForFunction(()=>!document.querySelector('[data-camera-id]').shadowRoot.querySelector('img').hasAttribute('src'));
   await page.waitForTimeout(10200);
   assert.equal(requests,start+8,'hidden page cancels pending snapshot retry');
   await page.evaluate(()=>window.dispatchEvent(new PageTransitionEvent('pagehide')));
   assert.equal(await host.locator('img').getAttribute('src'),null);
   await page.goto('about:blank');

  }
  const application=path.join(tmp,'application');
  execFileSync(path.join(root,'fpr'),['build','examples/printers.fpr','-o',application],{cwd:root,env:{...process.env,FPR_HOME:root,XDG_CACHE_HOME: process.env.XDG_CACHE_HOME || path.join(tmp,'cache')},timeout:180000,stdio:'pipe'});
  for(const harts of [1,4]) {
   const status=path.join(tmp,'status-'+harts+'.json');
   const snapshot={schema:1,generated_at:Math.floor(Date.now()/1000),printers:[{id:'native-test',name:'Native test',model:'P1S',location:'test',connection:'ONLINE',state:'Printing',progress:12,camera_available:true}]};
   fs.writeFileSync(status,JSON.stringify(snapshot));
   const child=spawn(application,['--port=0','--poll-ms=250','--status='+status,'--store='+path.join(tmp,'store-'+harts)],{cwd:root,env:{...process.env,FPR_HOME:root,FPR_HARTS:String(harts)},stdio:['ignore','ignore','pipe']});
   children.push(child);
   const url=await new Promise((resolve,reject)=>{let log='';const timer=setTimeout(()=>reject(new Error('native startup timeout: '+log)),15000);
     child.stderr.on('data',data=>{log+=data;const match=log.match(/live: (http:\/\/127\.0\.0\.1:\d+)/);if(match){clearTimeout(timer);resolve(match[1]);}});
     child.once('error',reject);child.once('exit',code=>{clearTimeout(timer);reject(new Error('native exited '+code+': '+log));});});
   const live=await browser.newPage();let pulls=0;
   await live.route('**/camera/**',async route=>{pulls++;await route.fulfill({contentType:'image/png',body:Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a1ioAAAAASUVORK5CYII=','base64')});});
   await live.goto(url);
   await live.locator('[role="switch"]').click();
   await live.waitForFunction(()=>document.querySelector('[data-camera-status]').textContent.includes('Camera connected'));
   assert.equal(pulls,1);
   await live.locator('[data-camera-id] img').evaluate(e=>{window.originalImage=e;});
   snapshot.printers[0].progress=64;snapshot.printers[0].state='Fresh native telemetry';snapshot.generated_at=Math.floor(Date.now()/1000);
   fs.writeFileSync(status,JSON.stringify(snapshot));
   await live.waitForFunction(()=>document.querySelector('[role="progressbar"]').getAttribute('aria-valuenow')==='64');
   assert.equal(await live.locator('[data-camera-id] img').evaluate(e=>e===window.originalImage),true,'Live morph preserves shadow image');
   assert.equal(pulls,1,'a progress update must not reconnect the stream');
   const ratio=await live.locator('[role="progressbar"]').evaluate(e=>e.firstChild.getBoundingClientRect().width/e.getBoundingClientRect().width);
   assert(Math.abs(ratio-.64)<.003,'dynamic progress utility travels with Live morph');
   await live.getByRole('button',{name:/Hide details/}).click();
   await live.waitForFunction(()=>!document.querySelector('[data-camera-id]').shadowRoot.querySelector('img').hasAttribute('src'));
   await live.close();
   const exited=new Promise(resolve=>child.once('exit',resolve));child.kill('SIGTERM');await exited;
  }
  console.log('PASS actual native Live printer: generated body/media, per-tab camera, dynamic progress CSS, stable shadow/stream through telemetry and collapse cleanup; 1/4 harts');
  console.log('PASS printer presentation: generated local rules only, document ownership, wide/narrow layout, progress, camera geometry, keyboard focus, component isolation and generated media lifecycle (visibility, disconnect, failure, toggle, BFCache, detach); 1/4 harts');
 } finally {for(const child of children)if(child.exitCode===null&&child.signalCode===null)child.kill('SIGTERM');if(browser)await browser.close();fs.rmSync(tmp,{recursive:true,force:true});}
})().catch(e=>{if(e.stdout)console.error(e.stdout.toString());if(e.stderr)console.error(e.stderr.toString());console.error(e);process.exitCode=1;});
