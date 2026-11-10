#!/usr/bin/env python3
"""Physical stack high-water oracle for the closed builtin RV32/RV64 subset.

Hosted target summaries remain unproved across runtime calls. This test does
not replace those calls with invented bounds or claim whole-image admission.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(args, env, timeout=600):
    p = subprocess.run(list(map(str, args)), cwd=ROOT, env=env,
                       capture_output=True, text=True, timeout=timeout)
    assert p.returncode == 0, (args, p.returncode, p.stdout[-5000:], p.stderr[-5000:])
    return p.stdout


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--require-execution', action='store_true')
    ap.add_argument('--record', type=Path)
    ap.add_argument('--baseline', type=Path, help='optional pre-summary compiler for emitted-instruction parity')
    args = ap.parse_args()
    records = []
    with tempfile.TemporaryDirectory(prefix='fpr-native-stack-') as directory:
        out = Path(directory)
        env = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
        env['FPR_STACK_TEST_OUT'] = str(out)
        env.update(FPR_HOME=str(ROOT), XDG_CACHE_HOME=str(out/'cache'))
        print(run(['cabal', 'test', 'NativeStack', '--test-show-details=direct'], env), flush=True)
        # NativeStack writes fresh artifacts on every invocation, including a
        # cached Cabal build. Absence is an error, never a silent execution skip.
        assert all((out/(t+'.s')).is_file() for t in ('a64', 'x64', 'rv32', 'rv64'))
        source = out/'entries.fpr'
        source.write_text('identity : Int -> Int.\nidentity x = x.\nannounce : Int -> Unit.\nannounce x = print x.\n')
        compiled = out/'entries.s'
        flags = ['compile', '--profile=bare-metal-builtin', '--arc', '--lib',
                 '--export=identity,announce', source]
        run([ROOT/'fpr', *flags, compiled], env)
        text = compiled.read_text()
        assert re.search(r'native-stack-v1: fpr_fn_Unit local=\d+ peak=UNPROVED reasons=interposable-entry:', text), text[-5000:]
        assert re.search(r'native-stack-v1: fpr_fn_announce\w* local=\d+ peak=UNPROVED', text), text[-5000:]
        assert re.search(r'native-stack-v1: fpr_fn_identity\w* local=\d+ peak=UNPROVED reasons=.*runtime:', text), text[-5000:]
        integration = dict(arc_reference_boundary='unproved', weak_definition_boundary='unproved', status='source-emission-pass', assembly_sha256=hashlib.sha256(text.encode()).hexdigest())
        if args.baseline:
            old = out/'entries-old.s'
            run([args.baseline, *flags, old], env)
            def instructions(s):
                return [line.strip() for line in s.splitlines() if line.strip() and not line.lstrip().startswith('#')]
            assert instructions(text) == instructions(old.read_text()), 'native instruction or data emission changed'
            integration.update(baseline_sha256=hashlib.sha256(args.baseline.read_bytes()).hexdigest(),
                               unchanged_instructions_and_data=True)
        for width in (32, 64):
            target = 'rv'+str(width)
            asm = (out/(target+'.s')).read_text()
            bounds_text = (out/(target+'.bounds')).read_text()
            bounds = {n: int(peak) for n, peak in re.findall(
                r'native-stack-v1: fpr_fn_(\w+) local=\d+ peak=(\d+)', bounds_text)}
            assert set(bounds) == {'leaf', 'middle', 'root', 'tail', 'spills'}, bounds_text
            missing = [tool for tool in ('riscv64-unknown-elf-gcc', 'qemu-system-riscv'+str(width))
                       if not shutil.which(tool)]
            if missing:
                assert not args.require_execution, missing
                records.append(dict(target=target, status='execution-skipped', missing=missing))
                continue
            ld, st, abi = ('lw', 'sw', 'ilp32') if width == 32 else ('ld', 'sd', 'lp64')
            # At each final-layout frame decrement, observe SP using reserved
            # scratch registers only. No calls or extra stack space are added.
            count = 0

            def observe(m):
                nonlocal count
                count += 1
                return m[0] + f'\n    la t3, stack_low\n    {ld} t4, 0(t3)\n' \
                    f'    bgeu sp, t4, .Lstack_observe_{count}\n    {st} sp, 0(t3)\n.Lstack_observe_{count}:'

            instrumented = re.sub(r'^\s*addi sp, sp, -\d+$', observe, asm, flags=re.M)
            assert count == 5, (target, count, asm)
            (out/'observed.s').write_text(instrumented)
            # The assembly caller records its SP immediately before the call,
            # then checks restoration; the C harness frame is outside the bound.
            shim = '.text\n.globl stack_invoke\nstack_invoke:\n addi sp,sp,-16\n'
            shim += f' {st} ra,0(sp)\n la t3,stack_entry\n {st} sp,0(t3)\n'
            shim += f' la t3,stack_low\n {st} sp,0(t3)\n mv t3,a0\n li a0,85\n jalr ra,t3,0\n'
            shim += f' la t3,stack_after\n {st} sp,0(t3)\n {ld} ra,0(sp)\n addi sp,sp,16\n ret\n'
            startup = (ROOT/'tests/typed_ir/kernel_crt.S').read_text().split('.globl fpr_fuel_exhausted')[0]
            (out/'crt.S').write_text(startup+shim)
            source = '''#include <stdint.h>
typedef uintptr_t U;
U stack_entry,stack_low,stack_after;
extern U stack_invoke(U (*fn)(U));
static void say(const char*s){volatile unsigned char*u=(void*)0x10000000;for(;*s;s++){while(!(u[5]&32)){}u[0]=*s;}}
static void number(U n){char b[32];unsigned i=0;do{b[i++]='0'+n%10;n/=10;}while(n);while(i){char c[]={b[--i],0};say(c);}}
__attribute__((noreturn)) void oracle_finish(int n){*(volatile unsigned*)0x100000=n?0x13333:0x5555;for(;;){}}
'''
            for name in bounds:
                source += f'extern U fpr_fn_{name}(U);\n'
            source += 'int main(void){\n'
            for name, expected in bounds.items():
                answer = 1 if name == 'spills' else 85
                source += f'if(stack_invoke(fpr_fn_{name})!={answer} || stack_entry!=stack_after){{say("FAIL ABI\\n");return 1;}}\n'
                source += f'say("{name} ");number(stack_entry-stack_low);say("\\n");\n'
                source += f'if(stack_entry-stack_low!={expected}){{say("FAIL bound\\n");return 1;}}\n'
            source += 'say("NATIVE_STACK_PASS\\n");return 0;}\n'
            (out/'oracle.c').write_text(source)
            image = out/(target+'.elf')
            run(['riscv64-unknown-elf-gcc', '-ffixed-x27', '-march='+target+'im_zicsr', '-mabi='+abi,
                 '-mcmodel=medany', '-msmall-data-limit=0', '-O2', '-ffreestanding', '-nostdlib',
                 '-fno-builtin', '-T', ROOT/'tests/typed_ir/kernel_link.ld', out/'crt.S',
                 out/'observed.s', out/'oracle.c', '-o', image], env)
            result = run(['qemu-system-riscv'+str(width), '-machine', 'virt', '-m', '16M',
                          '-nographic', '-bios', 'none', '-kernel', image], env, timeout=30)
            assert 'NATIVE_STACK_PASS' in result and 'FAIL' not in result, result
            observed = {n: int(value) for n, value in re.findall(r'^(\w+) (\d+)$', result, re.M)}
            assert observed == bounds, (observed, bounds)
            records.append(dict(target=target, status='emulator-pass', predicted_bytes=bounds,
                                observed_bytes=observed, assembly_sha256=hashlib.sha256(asm.encode()).hexdigest(),
                                image_sha256=hashlib.sha256(image.read_bytes()).hexdigest()))
            print(target+': physical stack bounds match all five executed probes', flush=True)
        record = dict(metric='native-stack-v1', scope='closed generated builtin call graph; excludes image/runtime admission',
                      compiler_sha256=hashlib.sha256((ROOT/'fpr').read_bytes()).hexdigest(), integration=integration, targets=records)
        if args.record:
            args.record.write_text(json.dumps(record, indent=2)+'\n')


if __name__ == '__main__':
    main()
