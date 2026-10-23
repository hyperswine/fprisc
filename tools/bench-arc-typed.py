#!/usr/bin/env python3
"""Paired QEMU guest work for legacy/typed ARC, using the real FP-RISC heap.
Deterministic guest instruction counts, not physical elapsed-time speedups.
"""
import argparse,hashlib,json,os,random,re,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output',type=Path,required=True)
    ap.add_argument('--runs',type=int,default=31)
    a=ap.parse_args()
    if a.runs<3:ap.error('at least three pairs')
    out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
    env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
    env.update(FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),XDG_CACHE_HOME=str(out/'cache'))
    def run(cmd,mode,timeout=120):
        r=subprocess.run([str(x) for x in cmd],cwd=ROOT,env=mode,capture_output=True,text=True,timeout=timeout)
        assert r.returncode==0,(cmd,r.returncode,r.stdout,r.stderr)
        return r.stdout+r.stderr
    images={}
    for mode in ('legacy','mixed'):
        build=out/mode;image=build/'program.elf';e=dict(env,FPR_TYPED_IR_BACKEND=mode)
        if mode=='mixed':e['FPR_TYPED_IR_STRICT']='all'
        text=run(['make','bare-metal-builtin','ARC=1','ARC_CHECK=1','HEAP=fpr','BUILTIN_HEAP_BYTES=16384',
            'PROG=tests/builtin_arc.fpr','BUILD='+str(build),'IMAGE='+str(image),
            'BUILTIN_EXTRA=tests/typed_ir/arc_insns.c','BUILTIN_LDFLAGS=-Wl,--wrap=fpr_fn_main'],e)
        (out/(mode+'-build.log')).write_text(text)
        for asm in (build/'builtin.s',build/'heap.s'):
            headers=re.findall(r'^# fn (.*)',asm.read_text(),re.M)
            assert headers and all(('typed-ir' in h)==(mode=='mixed') for h in headers),asm
        images[mode]=image
    samples={m:[] for m in images};rng=random.Random(7616)
    for i in range(a.runs):
        modes=list(images);rng.shuffle(modes)
        for mode in modes:
            text=run(['qemu-system-riscv64','-machine','virt','-m','128M','-nographic','-bios','none',
                '-icount','shift=0,align=off,sleep=off','-kernel',images[mode]],env)
            assert 'AUTOMATIC ARC HOLDS' in text,text
            samples[mode].append(int(re.search(r'ARC_GUEST_INSNS=([0-9a-f]+)',text)[1],16))
        print(f'Paired round {i+1}/{a.runs}',flush=True)
    data={'compiler_sha256':hashlib.sha256((ROOT/'fpr').read_bytes()).hexdigest(),'scope':__doc__,
        'runs':a.runs,'samples_guest_insns':samples,'ratio':sum(samples['mixed'])/sum(samples['legacy'])}
    (out/'results.json').write_text(json.dumps(data,indent=2)+'\n');print(json.dumps(data,indent=2))
if __name__=='__main__':main()
