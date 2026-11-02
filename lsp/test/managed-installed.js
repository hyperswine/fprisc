#!/usr/bin/env node
'use strict';
// Optional installed-package acceptance. Requires isolated stores containing
// FP-RISC 0.12.0/0.13.0 and QOS 0.3.0, and manager 0.2.0 on PATH.
const assert = require('assert/strict');
const fs = require('fs'), path = require('path'), os = require('os');
const { spawn } = require('child_process');
const { pathToFileURL } = require('url');
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function until(test,label){const end=Date.now()+20000;while(!test()){if(Date.now()>end)throw Error(label);await sleep(40);}}
(async()=>{
  if(!process.env.FPRMETA_HOME||!process.env.QOSMETA_HOME)throw Error('Set isolated FPRMETA_HOME and QOSMETA_HOME first');
  const dir=fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'fpr-installed-editor-'))),pending=new Map(),diags=new Map(),states=new Map();
  let server,id=0,wire=Buffer.alloc(0),err='';
  const settingsFile=path.join(process.env.FPRMETA_HOME,'settings.toml'), originalSettings=fs.readFileSync(settingsFile);
  const put=(name,text)=>{const f=path.join(dir,name);fs.mkdirSync(path.dirname(f),{recursive:true});fs.writeFileSync(f,text);return f;};
  const uri=file=>pathToFileURL(file).href;
  try{
    const a=put('a/src/main.fpr','S = use "std/string".\nmain = print (S.trim " a ").\n');
    const b=put('b/src/main.fpr','S = use "std/string".\nmain = print (S.trim " b ").\n');
    put('a/fpr.toml','[toolchain] # managed compiler\nfpr = "=0.12.0"\n');put('b/fpr.toml','[toolchain]\nfpr = "=0.13.0"\n');
    const q=put('q/main.fpr','unsafe module.\nD = use "qos/desktop".\ntext viewport = D.text viewport "Title" "Subtitle" Nil.\n');
    put('q/qos.toml','[sdk] # managed SDK\nversion = "=0.3.0"\n');
    const loose=put('loose/main.fpr','S = use \"std/string\".\nmain = print (S.trim \" value \").\n');
    const env={...process.env};delete env.FPR_HOME;delete env.FPR_TOOLCHAIN;delete env.QOS_SDK;
    server=spawn(process.execPath,[path.join(__dirname,'../server/server.js')],{env,stdio:['pipe','pipe','pipe']});
    server.stderr.on('data',c=>err+=c);
    server.stdout.on('data',chunk=>{
      wire=Buffer.concat([wire,chunk]);for(;;){const end=wire.indexOf('\r\n\r\n');if(end<0)return;
        const size=+/Content-Length:\s*(\d+)/i.exec(wire.subarray(0,end).toString())[1];if(wire.length<end+4+size)return;
        const m=JSON.parse(wire.subarray(end+4,end+4+size));wire=wire.subarray(end+4+size);
        if(m.id!==undefined&&pending.has(m.id)){pending.get(m.id)(m);pending.delete(m.id);}
        if(m.method==='textDocument/publishDiagnostics'){diags.set(m.params.uri,m.params.diagnostics);states.set(m.params.uri,(states.get(m.params.uri)||0)+1);}
      }
    });
    const send=m=>{const b=Buffer.from(JSON.stringify(m));server.stdin.write(`Content-Length: ${b.length}\r\n\r\n`);server.stdin.write(b);};
    const notify=(method,params)=>send({jsonrpc:'2.0',method,params});
    const request=(method,params)=>new Promise((resolve,reject)=>{const n=++id,timer=setTimeout(()=>reject(Error(method+' timed out: '+err)),22000);pending.set(n,m=>{clearTimeout(timer);m.error?reject(Error(m.error.message)):resolve(m.result);});send({jsonrpc:'2.0',id:n,method,params});});
    await request('initialize',{rootUri:uri(dir),initializationOptions:{check:true,home:'',compilerPath:'',modulePaths:[],checkArgs:[],unresolvedNames:false}});
    const open=file=>notify('textDocument/didOpen',{textDocument:{uri:uri(file),languageId:'fpr',version:1,text:fs.readFileSync(file,'utf8')}});
    for(const f of [a,b,q,loose])open(f);
    const sa=await request('fpr/toolchain',{uri:uri(a)}),sb=await request('fpr/toolchain',{uri:uri(b)}),sq=await request('fpr/toolchain',{uri:uri(q)});
    assert.equal(sa.selection.version,'0.12.0');assert.equal(sb.selection.version,'0.13.0');assert.equal(sq.selection.version,'0.3.0');
    assert(sq.compiler.includes('compiler/fpr'));assert(sq.moduleHome.endsWith('/modules'));
    const definition=async(file,line,character)=>(await request('textDocument/definition',{textDocument:{uri:uri(file)},position:{line,character}}));
    const da=await definition(a,1,17),db=await definition(b,1,17),dq=await definition(q,2,19);
    const first=r=>Array.isArray(r)?r[0]:r;
    assert(first(da)?.uri.includes('/0.12.0/'),'A navigates to its own installed std: '+JSON.stringify(da));
    assert(first(db)?.uri.includes('/0.13.0/'),'B navigates to its own installed std: '+JSON.stringify(db));
    assert(first(dq)?.uri.includes('/0.3.0/'),'QOS navigates to its own SDK: '+JSON.stringify(dq));
    await until(()=>[a,b,q].every(f=>(states.get(uri(f))||0)>=3),'initial managed checks complete');
    await sleep(700);
    for(const file of [a,b,q])assert.deepEqual((diags.get(uri(file))||[]).filter(d=>d.severity===1),[],file+' compiler diagnostics');
    fs.appendFileSync(q,'broken = packaging_qos_missing.\n');
    notify('textDocument/didChange',{textDocument:{uri:uri(q),version:2},contentChanges:[{text:fs.readFileSync(q,'utf8')}]});notify('textDocument/didSave',{textDocument:{uri:uri(q)}});
    await until(()=>(diags.get(uri(q))||[]).some(d=>d.message.includes('packaging_qos_missing')),'SDK private compiler diagnostic');
    const marker='packaging_missing_name';fs.appendFileSync(b,`broken = ${marker}.\n`);
    notify('textDocument/didChange',{textDocument:{uri:uri(b),version:2},contentChanges:[{text:fs.readFileSync(b,'utf8')}]});notify('textDocument/didSave',{textDocument:{uri:uri(b)}});
    await until(()=>(diags.get(uri(b))||[]).some(d=>d.message.includes(marker)),'packaged compiler diagnostic');
    const pin=path.join(dir,'b/fpr.toml');fs.writeFileSync(pin,'[toolchain]\nfpr = "=9.9.9"\n');
    notify('workspace/didChangeWatchedFiles',{changes:[{uri:uri(pin),type:2}]});
    await until(()=>(diags.get(uri(b))||[]).some(d=>d.code==='toolchain-selection'&&d.message.includes('fprmeta install 9.9.9')),'missing pin actionable diagnostic');
    const before=states.get(uri(loose))||0;
    fs.writeFileSync(settingsFile,'[toolchain]\ndefault = "0.12.0"\n');
    await until(()=>(states.get(uri(loose))||0)>before,'external default change triggers automatic recheck');
    assert.equal((await request('fpr/toolchain',{uri:uri(loose)})).selection.version,'0.12.0');
    assert(first(await definition(loose,1,17))?.uri.includes('/0.12.0/'),'navigation follows changed external default');
    await request('shutdown',null);notify('exit',null);await new Promise(r=>server.once('exit',r));
    console.log('installed managed LSP: two FP-RISC releases, QOS private compiler/modules, per-project navigation, real diagnostics, pin invalidation and missing-version install hint PASS');
  }finally{
    if(server&&server.exitCode===null){server.stdin.end();await sleep(150);if(server.exitCode===null)server.kill();}
    fs.writeFileSync(settingsFile,originalSettings);
    fs.rmSync(dir,{recursive:true,force:true});
  }
})().catch(e=>{console.error(e);process.exitCode=1;});
