#!/usr/bin/env python3
"""Paired guest instructions: old default large-frame fallback vs typed reservation.
Uses production actor runtime, default first stack, 80 nested 512-value frames
and forced yields. QEMU deterministic instruction counts, not physical time.
"""
import argparse,hashlib,json,os,random,re,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'tests'))
from check_typed_ir_rv_frames import actor_runtime
from check_typed_ir_rv import run

COUNTER=r'''#include "fpr.h"
extern V __real_fpr_fn_main(void);
static uint64_t retired(void){
#if __riscv_xlen == 32
 uint32_t hi,lo,next;do{__asm__ volatile("rdinstreth %0;rdinstret %1;rdinstreth %2":"=r"(hi),"=r"(lo),"=r"(next)::"memory");}while(hi!=next);
 return ((uint64_t)hi<<32)|lo;
#else
 uint64_t n;__asm__ volatile("rdinstret %0":"=r"(n)::"memory");return n;
#endif
}
V __wrap_fpr_fn_main(void){uint64_t start=retired();V v=__real_fpr_fn_main();uint64_t count=retired()-start;
 const char*s="GUEST_INSNS=";while(*s)hal_putc(*s++);const char hex[]="0123456789abcdef";
 for(unsigned i=0;i<16;i++)hal_putc(hex[(count>>(4*(15-i)))&15]);hal_putc('\n');return v;}
'''

def main():
 ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--against',type=Path,required=True);ap.add_argument('--output',type=Path,required=True);ap.add_argument('--runs',type=int,default=31);a=ap.parse_args()
 if a.runs<3:ap.error('at least three pairs')
 out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
 env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')};env.update(FPR_HOME=str(ROOT),FPR_PATH=str(ROOT))
 counter=out/'counter.c';counter.write_text(COUNTER)
 images={};identities={}
 for width in ('32','64'):
  for variant,compiler in [('before',a.against),('typed',ROOT/'fpr')]:
   compiler=compiler.resolve();identities[variant]=hashlib.sha256(compiler.read_bytes()).hexdigest()
   image,mode=actor_runtime(out/(width+'-'+variant),env,width,compiler=compiler,strict=variant=='typed',counter=counter,execute=False,small_stack=False)
   images[width,variant]=image
 samples={w:{v:[] for v in ('before','typed')} for w in ('32','64')};rng=random.Random(8117)
 for i in range(a.runs):
  for width in samples:
   order=['before','typed'];rng.shuffle(order)
   for variant in order:
    text=run(['qemu-system-riscv'+width,'-icount','shift=0,align=off,sleep=off','-machine','virt','-smp','1','-m','128M','-nographic','-bios','none','-kernel',images[width,variant]],env)
    assert 'RV ACTOR FRAMES HOLD' in text,text
    samples[width][variant].append(int(re.search(r'GUEST_INSNS=([0-9a-f]{16})',text)[1],16))
  print(f'paired round {i+1}/{a.runs}',flush=True)
 result={'scope':__doc__,'runs':a.runs,'compiler_sha256':identities,'samples_guest_insns':samples,
         'ratio':{w:sum(v['typed'])/sum(v['before']) for w,v in samples.items()},
         'elf_sha256':{w+'-'+v:hashlib.sha256(p.read_bytes()).hexdigest() for (w,v),p in images.items()}}
 (out/'results.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result['ratio'],indent=2))

if __name__=='__main__':main()
