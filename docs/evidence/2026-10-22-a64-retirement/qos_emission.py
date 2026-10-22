import hashlib, json, os, re, subprocess, tempfile, time
from pathlib import Path
FPR=Path('/Users/jasonqin/Documents/GitHub/fprisc-typed-ir-next')
QOS=Path('/Users/jasonqin/Documents/GitHub/qos-typed-ir-pin')
EVIDENCE=FPR/'docs/evidence/2026-10-22-a64-retirement'
env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
env.update(FPR_HOME=str(QOS),FPR_PATH=str(FPR),FPR_FOREIGN=str(QOS/'core/foreign.fpr'))
files=sorted([*(QOS/'programs').rglob('*.fpr'),*(QOS/'tests').rglob('*.fpr')])
results=[];start=time.monotonic()
with tempfile.TemporaryDirectory(prefix='qos-a64-emission-') as d:
    tmp=Path(d)
    for i,src in enumerate(files,1):
        name=str(src.relative_to(QOS));asm=tmp/(name.replace('/','__')+'.s')
        cmd=[str(FPR/'fprc'),'--target=qa64mac','--profile=qos-portable','--plugin',
             '--prelude='+str(FPR/'core/prelude.fpr'),str(src),str(asm)]
        try:
            p=subprocess.run(cmd,cwd=QOS,env=env,capture_output=True,text=True,timeout=180)
        except subprocess.TimeoutExpired:
            results.append({'source':name,'status':'timeout'});continue
        if p.returncode==0:
            units=[Path(x) for x in Path(str(asm)+'.units').read_text().splitlines()]
            for path in [asm,*units]:
                text=path.read_text()
                assert text.startswith('# typed IR: no translation\n'),path
                assert '# wcet:' not in text,path
                assert all(' typed-ir a64 ' in h for h in re.findall(r'^# fn (.*)',text,re.M)),path
            result={'source':name,'status':'native','units':len(units)}
        else:
            native_failure=bool(re.search(r'typed-ir strict:|requires legacy translation|typed-ir.*compiler error',p.stderr))
            compiler_error=p.returncode<0 or bool(re.search(r'CallStack|internal:|Stack space overflow|Pattern match.*failure',p.stderr))
            result={'source':name,'status':'native_failure' if native_failure else 'compiler_error' if compiler_error else 'frontend_refusal',
                    'returncode':p.returncode,'diagnostic':p.stderr[-3500:]}
        if result['status']=='compiler_error' and 'compiler/Exhaust.hs:191' in result.get('diagnostic',''):
            probe=subprocess.run([*cmd[:-2],'--check-only',*cmd[-2:]],cwd=QOS,env=dict(env,FPR_TYPED_IR_BACKEND='legacy'),capture_output=True,text=True,timeout=60)
            if probe.returncode!=0 and 'compiler/Exhaust.hs:191' in probe.stderr:
                result['status']='frontend_exception'
                result['check_only_diagnostic']=probe.stderr[-3500:]
        results.append(result)
        if i%20==0 or result['status']=='native_failure':
            print(f'{i}/{len(files)} {name}: {result["status"]}',flush=True)
counts={status:sum(r['status']==status for r in results) for status in sorted({r['status'] for r in results})}
(EVIDENCE/'qos-emission.json').write_text(json.dumps({'target':'qa64mac','mode':'default, plugin roots',
    'qos_root':str(QOS),'compiler':str(FPR/'fprc'),'compiler_sha256':hashlib.sha256((FPR/'fprc').read_bytes()).hexdigest(),'elapsed_s':round(time.monotonic()-start,1),'counts':counts,'results':results},indent=2)+'\n')
print(json.dumps(counts),flush=True)
raise SystemExit(1 if counts.get('native_failure',0) or counts.get('timeout',0) or counts.get('compiler_error',0) else 0)
