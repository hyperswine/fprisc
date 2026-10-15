#!/usr/bin/env node
// Explicit live-device acceptance. Key contents and camera pixels stay local to
// this driver/browser and are never printed, captured in traces or saved.
const {chromium}=require('playwright');
const fs=require('node:fs');
const assert=require('node:assert/strict');
const [origin,keyFile,output]=process.argv.slice(2);
if(!origin?.startsWith('https://')||!keyFile||!output)throw Error('usage: check_printer_public_browser.cjs HTTPS_ORIGIN KEY_FILE OUTPUT_JSON');
let phase='launch';
(async()=>{
 let browser,page;
 try {
  browser=await chromium.launch({headless:true,...(process.env.CHROME_BIN?{executablePath:process.env.CHROME_BIN}:{})});
  page=await browser.newPage({viewport:{width:1300,height:1000}});
  const errors=[],sockets=[];let leaked=false,resolveWire;
  const wireReady=new Promise(resolve=>{resolveWire=resolve;});
  page.on('pageerror',()=>errors.push(true));
  page.on('websocket',socket=>{sockets.push(socket.url());socket.once('framereceived',()=>resolveWire());});
  page.on('request',request=>{if((request.postData()||'').includes('BEGIN PRIVATE KEY'))leaked=true;});
  phase='public login';await page.goto(origin);
  const field=page.locator('#private-key');
  assert.equal(await field.evaluate(e=>getComputedStyle(e).webkitTextSecurity),'disc');
  // Do not use fill(key): a failed Playwright call can include its input in logs.
  await field.evaluate((element,key)=>{element.value=key;element.dispatchEvent(new Event('input',{bubbles:true}));},fs.readFileSync(keyFile,'utf8'));
  await page.getByRole('button',{name:'Sign in',exact:true}).click();
  await page.getByRole('heading',{name:'Print room',exact:true}).waitFor();
  // The initial HTML paints before the channel is ready to accept controls.
  phase='initial public WSS snapshot';
  await new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('WSS snapshot timeout')),30000);
   wireReady.then(()=>{clearTimeout(timer);resolve();});});
  assert(sockets.some(url=>url.startsWith(origin.replace('https://','wss://')+'/ws')));
  phase='real camera decoding';
  const dimensions={};
  for(const [id,name] of [['a1','Bambu A1'],['p1s','Bambu P1S']]) {
   phase=id+' camera switch';
   const card=page.locator('article').filter({has:page.getByRole('heading',{name,exact:true})});
   await card.getByRole('switch').click();
   phase=id+' camera decode';
   try {
    await page.waitForFunction(id=>{
     const image=document.querySelector('[data-camera-id="'+id+'"]')?.shadowRoot?.querySelector('img');
     return image?.naturalWidth>0&&image?.naturalHeight>0;
    },id,{timeout:25000});
   } catch {
    const diagnostic=await page.evaluate(id=>{
     const host=document.querySelector('[data-camera-id="'+id+'"]'),image=host?.shadowRoot?.querySelector('img');
     return {id,hidden:document.hidden,live:document.getElementById('lv-link')?.textContent==='live',
      selected:host?.getAttribute('data-camera-on'),shadow:!!host?.shadowRoot,image:!!image,
      source:!!image?.getAttribute('src'),complete:image?.complete,width:image?.naturalWidth};
    },id);
    console.log(JSON.stringify(diagnostic));throw Error('camera decode failed');
   }
   dimensions[id]=await card.locator('img').evaluate(e=>({width:e.naturalWidth,height:e.naturalHeight}));
  }
  phase='public responsive view';
  for(const width of [1300,390]) {
   await page.setViewportSize({width,height:1000});
   assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
  }
  phase='public sign out';
  await page.getByRole('button',{name:'Sign out',exact:true}).click();
  await page.getByRole('heading',{name:'Sign in to Print room',exact:true}).waitFor();
  assert.equal(await page.evaluate(async()=> (await fetch('/api/status')).status),401);
  assert.equal(await page.evaluate(()=>Object.keys(localStorage).length),0);
  assert.equal(leaked,false);assert.deepEqual(errors,[]);
  const evidence={origin,checked_at:Math.floor(Date.now()/1000),generated_login:true,public_wss:true,
   decoded_real_cameras:dimensions,responsive_widths:[1300,390],sign_out:true,no_key_persistence_or_transmission:true};
  fs.writeFileSync(output,JSON.stringify(evidence,null,2)+'\n');
  console.log(JSON.stringify(evidence,null,2));
 } finally {
  if(page&&!page.isClosed())await page.evaluate(async()=>{try{await fetch('/auth/logout',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});}catch{}}).catch(()=>{});
  if(browser)await browser.close();
 }
})().catch(()=>{console.error('Public browser acceptance failed at: '+phase);process.exitCode=1;});
