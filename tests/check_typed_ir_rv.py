#!/usr/bin/env python3
"""Direct RV32/RV64 code in QEMU: independent results, fuel clobbers, calls and objects.
The tiny runtime substitutes are deliberately separate from Linux scheduler proof.
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(args, env):
    p = subprocess.run(list(map(str, args)), cwd=ROOT, env=env, capture_output=True,
                       text=True, timeout=240)
    assert p.returncode == 0, (args, p.returncode, p.stdout[-3000:], p.stderr[-4000:])
    return p.stdout + p.stderr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--width', choices=('32', '64'), default='64')
    ap.add_argument('--require-execution', action='store_true')
    args = ap.parse_args()
    width = args.width
    missing = [t for t in ('riscv64-unknown-elf-gcc', 'qemu-system-riscv' + width) if not shutil.which(t)]
    if missing:
        if args.require_execution:
            raise SystemExit('required tools missing: ' + ', '.join(missing))
        print('Typed RV64 QEMU SKIP: ' + ', '.join(missing))
        return
    env = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
    env.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), FPR_NO_INLINE='1',
               FPR_NO_SCALAR_WORKERS='1', FPR_NO_FIELD_WORKERS='1', FPR_NO_REUSE='1')
    run(['make', 'fpr'], env)
    with tempfile.TemporaryDirectory(prefix='fpr-tir-rv-') as d:
        root = Path(d)
        env['XDG_CACHE_HOME'] = str(root / 'cache')
        source = root / 'probe.fpr'
        source.write_text('''unsafe base.
rvArith a b = (a * b + a) - b.
rvDiv a b = a / b.
rvChoose a b = if a <= b then a else b.
rvLoop : unsafe Int -> Int -> Int -> Int .
rvLoop n a b = if n == 0 then a + 2*b else rvLoop (n - 1) b a.
rvPair n = (n, n + 1).
rvRead p = case p of (a,b) -> a + b.
rvNested n = p = rvPair n; q = rvPair (n + 2); rvRead p + rvRead q.
rvString u = "ABC".
rvLen s = strlen s.
rvByte s i = charAt s i.
rvWide a b c d e f g h i = a+b+c+d+e+f+g+h+i.
rvWideCall n = rvWide n 2 3 4 5 6 7 8 9.
main = Unit.
''')
        names = 'rvArith,rvDiv,rvChoose,rvLoop,rvPair,rvRead,rvNested,rvString,rvLen,rvByte,rvWide,rvWideCall'
        crt = root / 'crt.s'
        crt.write_text('''
.section .text.entry,"ax",@progbits
.globl _start
_start:
    la sp, _stack_top
    la t0, trap
    csrw mtvec, t0
    call main
    tail oracle_finish
.balign 4
trap:
    li a0, 1
    tail oracle_finish
.text
.globl fpr_fuel_exhausted
fpr_fuel_exhausted:
    addi sp, sp, -16
    sd ra, 8(sp)
    call oracle_tick
    ld ra, 8(sp)
    addi sp, sp, 16
    li a0, 0
    li a1, 0
    li a2, 0
    li a3, 0
    li a4, 0
    li a5, 0
    li a6, 0
    li a7, 0
    li t0, 0
    li t1, 0
    li t2, 0
    li t3, 0
    li t4, 0
    li t5, 0
    li t6, 0
    ret
''')
        ld = root / 'link.ld'
        ld.write_text('''OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 8M }
SECTIONS {
 .text : { KEEP(*(.text.entry)) *(.text .text.*) } > RAM
 .rodata : { *(.rodata .rodata.*) } > RAM
 .data : { *(.data .data.*) } > RAM
 .bss (NOLOAD) : { *(.bss .bss.* COMMON) } > RAM
 _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
''')
        for loops in ('0', '1'):
            if width == '32':
                crt.write_text(crt.read_text().replace('sd ra', 'sw ra').replace('ld ra', 'lw ra'))
            mode = dict(env, FPR_TYPED_IR_BACKEND='mixed', FPR_TYPED_IR_STRICT=names,
                        FPR_TYPED_IR_SELF_LOOPS=loops)
            asm = root / 'probe.s'
            run([ROOT/'fpr', 'compile', '--target=rv' + width, source, asm], mode)
            text = asm.read_text()
            bodies = re.findall(r'(?ms)^# fn ([^\n]+)\n(.*?)(?=^# (?:wcet|native-insns-v1):)', text)
            chosen = [(title, body) for title, body in bodies if title.split()[0] in names.split(',')]
            assert len(chosen) == len(names.split(',')) and all(('typed-ir rv' + width) in title for title, _ in chosen)
            objects = re.findall(r'(?ms)^    \.balign 8\n\.Ltirstr[^:\n]*:\n    \.long 9000\n.*?(?=^$)', text)
            asm.write_text('.text\n' + '\n'.join(body for _, body in chosen) + '\n.section .rodata\n' + '\n'.join(objects))
            exe = root / 'oracle.elf'
            run(['riscv64-unknown-elf-gcc', '-march=rv' + width + 'im_zicsr_zifencei', '-mabi=' + ('lp64' if width == '64' else 'ilp32'), '-mcmodel=medany',
                 '-msmall-data-limit=0', '-O2', '-ffreestanding', '-nostdlib', '-fno-builtin',
                 '-T', ld, crt, asm, ROOT/'tests/typed_ir/rv_oracle.c', '-o', exe], env)
            result = run(['qemu-system-riscv' + width, '-machine', 'virt', '-smp', '1', '-m', '16M',
                          '-nographic', '-bios', 'none', '-kernel', exe], env)
            assert 'TYPED_RV_PASS' in result, result
            print(f'direct RV{width} self-loops={loops}: {result.strip()}', flush=True)


if __name__ == '__main__':
    main()
