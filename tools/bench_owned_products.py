#!/usr/bin/env python3
"""Paired owned-product/explicit-loop guest work; no hardware timing claim."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tests'))
from check_owned_products import SOURCE, SINGLE_SOURCE
from check_uniform_aggregate import run

PROBE=r'''
#include "builtin.h"
extern V __real_fpr_fn_main(void);
extern uw owned(V) __asm__("RAW_OWNED"),plain(V) __asm__("RAW_PLAIN");
static uw cycles(void){uw v;__asm__ volatile("csrr %0,mcycle":"=r"(v)::"memory");return v;}
static void say(const char*s){volatile unsigned char*u=(void*)0x10000000;for(;*s;s++){while(!(u[5]&32)){}u[0]=*s;}}
static void number(uw n){char b[32];unsigned k=0;do{b[k++]='0'+n%10;n/=10;}while(n);while(k){char s[]={b[--k],0};say(s);}}
V __wrap_fpr_fn_main(void){
 uw ns[]={100,1000,10000},lens[]={3,4,5};
 for(unsigned i=0;i<3;i++)for(unsigned round=0;round<4;round++)for(unsigned order=0;order<2;order++){
  unsigned which=order^(round&1);uw n=ns[i],live=fpr_builtin_live_allocations(),result,start=cycles();
  if(which)result=plain(TAG(n));else result=owned(TAG(n));
  uw elapsed=cycles()-start;
  if(result!=n+TEXT_FIELDS*lens[i] || fpr_builtin_live_allocations()!=live)fpr_cpanic("owned benchmark correctness");
  if(round){say(which?"plain ":"owned ");number(n);say(" ");number(elapsed);say("\n");}
 }
 say("OWNED_WORK_PASS\n");return __real_fpr_fn_main();
}
'''


def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-compiler',type=Path,required=True)
    parser.add_argument('--record',type=Path,required=True)
    parser.add_argument('--normal-inline',action='store_true',help='Use ordinary inlining instead of isolating representation with FPR_NO_INLINE')
    shape=parser.add_mutually_exclusive_group()
    shape.add_argument('--nested',action='store_true',help='Measure an outer product containing a String/Word product and a second String')
    shape.add_argument('--single',action='store_true',help='Measure a one-field owned String wrapper against its explicit payload loop')
    args=parser.parse_args();baseline=args.baseline_compiler.resolve()
    if args.single:
        source_text='profile builtin.\n'+SINGLE_SOURCE[:SINGLE_SOURCE.index('ShellShell =')]
    elif args.nested:
        source_text=('profile builtin.\nTextPair = Type (TextPair String Word).\nOuter = Type (Outer TextPair String).\n'
                     +SOURCE[SOURCE.index('nestedGo :'):SOURCE.index('makeNested :')])
    else:
        source_text=SOURCE[:SOURCE.index('makePublic')]
    functions=('runSingle','runSinglePlain') if args.single else ('runNested','runNestedPlain') if args.nested else ('runOwned','runPlain')
    record=dict(schema='owned-product-work-v1',measure='QEMU icount guest instructions, not hardware cycles or host wall time',
        nested=args.nested,single=args.single,inlining='normal' if args.normal_inline else 'disabled',
        baseline_compiler_sha256=digest(baseline),compiler_sha256=digest(ROOT/'fpr'),tool_sha256=digest(Path(__file__)),
        source_sha256=hashlib.sha256(source_text.encode()).hexdigest(),
        qemu_version=run(['qemu-system-riscv64','--version']).splitlines()[0],records=[])
    qemu=['qemu-system-riscv64','-machine','virt','-smp','1','-m','128M','-nographic','-bios','none','-icount','shift=0,sleep=off']
    record['qemu_command']=qemu
    record['architecture_flags']='-march=rv64imafdc_zicsr -mabi=lp64 -mcmodel=medany'
    with tempfile.TemporaryDirectory(prefix='fpr-owned-work-') as directory:
        tmp=Path(directory);source=tmp/'products.fpr';source.write_text(source_text)
        main=tmp/'main.fpr';main.write_text('main = Unit.\n')
        for name,compiler,boxed in [('before',baseline,False),('after',ROOT/'fpr',False),('rollback',ROOT/'fpr',True)]:
            env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
            env.update(FPR_HOME=str(ROOT),XDG_CACHE_HOME=str(tmp/f'cache-{name}'))
            if not args.normal_inline:env['FPR_NO_INLINE']='1'
            if boxed:env['FPR_NO_PAIR_RETURNS']='1'
            asm=tmp/f'{name}.s'
            run([compiler,'--profile=bare-metal-builtin','--arc','--lib','--export='+','.join(functions),source,asm],env=env)
            body=f'#define TEXT_FIELDS {2 if args.nested else 1}\n'+PROBE
            for key,fn in zip(('OWNED','PLAIN'),functions):
                match=re.search(r'^# fn \$uniform\.raw\.'+fn+r'\S* .*?^    \.globl (\S+)',asm.read_text(),re.M|re.S)
                assert match,fn
                body=body.replace('RAW_'+key,match[1])
            probe=tmp/f'{name}.c';probe.write_text(body)
            image=tmp/f'{name}.elf'
            run(['make','-s','bare-metal-builtin','ARC=1','ARC_CHECK=0','HEAP=c',f'PROG={main}',f'BUILD={tmp/name}',
                 f'IMAGE={image}',f'BUILTIN_EXTRA={asm} {probe}','BUILTIN_LDFLAGS=-Wl,--wrap=fpr_fn_main',
                 'ARCHFLAGS='+record['architecture_flags']],env=env)
            output=run([*qemu,'-kernel',image])
            assert 'OWNED_WORK_PASS' in output.splitlines(),output
            counts={}
            for kind,n,count in re.findall(r'^(owned|plain) (\d+) (\d+)$',output,re.M):
                counts.setdefault(n,{}).setdefault(kind,[]).append(int(count))
            assert set(counts)=={'100','1000','10000'},output
            for pair in counts.values():
                assert set(pair)=={'owned','plain'} and all(len(v)==3 and len(set(v))==1 for v in pair.values()),output
            record['records'].append(dict(mode=name,counts=counts,image_sha256=digest(image),assembly_sha256=digest(asm)))
            print(name,counts,flush=True)
    args.record.write_text(json.dumps(record,indent=2)+'\n')


if __name__=='__main__':main()
