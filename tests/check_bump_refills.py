#!/usr/bin/env python3
"""Shared refill tails: real-runtime cold/hit paths and an RV64 register oracle."""
from pathlib import Path
import os, platform, re, subprocess, tempfile, argparse
from fuel_wrapper import fuel_wrapper
ROOT=Path(__file__).resolve().parents[1]

def run(args,env,timeout=300):
    p=subprocess.run(list(map(str,args)),cwd=ROOT,env=env,capture_output=True,text=True,timeout=timeout)
    assert p.returncode==0,(args,p.returncode,p.stdout[-2000:],p.stderr[-4000:])
    return p.stdout

def block(text):
    m=re.search(r'(?ms)^# fn build .*?(?=^# native-insns-v1:)',text)
    assert m
    return m[0]

def main():
    parser=argparse.ArgumentParser();parser.add_argument("--compact",action="store_true");args=parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='fpr-refills-') as td:
        tmp=Path(td)
        env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
        env.update(FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),XDG_CACHE_HOME=str(tmp/'cache'),
                   FPR_NO_LIST_FUSE='1',FPR_NO_FIELD_WORKERS='1',FPR_NO_SCALAR_WORKERS='1',
                   FPR_NO_LOOP_REGIONS='1',FPR_NO_CALL_REGIONS='1',FPR_HARTS='1')
        env['FPR_COMPACT_CELLS']='1' if args.compact else '0'
        node='acc'
        for k in reversed(range(24)): node=f'(Cons (n + {k}) {node})'
        src=tmp/'refills.fpr'
        src.write_text('unsafe program.\nList = use "std/list".\nbuild n acc = if n == 0 then acc else build (n - 1) '+node+'.\nmain = print (List.sum (build 200 Nil)).\n')
        texts={}
        for target in ('a64mac','x64mac','rv64'):
            asm=tmp/(target+'.s')
            run([ROOT/'fpr','compile','--system=posix','--target='+target,src,asm],env)
            text=asm.read_text();texts[target]=text;body=block(text)
            sites=len(re.findall(r'\b(?:bl|call)\s+\S*bump_shared_',body))
            tails=len(re.findall(r'^\S*bump_shared_\d+:',body,re.M))
            assert sites>=8 and 0<tails<sites,(target,sites,tails)
            assert len(re.findall(r'\b(?:bl|call)\s+fpr_alloc_save_local',body))==tails,(target,body)
            print(f'{target}: {sites} refill sites share {tails} tails PASS',flush=True)
        targets=[()]
        if platform.system()=='Darwin' and subprocess.run(['arch','-x86_64','/usr/bin/true'],capture_output=True).returncode==0:
            targets.append(('--target=macos-x86_64',))
        for ti,target in enumerate(targets):
            for mode,extra in [('normal',{}),('all-cold',{'FPR_COST_PROBE':'1'}),('rollback',{'FPR_NO_BUMP_ALLOC':'1'})]:
                exe=tmp/f'run-{ti}-{mode}'
                run([ROOT/'fpr','build',src,*target,'-o',exe],dict(env,**extra))
                for harts in ('1','4'):
                    output=run([exe],dict(env,FPR_HARTS=harts))
                    assert output=='537600\n',(target,mode,harts,output)
            print(f'{target or "host"}: shared cold calls, slab refills, rollback and 1/4 harts PASS',flush=True)
        # Execute the exact RV64 function and its preserving wrappers. A closed
        # bump window forces every allocation through the shared tail. The C
        # oracle checks all 4,800 cells and the allocator request count.
        rv=tmp/'oracle.s';text=texts['rv64']
        alloc=re.search(r'(?ms)^fpr_alloc_save_local:.*?^\s*ret\s*$',text)
        assert alloc
        rv.write_text('.text\n'+block(text)+fuel_wrapper(text)+'\n')
        crt=tmp/'crt.S'
        crt.write_text('''.section .text.entry,"ax",@progbits
.globl _start
_start:
 la sp, _stack_top
 la tp, _tls_start
 call main
 tail oracle_finish
''')
        ld=tmp/'link.ld'
        ld.write_text('''OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 16M }
SECTIONS {
 .text : { KEEP(*(.text.entry)) *(.text .text.*) } > RAM
 .rodata : { *(.rodata .rodata.*) } > RAM
 .data : { *(.data .data.*) } > RAM
 .tdata : { _tls_start = .; *(.tdata .tdata.*) } > RAM
 .tbss : { *(.tbss .tbss.*) } > RAM
 .bss (NOLOAD) : { *(.bss .bss.* COMMON) } > RAM
 _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
''')
        c=tmp/'oracle.c'
        c.write_text(r'''#include <stdint.h>
typedef uintptr_t V;
static V hart[80];
__thread V *fpr_posix_hart=hart;
static _Alignas(16) unsigned char arena[4800*48];
static uintptr_t requests, cold;
static V slab[8],pool[8],buckets[512];
#define PREFIX COMPACT_PREFIX
#define TOTAL ((24+PREFIX+15)&~15)
static const struct {uint32_t tid,var;} yes={1,1},no={1,0},nil={2,0};
V fpr_prim_fn__x3d_x3d(V a,V b){return (V)(a==b?&yes:&no);}
V fpr_prim_fn__x2b(V a,V b){return (((a>>1)+(b>>1))<<1)|1;}
V fpr_prim_fn__x2d(V a,V b){return (((a>>1)-(b>>1))<<1)|1;}
__attribute__((noreturn)) void oracle_finish(int code){*(volatile unsigned*)0x100000=code?((unsigned)code<<16)|0x3333:0x5555;for(;;){}}
V fpr_stack_grow(void){oracle_finish(7);}
void fpr_fuel_exhausted(void){hart[0]=1000000000;}
V fpr_alloc(V raw){
 if(raw!=24||slab[4]+TOTAL>(V)(arena+sizeof arena))oracle_finish(2);
 V start=slab[4];slab[4]+=TOTAL;requests++;
 if(PREFIX==16)*(V*)start=TOTAL;*(V*)(start+PREFIX-8)=(V)slab;
 slab[5]=slab[4]+127*TOTAL;if(slab[5]>(V)(arena+4800*TOTAL))slab[5]=(V)(arena+4800*TOTAL);
 if(!cold){hart[60]=(V)slab;hart[61]=(V)buckets;}
 return start+PREFIX;
}
extern V fpr_fn_build(V,V);
int main(void){for(cold=0;cold<2;cold++){
 hart[0]=1000000000;hart[58]=(V)-1;hart[60]=0;requests=0;
 slab[1]=(V)pool;slab[4]=(V)arena;slab[5]=(V)arena;
 V xs=fpr_fn_build(401,(V)&nil);uintptr_t n=0,sum=0;
 while(xs!=(V)&nil){if(n++>=4800||((uint32_t*)xs)[0]!=2||((uint32_t*)xs)[1]!=1)oracle_finish(3);
 if(*(V*)(xs-8)!=(V)slab)oracle_finish(5);
 sum+=(*(V*)(xs+8))>>1;xs=*(V*)(xs+16);}
 if(n!=4800||sum!=537600||slab[4]!=(V)(arena+4800*TOTAL))oracle_finish(4);
 if(cold?requests!=4800:(!requests||requests>40))oracle_finish(6);
 }return 0;}

''')
        c.write_text(c.read_text().replace('COMPACT_PREFIX','8' if args.compact else '16'))
        elf=tmp/'oracle.elf'
        run(['riscv64-unknown-elf-gcc','-march=rv64im_zicsr','-mabi=lp64','-mcmodel=medany','-msmall-data-limit=0','-O2','-ffreestanding','-nostdlib','-fno-builtin','-T',ld,crt,rv,c,'-o',elf],env)
        run(['qemu-system-riscv64','-machine','virt','-m','32M','-nographic','-bios','none','-kernel',elf],env,60)
        print('RV64 shared-refill register, owner and physical extent oracle: 4,800 cold/inline cells PASS',flush=True)
if __name__=='__main__':main()
