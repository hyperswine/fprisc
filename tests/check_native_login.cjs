#!/usr/bin/env node
// Actual generated login/session UI against the native host; synthetic key only.
const {chromium}=require('playwright');
const {generateKeyPairSync}=require('node:crypto');
const {spawn}=require('node:child_process');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..'),binary=process.argv[2];
if(!binary)throw Error('supply native printer-host binary');
const tmp=fs.mkdtempSync(path.join(os.tmpdir(),'fpr-native-login-'));
(async()=>{
 let browser;
 const children=[];
 try {
  const {privateKey,publicKey}=generateKeyPairSync('ed25519');
  const pem=privateKey.export({format:'pem',type:'pkcs8'}).toString();
  const jwk=publicKey.export({format:'jwk'});
  const allow=path.join(tmp,'auth.json');
  fs.writeFileSync(allow,JSON.stringify([{name:'Synthetic browser test',algorithm:'Ed25519',public_key:Buffer.from(jwk.x,'base64url').toString('hex')}]));
  browser=await chromium.launch({headless:true,...(process.env.CHROME_BIN?{executablePath:process.env.CHROME_BIN}:{})});
  for(const harts of [1,4]) {
   const child=spawn(binary,['--demo','--port=0','--auth='+allow,'--store='+path.join(tmp,'store-'+harts)],{cwd:root,env:{...process.env,FPR_HARTS:String(harts),PATH:'/nonexistent'},stdio:['ignore','pipe','pipe']});children.push(child);
   const port=await new Promise((resolve,reject)=>{let out='',err='';const timer=setTimeout(()=>reject(new Error('native startup timeout: '+err)),20000);
    child.stdout.on('data',data=>{out+=data;const m=out.match(/gateway-ready (\d+)/);if(m){clearTimeout(timer);resolve(Number(m[1]));}});
    child.stderr.on('data',data=>err+=data);child.once('exit',code=>{clearTimeout(timer);reject(new Error('native exit '+code+': '+err));});});
   const page=await browser.newPage({viewport:{width:390,height:844}}),errors=[];
   page.on('pageerror',e=>errors.push(e.message));
   page.on('request',req=>{const body=req.postData()||'';assert(!body.includes('BEGIN PRIVATE KEY')&&!body.includes(pem),'private material sent over network');});
   const url='http://localhost:'+port;
   await page.goto(url);
   const field=page.locator('#private-key');
   assert.equal(await field.evaluate(e=>getComputedStyle(e).webkitTextSecurity),'disc');
   assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
   await field.fill('invalid');await page.getByRole('button',{name:'Sign in',exact:true}).click();
   await page.waitForFunction(()=>document.querySelector('#message').textContent.includes('Ed25519 PKCS'));
   assert.equal(await field.inputValue(),'');
   await field.fill(pem);await page.getByRole('button',{name:'Sign in',exact:true}).click();
   await page.getByRole('heading',{name:'Print room',exact:true}).waitFor();
   assert.equal(await page.evaluate(async()=>{const r=await fetch('/api/status');return r.status;}),200);
   const socketBefore=await page.evaluate(()=>WebSocket.prototype.send);
   await page.getByRole('button',{name:'Sign out',exact:true}).click();
   await page.getByRole('heading',{name:'Sign in to Print room'}).waitFor();
   assert.equal(await page.evaluate(async()=>{const r=await fetch('/api/status');return r.status;}),401);
   assert.equal(await page.evaluate(()=>Object.keys(localStorage).length),0);
   assert.deepEqual(errors,[]);
   await page.close();
   const exited=new Promise(resolve=>child.once('exit',resolve));child.kill('SIGTERM');await exited;
  }
  console.log('PASS generated native login/session: masked local field, invalid-key clearing, WebCrypto proof, authenticated view/status, sign-out/revocation, no key persistence or transmission; 1/4 harts');
 }finally{for(const c of children)if(c.exitCode===null&&c.signalCode===null)c.kill('SIGTERM');if(browser)await browser.close();fs.rmSync(tmp,{recursive:true,force:true});}
})().catch(e=>{console.error(e);process.exitCode=1;});
