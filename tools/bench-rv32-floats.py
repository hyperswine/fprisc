#!/usr/bin/env python3
"""Paired RV32 numeric guest instruction counts, before/default versus strict typed.
Includes real software arithmetic, vectors and runtime work inside main.
Not physical elapsed time.
"""
import argparse,hashlib,json,os,random,re,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tests'))
from check_rv32_float_constants import build,boot

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--against',type=Path,required=True)
    ap.add_argument('--output',type=Path,required=True)
    ap.add_argument('--runs',type=int,default=31)
    a=ap.parse_args()
    if a.runs<3:ap.error('at least three pairs')
    out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
    env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
    env.update(FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),FPR_TYPED_IR_BACKEND='mixed',FPR_NO_F64_INLINE='1',XDG_CACHE_HOME=str(out/'cache'))
    if 'FPR_SOFTFLOAT_ROOT' in os.environ:env['FPR_SOFTFLOAT_ROOT']=os.environ['FPR_SOFTFLOAT_ROOT']
    wrapper=out/'counter.c'
    wrapper.write_text('''#include "builtin.h"
extern V __real_fpr_fn_main(void);extern void hal_putc(char);
static uint64_t retired(void){uint32_t hi,lo,next;do{
 __asm__ volatile("rdinstreth %0;rdinstret %1;rdinstreth %2":"=r"(hi),"=r"(lo),"=r"(next)::"memory");
 }while(hi!=next);return ((uint64_t)hi<<32)|lo;}
V __wrap_fpr_fn_main(void){uint64_t start=retired();V answer=__real_fpr_fn_main();uint64_t count=retired()-start;
 const char*s="RV32_GUEST_INSNS=";while(*s)hal_putc(*s++);static const char digits[]="0123456789abcdef";
 for(unsigned i=0;i<16;i++)hal_putc(digits[(count>>(4*(15-i)))&15]);hal_putc('\n');return answer;}
'''.replace("hal_putc('\n')","hal_putc('\\n')"))
    images={};hashes={}
    for variant,compiler in [('before',a.against),('typed',ROOT/'fpr')]:
        compiler=compiler.resolve();hashes[variant]=hashlib.sha256(compiler.read_bytes()).hexdigest()
        mode=dict(env)
        if variant=='typed':mode['FPR_TYPED_IR_STRICT']='all'
        images[variant]=build(ROOT/'tests/tangnano20k_rv32_numeric.fpr',out/variant,mode,compiler=compiler,extra=wrapper)
        text=(out/variant/'base.s').read_text()
        assert ('# wcet:' in text)==(variant=='before'),'benchmark did not replace the old default fallback'
    samples={v:[] for v in images};rng=random.Random(7717)
    for i in range(a.runs):
        order=list(images);rng.shuffle(order)
        for variant in order:
            text=boot(images[variant],env,count=True)
            assert 'RV32 BASE NUMERIC HOLDS' in text and 'FPR EXIT 0' in text,text
            samples[variant].append(int(re.search(r'RV32_GUEST_INSNS=([0-9a-f]+)',text)[1],16))
        print(f'Paired round {i+1}/{a.runs}',flush=True)
    result={'compiler_sha256':hashes,'scope':__doc__,'runs':a.runs,'samples_guest_insns':samples,
            'ratio':sum(samples['typed'])/sum(samples['before'])}
    (out/'results.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))

if __name__=='__main__':main()
