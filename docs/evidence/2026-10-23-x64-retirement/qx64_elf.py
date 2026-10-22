"""Assemble representative full QOS roots/imports as unadapted x86 ELF."""
import hashlib,json,os,re,subprocess,tempfile
from pathlib import Path
FPR=Path(__file__).resolve().parents[3]
QOS=FPR.parent/'qos-typed-ir-pin'
EVIDENCE=Path(__file__).parent
catalog=json.loads((EVIDENCE/'qos-emission.json').read_text())
patterns=('guishell','diskapp','mainprofile','qlogmemory','sysed1','plugin','terminal','kv')
selected=[]
for pattern in patterns:
    matches=[r['source'] for r in catalog['results'] if r['status']=='native' and pattern in r['source'].lower()]
    if matches: selected.append(matches[0])
selected=list(dict.fromkeys(selected))
assert len(selected)>=5,selected
env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
env.update(FPR_HOME=str(QOS),FPR_PATH=str(FPR),FPR_FOREIGN=str(QOS/'core/foreign.fpr'))
def run(cmd):
    p=subprocess.run(list(map(str,cmd)),cwd=QOS,env=env,capture_output=True,text=True,timeout=180)
    assert p.returncode==0,(cmd,p.returncode,p.stdout[-1000:],p.stderr[-3000:])
    return p.stdout
results=[]; seen=set(); relocations=0
with tempfile.TemporaryDirectory(prefix='fpr-qx64-elf-') as d:
    tmp=Path(d)
    for src in selected:
        asm=tmp/(src.replace('/','__')+'.s')
        run([FPR/'fprc','--target=qx64','--profile=qos-portable','--plugin','--prelude='+str(FPR/'core/prelude.fpr'),QOS/src,asm])
        units=[Path(s) for s in Path(str(asm)+'.units').read_text().splitlines()]
        for path in [asm,*units]:
            if path in seen: continue
            seen.add(path)
            text=path.read_text()
            assert text.startswith('# typed IR: no translation\n') and '@tpoff' not in text,path
            obj=tmp/'check.o'
            run(['clang','-target','x86_64-unknown-linux-gnu','-c',path,'-o',obj])
            rel=run(['objdump','-r',obj])
            assert not re.search(r'R_X86_64_\w*(?:TLS|TPOFF|DTP)',rel),rel
            relocations+=rel.count('fpr_g_tlsoff')
        results.append({'source':src,'units':len(units)})
        print(src+': full ELF root/import assembly PASS',flush=True)
assert relocations>0
result={'target':'qx64','compiler_sha256':hashlib.sha256((FPR/'fprc').read_bytes()).hexdigest(),'roots':results,'unique_assembly_files':len(seen),'borrowed_offset_relocations':relocations,'app_tls_relocations':0}
(EVIDENCE/'qx64-elf.json').write_text(json.dumps(result,indent=2)+'\n')
print(f'{len(results)} roots, {len(seen)} unique assembly files, {relocations} borrowed-offset relocations, zero app TLS relocations PASS',flush=True)
