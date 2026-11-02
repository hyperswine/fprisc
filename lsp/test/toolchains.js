#!/usr/bin/env node
'use strict';
const assert = require('assert/strict');
const fs = require('fs'), os = require('os'), path = require('path');
const { compilerContext, createChecker, projectRoot } = require('../server/compiler-check');
const { snapshot } = require('../server/check-inputs');
const toolchains = require('../server/toolchains');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(test, label) { const end = Date.now()+6000; while (!test()) { if (Date.now()>end) throw Error(label); await sleep(10); } }
(async () => {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'fpr-managed-editor-')));
  const saved = { ...process.env }, checkers = [];
  const put = (name, text) => { const file=path.join(root,name);fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,text);return file; };
  const executable = (name,text) => {const file=put(name,`#!${process.execPath}\n${text}`);fs.chmodSync(file,0o755);return file;};
  try {
    delete process.env.FPR_HOME; delete process.env.FPR_TOOLCHAIN; delete process.env.QOS_SDK;
    process.env.FPRMETA_HOME=path.join(root,'fpr store');process.env.QOSMETA_HOME=path.join(root,'qos store');
    const settings = put('fpr store/settings.toml', 'a'); put('qos store/settings.toml','q');
    const calls=put('calls',''), builds=put('builds','');
    const descriptor = (name,kind='fpr') => {
      const home=path.join(root,name,'modules');
      put(name+'/modules/core/prelude.fpr','# prelude\n');put(name+'/modules/std/versioned.fpr',`# ${name}\nvalue : Int.\nvalue = 1.\n`);
      const compiler=executable(name+'/compiler/fpr',`require('fs').appendFileSync(${JSON.stringify(builds)},JSON.stringify({home:process.env.FPR_HOME,args:process.argv.slice(2)})+'\\n');setTimeout(()=>{},80);`);
      const metadata=put(name+'/metadata.json','{}');
      return {format:1,component:kind==='qos'?'qos-portable':'fprisc',version:name,binary:compiler,compiler,moduleHome:home,
        modulePaths:kind==='qos'?[path.dirname(compiler)]:[],foreign:kind==='qos'?put(name+'/modules/core/foreign.fpr','# foreign\n'):'',
        checkArgs:kind==='qos'?['--target=qa64','--prelude='+path.join(home,'core/prelude.fpr')]:['--system=posix'],metadata,source:'project pin'};
    };
    const a=descriptor('a'),b=descriptor('b'),q=descriptor('q','qos');
    const db=put('selections.json',JSON.stringify({a,b,q}));
    const proxy=executable('bin/fprmeta',`const fs=require('fs'),path=require('path');fs.appendFileSync(${JSON.stringify(calls)},'query\\n');
const qos=path.basename(process.argv[1])==='qosmeta',cwd=process.cwd();
const marker=path.join(cwd,qos?'qos.toml':'fpr.toml');
const choice=fs.existsSync(marker)?fs.readFileSync(marker,'utf8').trim():fs.readFileSync(path.join(process.env[qos?'QOSMETA_HOME':'FPRMETA_HOME'],'settings.toml'),'utf8').trim();
if(choice==='missing'){console.error('pin not installed; fprmeta install 9.9.9');process.exit(2);}
if(choice==='legacy'){console.log('old which output');process.exit(0);}
console.log(JSON.stringify(JSON.parse(fs.readFileSync(${JSON.stringify(db)},'utf8'))[choice]));`);
    fs.copyFileSync(proxy,path.join(root,'bin/qosmeta'));fs.chmodSync(path.join(root,'bin/qosmeta'),0o755);
    fs.symlinkSync('fprmeta',path.join(root,'bin/fpr'));process.env.PATH=path.join(root,'bin');
    const mainA=put('project-a/src/main.fpr','M = use "std/versioned".\nmain = M.value.\n');put('project-a/fpr.toml','a');
    const mainB=put('project-b/main.fpr','main = 1.\n');put('project-b/fpr.toml','b');
    const mainQ=put('project-q/src/main.fpr','main = 1.\n');put('project-q/qos.toml','q');
    const loose=put('loose/main.fpr','main = 1.\n');
    const context=file=>compilerContext(file,{},projectRoot(file,root));
    assert.equal(context(mainA).compiler,a.compiler);assert.equal(context(mainB).home,b.moduleHome);
    const count=fs.readFileSync(calls,'utf8');for(let i=0;i<20;i++)context(mainA);
    assert.equal(fs.readFileSync(calls,'utf8'),count,'cached navigation does not spawn a manager per request');
    assert.equal(projectRoot(mainQ,root),path.join(root,'project-q'));
    process.env.FPR_PATH='/unrelated/library';process.env.FPR_FOREIGN='/unrelated/foreign.fpr';
    let sdk=context(mainQ);assert.equal(sdk.compiler,q.compiler);assert.equal(sdk.env.FPR_HOME,q.moduleHome);
    assert.equal(sdk.env.FPR_FOREIGN,q.foreign);assert(!sdk.env.FPR_PATH.includes('/unrelated'));
    assert(sdk.settings.checkArgs.includes('--target=qa64'));
    delete process.env.FPR_PATH;delete process.env.FPR_FOREIGN;
    assert.equal(compilerContext(mainQ,{compilerPath:b.compiler}).compiler,b.compiler,'explicit compiler overrides SDK discovery');
    assert.equal(compilerContext(mainQ,{home:a.moduleHome,compilerPath:a.compiler}).home,a.moduleHome);
    const sol=put('project-q/script.sol','> print 1.\n');assert.equal(context(sol).selected.component,'fprisc');
    assert.equal(context(loose).compiler,a.compiler);const stamp=fs.statSync(settings);
    fs.writeFileSync(settings,'b');fs.utimesSync(settings,stamp.atime,stamp.mtime);
    assert.equal(context(loose).compiler,b.compiler,'same-size restored-mtime default changes invalidate selection');
    const snap=()=>{const c=context(mainA);return snapshot({file:mainA,cwd:projectRoot(mainA,root),home:c.home,compiler:c.compiler,args:[],env:c.env,controlFiles:c.controls});};
    const old=snap();fs.appendFileSync(a.metadata,' ');assert.notEqual(snap().key,old.key,'metadata changes invalidate check snapshots');
    const installedState=toolchains.managerState();put('fpr store/receipts/a.json','{}');assert.notEqual(toolchains.managerState(),installedState,'repair receipt publication changes installed state');
    const manifest=path.join(root,'project-a/fpr.toml');fs.writeFileSync(manifest,'b');assert.equal(context(mainA).compiler,b.compiler);
    fs.writeFileSync(manifest,'missing');assert.match(context(mainA).error,/install 9.9.9/);
    const reports=[];
    const checker=createChecker({settings:()=>({}),workspaceRoot:()=>root,readText:p=>{try{return fs.readFileSync(p,'utf8');}catch(_){return null;}},
      onResult:(file,report)=>{if(report!==null)reports.push({file,report});},onMissing:()=>assert.fail('selection errors must be diagnostics'),delay:5});checkers.push(checker);
    checker.check(mainA);await until(()=>reports.length,'missing selection diagnostic');
    assert.match(reports.at(-1).report.get(mainA)[0].message,/install 9.9.9/);
    assert.equal(fs.readFileSync(builds,'utf8'),'','missing pin never runs a fallback compiler');
    fs.writeFileSync(manifest,'a');checker.check(mainA);await until(()=>reports.length===2,'managed compiler check');
    assert.equal(JSON.parse(fs.readFileSync(builds,'utf8').trim()).home,a.moduleHome);
    assert(checker.affected(manifest).includes(mainA));assert(checker.affected(a.metadata).includes(mainA));
    fs.writeFileSync(manifest,'legacy');assert.match(context(mainA).error,/0.2.0/);
    console.log('toolchains: per-project homes, QOS isolation, overrides, bounded discovery cache, default/pin/metadata invalidation, missing-pin refusal and native check execution PASS');
  } finally {
    await Promise.all(checkers.map(c=>c.dispose()));
    for(const key of Object.keys(process.env))if(!(key in saved))delete process.env[key];Object.assign(process.env,saved);
    toolchains.clear();fs.rmSync(root,{recursive:true,force:true});
  }
})().catch(e=>{console.error(e);process.exitCode=1;});
