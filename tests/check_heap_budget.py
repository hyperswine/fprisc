#!/usr/bin/env python3
"""Compiler allocation/count admission executed on fixed builtin C heap arenas."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
NAMES=('identity','wide','choose')
SOURCE='''profile builtin.
identity : Word -> Word.
identity x = x.
wide : '''+' -> '.join(['Word']*13)+'''.
wide '''+' '.join('x'+str(i) for i in range(12))+''' = x11.
choose : Bool -> Word -> Word -> Word.
choose b x y = if b then x else y.
'''


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--require-execution',action='store_true')
    ap.add_argument('--record',type=Path)
    ap.add_argument('--linked-stack',action='store_true',help='also prove the final C/native call graph and trace a short run instruction by instruction')
    ap.add_argument('--rvc',action='store_true',help='assemble and execute the runtime with compressed integer instructions')
    args=ap.parse_args()
    iterations=1 if args.linked_stack else 64
    record=dict(compiler_sha256=hashlib.sha256((ROOT/'fpr').read_bytes()).hexdigest(),refusals=[])
    with tempfile.TemporaryDirectory(prefix='fpr-heap-budget-') as directory:
        out=Path(directory)
        env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
        env.update(FPR_HOME=str(ROOT),XDG_CACHE_HOME=str(out/'cache'))
        def run(command,expected=0):
            p=subprocess.run(list(map(str,command)),cwd=ROOT,env=env,capture_output=True,text=True,timeout=180)
            assert p.returncode==expected,(command,p.returncode,p.stdout[-4000:],p.stderr[-4000:])
            return p.stdout+p.stderr
        def compile(name,budget,source=SOURCE,exports=','.join(NAMES),extra=(),reason=None):
            src,asm=out/(name+'.fpr'),out/(name+'.s');src.write_text(source)
            command=[ROOT/'fpr','compile','--profile=bare-metal-builtin','--arc','--lib','--export='+exports,
                     *([] if budget is None else ['--heap-budget='+str(budget)]),*extra,src,asm]
            previous=asm.read_bytes() if asm.exists() else None
            if reason:
                p=subprocess.run(list(map(str,command)),cwd=ROOT,env=env,capture_output=True,text=True,timeout=180)
                assert p.returncode!=0 and reason in p.stdout+p.stderr,(name,p.returncode,p.stdout[-2000:],p.stderr)
                assert (asm.read_bytes()==previous if previous is not None else not asm.exists()),'refused budget replaced/published assembly'
                record['refusals'].append(dict(case=name,reason=p.stderr.strip()))
            else:
                run(command);return asm
        # A diagnostic report refreshes cached unit comments without changing
        # code identities or requiring stack analysis on an ordinary build.
        (out/'report-helper.fpr').write_text('helper x = print x.\n')
        report_source=out/'report.fpr';report_source.write_text('profile builtin.\nH = use "./report-helper".\nmain = H.helper 42.\n')
        def report_compile(name,flags=()):
            path=out/(name+'.s')
            run([ROOT/'fpr','compile','--profile=bare-metal-builtin',*flags,report_source,path])
            units=Path(str(path)+'.units').read_text().splitlines()
            return path.read_text(),{n:Path(n).read_text() for n in units}
        def instructions(text):
            return [s for s in text.splitlines() if s.strip() and not s.lstrip().startswith('#')]
        ordinary,old_units=report_compile('ordinary-report')
        reported,new_units=report_compile('explicit-report',('--stack-report',))
        assert '# native-stack-v1:' not in ordinary and '# native-stack-v1:' in reported
        assert instructions(ordinary)==instructions(reported)
        assert old_units,'stack report fixture did not exercise cached units'
        assert old_units.keys()==new_units.keys()
        for n in old_units:
            assert instructions(old_units[n])==instructions(new_units[n]),n
            assert '# native-stack-v1:' in new_units[n],n
        record['stack_report_refresh_preserves_code_and_unit_identities']=True
        record['stack_report_refreshed_units']=len(old_units)
        discovery=compile('discovery',100000)
        matches=re.findall(r'^# native-heap-budget-v1: (\w+) requests=(\d+) requested=(\d+) arena=(\d+)',discovery.read_text(),re.M)
        bounds={n:dict(requests=int(count),requested_bytes=int(size),arena_bytes=int(arena)) for n,count,size,arena in matches}
        assert set(bounds)==set(NAMES),bounds
        assert [bounds[n]['requests'] for n in NAMES]==[2,13,3],bounds
        capacity=max(r['arena_bytes'] for r in bounds.values())
        ordinary=compile('admitted',None).read_text()
        assembly=compile('admitted',capacity)
        assert '\n'.join(line for line in assembly.read_text().splitlines() if not line.startswith('# native-heap-budget-v1:'))+'\n'==ordinary,'heap budget changed emitted code/data'
        record['unchanged_instructions_and_data']=True
        compile('one-byte-short',capacity-1,reason='needs '+str(capacity)+' bytes')
        compile('admitted',capacity-1,reason='needs '+str(capacity)+' bytes')
        record['cached_short_budget_preserves_existing_output']=True
        for i,value in enumerate(('0','-1','','bad','1.5',str(2**64))):
            compile('invalid-'+str(i),value,reason='positive RV64 decimal byte count')
        compile('check-only',capacity,extra=('--check-only',),reason='native compilation')
        compile('no-entries',capacity,exports='',reason='explicit --export')
        compile('rv32',capacity,extra=('--target=rv32',),reason='RV32 currently supports manual ownership')
        compile('duplicates',capacity,exports='identity,identity',reason='duplicate public callback')
        compile('foreign',65536,source='profile builtin.\nspeak : Int -> Unit.\nspeak x = print x.\n',exports='speak',reason='UNPROVED')
        compile('overflow',65536,source='profile builtin.\nplus : Int -> Int.\nplus x = x + 1.\n',exports='plus',reason='UNPROVED')
        raw=compile('raw-zero',1,source='profile builtin.\nidentity : Word -> Word.\nidentity x = x.\n',exports='identity',extra=('--raw',))
        assert 'requests=0 requested=0 arena=0 limit=1' in raw.read_text()
        record.update(bounds=bounds,maximum_arena_bytes=capacity)
        print('Heap admission: conversion requests, exact/short limits, zero-allocation raw entry and unknown-boundary refusals PASS',flush=True)
        missing=[t for t in ('riscv64-unknown-elf-gcc','qemu-system-riscv64') if not shutil.which(t)]
        if missing:
            assert not args.require_execution,missing
            record['execution']=dict(status='SKIP',missing=missing)
        else:
            crt=(ROOT/'tests/typed_ir/kernel_crt.S').read_text().split('.globl fpr_fuel_exhausted')[0].replace('    call main','    la tp, hart_state\n    call main')
            (out/'crt.S').write_text(crt)
            sizes=','.join(str(bounds[n]['arena_bytes']) for n in NAMES)
            counts=','.join(str(bounds[n]['requests']) for n in NAMES)
            requested=','.join(str(bounds[n]['requested_bytes']) for n in NAMES)
            c=r'''#include "builtin.h"
#include <stdint.h>
const hdr_t fpr_unit={0,0},fpr_true={1,1},fpr_false={1,0};
_Alignas(16) uw hart_state[128];
_Alignas(16) unsigned char arena[CAPACITY+32];
extern uw identity(uw),wide(uw,uw,uw,uw,uw,uw,uw,uw,uw,uw,uw,uw),choose(int,uw,uw);
static void say(const char*s){volatile unsigned char*u=(void*)0x10000000;for(;*s;s++){while(!(u[5]&32)){}u[0]=*s;}}
__attribute__((noreturn)) void oracle_finish(int code){*(volatile unsigned*)0x100000=code?0x13333:0x5555;for(;;){}}
void fpr_cpanic(const char*s){say(s);say("\n");oracle_finish(1);}
static void check(int b){if(!b){say("HEAP_BUDGET_FAIL\n");oracle_finish(1);}}
static void number(uw n){char b[32];unsigned k=0;do{b[k++]='0'+n%10;n/=10;}while(n);while(k){char s[]={b[--k],0};say(s);}}
int main(void){
 const uw sizes[]={SIZES},counts[]={COUNTS},requested[]={REQUESTED};
 const char*names[]={"identity ","wide ","choose "};
 for(unsigned f=0;f<3;f++){uw high=0;
  for(unsigned i=0;i<64;i++)for(unsigned choice=0;choice<(f==2?2u:1u);choice++){
   for(unsigned j=0;j<sizeof arena;j++)arena[j]=0xa5;
   fpr_builtin_heap_plan p;
   check(!fpr_builtin_heap_plan_range(arena+16,arena+16+sizes[f],&p));
   check(p.block_prefix_bytes==80 && p.minimum_block_bytes==96);
   fpr_builtin_heap_init(arena+16,arena+16+sizes[f]);
   uw a=i?0xfedcba9876543210ULL^i:UINT64_MAX,b=~a;
   uw got=f==0?identity(a):f==1?wide(b,b,b,b,b,b,b,b,b,b,b,a):choose(choice,a,b);
   check(got==(f==2&&!choice?b:a));
   fpr_builtin_heap_stats stats;fpr_builtin_heap_get_stats(&stats);
#ifdef FPR_BUILTIN_HEAP_STATS
   check(stats.requests==counts[f] && stats.requested_bytes==requested[f]);
#endif
   check(!stats.live_bytes && !fpr_builtin_live_allocations());
   check(stats.peak_bytes<=p.block_end-p.block_start);
   if(stats.peak_bytes>high)high=stats.peak_bytes;
   for(unsigned j=0;j<16;j++)check(arena[j]==0xa5 && arena[16+sizes[f]+j]==0xa5);
  }
  say(names[f]);number(high);say("\n");
 }
 say("HEAP_BUDGET_FIXED_ARENAS_PASS\n");return 0;
}
'''.replace('CAPACITY',str(capacity)).replace('SIZES',sizes).replace('COUNTS',counts).replace('REQUESTED',requested).replace('i<64',f'i<{iterations}')
            (out/'oracle.c').write_text(c)
            spec=importlib.util.spec_from_file_location('target_image',ROOT/'tools/check_target_image.py')
            image_tool=importlib.util.module_from_spec(spec);spec.loader.exec_module(image_tool)
            target=dict(schema=1,target='qemu-rv64-heap-budget-test',elf_class_bits=64,ram_origin=0x80000000,
                        ram_bytes=8*1024*1024,max_image_bytes=8*1024*1024-65536,min_free_bytes=65536)
            images={}
            for mode in ('plain','measured'):
                image=out/(mode+'.elf')
                run(['riscv64-unknown-elf-gcc','-ffixed-x27','-march=rv64imc_zicsr' if args.rvc else '-march=rv64im_zicsr','-mabi=lp64','-mcmodel=medany','-msmall-data-limit=0',
                     '-O2','-ffreestanding','-fno-builtin','-nostdlib','-ffunction-sections','-fdata-sections','-Wl,--gc-sections',
                     '-DFPR_BUILTIN','-DFPR_BUILTIN_ARC',*(['-DFPR_BUILTIN_HEAP_STATS'] if mode=='measured' else []),
                     '-Iruntime','-Imachine/builtin','-T',ROOT/'tests/typed_ir/kernel_link.ld',out/'crt.S',assembly,
                     out/'oracle.c',ROOT/'machine/builtin/heap.c',ROOT/'machine/builtin/arc.c',ROOT/'machine/virt/memshim.c','-lgcc','-o',image])
                output=run(['qemu-system-riscv64','-machine','virt','-m','16M','-nographic','-bios','none','-kernel',image])
                assert 'HEAP_BUDGET_FIXED_ARENAS_PASS' in output,output
                images[mode]=dict(admission=image_tool.admit(image.read_bytes(),json.dumps(target).encode(),target['target']),output=output)
                if args.linked_stack:
                    from linked_stack_probe import qualify
                    images[mode]['linked_stack']=qualify(image,target,NAMES,iterations*4)
            record['execution']=dict(status='RV64-QEMU-PASS',rvc=args.rvc,calls_per_mode=iterations*4,images=images,target_manifest=target,
                                     assembly_sha256=hashlib.sha256(assembly.read_bytes()).hexdigest())
            print(f'RV64 plain/measured: {iterations*4} allocated callbacks per mode, fixed-arena guards and complete reclamation PASS',flush=True)
    if args.record:args.record.write_text(json.dumps(record,indent=2)+'\n')


if __name__=='__main__':main()
