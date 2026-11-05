#!/usr/bin/env python3
"""Checked public callback stack budgets, including the actual C adapter.

Execute admitted raw callbacks on a guarded fixed stack without an allocator.
This qualifies callback stack storage, not the complete image's dynamic RAM.
"""
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

ROOT = Path(__file__).resolve().parents[1]
SOURCE = '''profile builtin.
loop : Word -> Word -> Word.
loop n a = if Word.eq n (Word.fromInt 0) then a else loop (Word.sub n (Word.fromInt 1)) (Word.add a n).
run : Word -> Word.
run n = loop (Word.fromInt 10000) n.
twice : Word -> Word.
twice n = Word.add (run n) (run (Word.add n (Word.fromInt 1))).
Pair = Type (Pair Word Word).
product : Word -> Word.
product n = p = Pair n (Word.fromInt 1); case p of Pair a b -> Word.add a b.
'''


def run(args, env, timeout=180):
    p = subprocess.run(list(map(str, args)), cwd=ROOT, env=env, capture_output=True, text=True, timeout=timeout)
    assert p.returncode == 0, (args, p.returncode, p.stdout[-4000:], p.stderr[-4000:])
    return p.stdout


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--require-execution', action='store_true')
    ap.add_argument('--record', type=Path)
    ap.add_argument('--linked-stack', action='store_true')
    ap.add_argument('--rvc', action='store_true')
    args = ap.parse_args()
    record = {'compiler_sha256': hashlib.sha256((ROOT/'fpr').read_bytes()).hexdigest(), 'refusals': []}
    with tempfile.TemporaryDirectory(prefix='fpr-callback-stack-') as directory:
        out = Path(directory)
        env = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
        env.update(FPR_HOME=str(ROOT), XDG_CACHE_HOME=str(out/'cache'))

        def compile(name, text=SOURCE, budget=None, exports='run,twice,product', raw=True, extra=(), needle=None):
            src, asm = out/(name+'.fpr'), out/(name+'.s')
            src.write_text(text)
            command = [ROOT/'fpr', 'compile', '--profile=bare-metal-builtin', '--arc', '--lib',
                       *(['--raw'] if raw else []), '--export='+exports,
                       *([] if budget is None else ['--stack-budget='+str(budget)]), *extra, src, asm]
            p = subprocess.run(list(map(str, command)), cwd=ROOT, env=env, capture_output=True, text=True, timeout=180)
            if needle:
                assert p.returncode != 0 and needle in p.stdout+p.stderr, (name,p.returncode,p.stdout[-2000:],p.stderr)
                assert not asm.exists(), 'failed admission published new assembly'
                record['refusals'].append({'case': name, 'reason': p.stderr.strip()[-1500:]})
            else:
                assert p.returncode == 0, (name,p.stdout[-2000:],p.stderr)
                return asm

        emitted = compile('discovery')
        peaks = {n: int(size) for n, size in re.findall(r'^# native-stack-v1: (run|twice|product) local=\d+ peak=(\d+)$', emitted.read_text(), re.M)}
        assert set(peaks) == {'run','twice','product'} and all(n>=32 for n in peaks.values()), peaks
        limit = max(peaks.values())
        admitted = compile('admitted', budget=limit)
        assert len(re.findall(r'^# native-stack-budget-v1:', admitted.read_text(), re.M)) == 3
        # The same source/cache is checked again for a different limit.
        compile('short', budget=limit-1, needle='needs '+str(limit)+' bytes')
        compile('wrapper-short', budget=peaks['run']-16, exports='run', needle='stack budget run: needs')
        for value in ('0','-1','bad','', '1.5'):
            compile('invalid-'+str(len(record['refusals'])), budget=value, needle='positive decimal byte count')
        compile('check-only', budget=limit, extra=('--check-only',), needle='native compilation')
        compile('no-entries', budget=limit, exports='', needle='explicit --export')
        compile('duplicates', budget=limit, exports='run,run', needle='duplicate public callback')
        recursive = '''profile builtin.
recur : Word -> Word.
recur n = if Word.eq n (Word.fromInt 0) then n else Word.add n (recur (Word.sub n (Word.fromInt 1))).
'''
        compile('retaining-recursion', recursive, 65536, 'recur', needle='recursive-stack:')
        compile('uniform-conversion', 'profile builtin.\nidentity : Word -> Word.\nidentity x = x.\n',
                65536, 'identity', raw=False, needle='uniformBoxWord')
        compile('runtime-write', 'profile builtin.\nwrite : Addr -> Word -> Unit.\nwrite p w = Mem.writeWord p w.\n',
                65536, 'write', needle='UNPROVED')
        compile('overflow-path', 'profile builtin.\nplus : Int -> Int.\nplus x = x + 1.\n',
                65536, 'plus', needle='UNPROVED')
        print('Callback admission: exact/short budgets, wrapper storage, runtime paths and recursive refusals PASS', flush=True)
        record.update(predicted_bytes=peaks, stack_capacity_bytes=limit)
        missing=[n for n in ('riscv64-unknown-elf-gcc','qemu-system-riscv64') if not shutil.which(n)]
        if missing:
            assert not args.require_execution, missing
            record.update(execution='skipped', missing=missing)
        else:
            asm=admitted.read_text()
            count=0
            def observe(m):
                nonlocal count
                count+=1
                return m[0]+f'\n    la t3, observed_low\n    ld t4, 0(t3)\n    bgeu sp, t4, .Lcallback_observe_{count}\n    sd sp, 0(t3)\n.Lcallback_observe_{count}:'
            measured=re.sub(r'^\s*addi sp, sp, -\d+$', observe, asm, flags=re.M)
            assert count>=6
            (out/'observed.s').write_text(measured)
            startup=(ROOT/'tests/typed_ir/kernel_crt.S').read_text().split('.globl fpr_fuel_exhausted')[0]
            shim=f'''
.text
.globl invoke_arena
invoke_arena:
 addi sp,sp,-32
 sd ra,0(sp)
 sd s0,8(sp)
 sd s1,16(sp)
 mv s0,sp
 mv s1,a0
 mv a0,a1
 la sp,arena
 addi sp,sp,{limit+16}
 la t3,observed_low
 sd sp,0(t3)
 jalr ra,s1,0
 la t3,returned_sp
 sd sp,0(t3)
 mv sp,s0
 ld ra,0(sp)
 ld s0,8(sp)
 ld s1,16(sp)
 addi sp,sp,32
 ret
'''
            (out/'crt.S').write_text(startup+shim)
            c=f'''#include <stdint.h>
typedef uintptr_t U;
_Alignas(16) unsigned char arena[{limit+32}];
U observed_low,returned_sp;
struct {{uint32_t t,v;}} fpr_unit={{0,0}},fpr_true={{1,1}},fpr_false={{1,0}};
extern U run(U),twice(U),product(U),invoke_arena(U(*fn)(U),U);
static void say(const char*s){{volatile unsigned char*u=(void*)0x10000000;for(;*s;s++){{while(!(u[5]&32)){{}}u[0]=*s;}}}}
static void number(U n){{char b[32];unsigned i=0;do{{b[i++]='0'+n%10;n/=10;}}while(n);while(i){{char q[]={{b[--i],0}};say(q);}}}}
__attribute__((noreturn)) void oracle_finish(int code){{*(volatile unsigned*)0x100000=code?0x13333:0x5555;for(;;){{}}}}
int main(void){{
 U (*fns[])(U)={{run,twice,product}};
 const char*names[]={{"run ","twice ","product "}};
 U expected_peaks[]={{{peaks['run']},{peaks['twice']},{peaks['product']}}};
 for(unsigned f=0;f<3;f++){{U high=0;
  for(unsigned i=0;i<64;i++){{
   for(unsigned j=0;j<sizeof(arena);j++)arena[j]=0xa5;
   U n=i==0?UINT64_MAX:((U)0xfedcba9876543210ULL^i);
   U want=f==0?n+50005000ULL:f==1?2*n+100010001ULL:n+1;
   U got=invoke_arena(fns[f],n),top=(U)(arena+{limit+16});
   if(got!=want || returned_sp!=top || observed_low<top-{limit}){{say("FAIL result/stack\\n");return 1;}}
   U used=top-observed_low;if(used>high)high=used;
   for(unsigned j=0;j<16;j++)if(arena[j]!=0xa5 || arena[{limit+16}+j]!=0xa5){{say("FAIL guard\\n");return 1;}}
  }}
  say(names[f]);number(high);say("\\n");
#ifdef MEASURE_STACK
  if(high!=expected_peaks[f]){{say("FAIL peak\\n");return 1;}}
#endif
 }}say("CALLBACK_STACK_ARENA_PASS\\n");return 0;
}}
'''
            (out/'oracle.c').write_text(c)
            spec=importlib.util.spec_from_file_location('target_image',ROOT/'tools/check_target_image.py')
            admission=importlib.util.module_from_spec(spec);spec.loader.exec_module(admission)
            target=dict(schema=1,target='qemu-virt-rv64-8m-callback-test',elf_class_bits=64,ram_origin=0x80000000,
                        ram_bytes=8*1024*1024,max_image_bytes=8*1024*1024-65536,min_free_bytes=65536)
            images={}
            for mode,assembly in [('plain',admitted),('measured',out/'observed.s')]:
                image=out/(mode+'.elf')
                run(['riscv64-unknown-elf-gcc','-march=rv64imc_zicsr' if args.rvc else '-march=rv64im_zicsr','-mabi=lp64','-mcmodel=medany',
                     '-msmall-data-limit=0','-O2','-ffreestanding','-nostdlib','-fno-builtin','-ffunction-sections',
                     *(['-DMEASURE_STACK'] if mode=='measured' else []),
                     '-Wl,--gc-sections','-T',ROOT/'tests/typed_ir/kernel_link.ld',out/'crt.S',assembly,out/'oracle.c','-o',image],env)
                result=run(['qemu-system-riscv64','-machine','virt','-m','16M','-nographic','-bios','none','-kernel',image],env,30)
                assert 'CALLBACK_STACK_ARENA_PASS' in result and 'FAIL' not in result,result
                symbols=run(['riscv64-unknown-elf-nm',image],env)
                assert not re.search(r'\b(?:fpr_alloc|fpr_builtin_alloc_adt|malloc|calloc|realloc)\b',symbols), symbols
                images[mode]=admission.admit(image.read_bytes(),json.dumps(target).encode(),target['target'])
                if args.linked_stack:
                    from linked_stack_probe import prove
                    proof=prove(image.read_bytes(),json.dumps(target).encode(),target['target'],list(peaks.items()))
                    assert {e['symbol']:e['peak_bytes'] for e in proof['entries']}==peaks
                    images[mode]['linked_stack']=proof
                if mode=='measured':
                    record['observed_bytes']={n:int(v) for n,v in re.findall(r'^(run|twice|product) (\d+)$',result,re.M)}
                print('RV64 '+mode+': 192 admitted callbacks on a guarded fixed stack without an allocator PASS',flush=True)
            record.update(execution='rv64-qemu-pass',rvc=args.rvc,invocations_per_mode=192,guard_bytes_each_side=16,
                          allocator_symbols_absent=True,assembly_sha256=hashlib.sha256(asm.encode()).hexdigest(),
                          target_manifest=target,images=images)
        if args.record:
            args.record.write_text(json.dumps(record,indent=2)+'\n')


if __name__=='__main__':
    main()
