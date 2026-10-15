#!/usr/bin/env python3
"""Sanitized heap contracts and the same executable fixture on RV32/RV64.

--baseline-ref REF also runs the allocation/release workload against that git
revision's C heap. QEMU icount reports deterministic guest work, not FPGA time.
The ordinary test has no compiler/runtime dependency beyond the heap's C ABI.
"""
from pathlib import Path
import argparse
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CASES = {
    'overflow': 'allocation overflow',
    'init-overflow': 'heap too small',
    'small-heap': 'heap too small',
    'out-of-memory': 'out of memory',
    'oversized-alloc': 'out of memory',
    'oversized-realloc': 'REFUSED REALLOC PRESERVES ORIGINAL\nBuiltin: out of memory',
    'double-free': 'invalid allocation pointer',
    'coalesced-double-free': 'invalid allocation pointer',
    'interior': 'invalid allocation pointer',
    'forged-interior': 'invalid allocation pointer',
    'unaligned': 'invalid allocation pointer',
    'outside': 'invalid allocation pointer',
    'past-end': 'invalid allocation pointer',
    'retain-interior': 'invalid allocation pointer',
    'release-interior': 'invalid allocation pointer',
    'shared-free': 'free of shared allocation',
    'shared-realloc': 'realloc of shared allocation',
    'realloc-overflow': 'allocation overflow',
    'rc-overflow': 'reference count overflow',
    'field-index': 'field index out of range',
    'adt-layout': 'invalid ADT layout',
}
START = r'''
    .section .text.entry,"ax",@progbits
    .globl _start
_start:
    .option push
    .option norelax
    la gp,__global_pointer$
    .option pop
    la sp,_stack_top
    la t0,_bss_start
    la t1,_bss_end
1:  bgeu t0,t1,2f
#if __riscv_xlen == 64
    sd zero,0(t0)
    addi t0,t0,8
#else
    sw zero,0(t0)
    addi t0,t0,4
#endif
    j 1b
2:  li a0,0
    li a1,0
    call main
    call heap_test_exit
'''
HAL = r'''
#include <stdint.h>
void heap_test_putc(char c) {
  volatile uint8_t *u=(volatile uint8_t *)0x10000000;
  while (!(u[5]&0x20)) {} u[0]=(uint8_t)c;
}
__attribute__((noreturn)) void heap_test_exit(int code) {
  *(volatile uint32_t *)0x100000=code ? ((uint32_t)code<<16)|0x3333 : 0x5555;
  for (;;) __asm__ volatile("wfi");
}
'''
LINK = '''
OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 16M }
SECTIONS {
  .text : { KEEP(*(.text.entry)) *(.text .text.*) } > RAM
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > RAM
  .data : { *(.data .data.*) PROVIDE(__global_pointer$ = . + 0x800); *(.sdata .sdata.*) } > RAM
  .bss (NOLOAD) : { . = ALIGN(16); _bss_start = .; *(.bss .bss.* .sbss .sbss.* COMMON) . = ALIGN(16); _bss_end = .; } > RAM
  .stack (NOLOAD) : { . += 64K; . = ALIGN(16); _stack_top = .; } > RAM
}
'''


def run(args, expected=0, timeout=180):
    p = subprocess.run([str(a) for a in args], cwd=ROOT, capture_output=True,
                       text=True, timeout=timeout)
    if p.returncode != expected:
        raise AssertionError(f'{args}: exit {p.returncode}\n{p.stdout}\n{p.stderr}')
    return p.stdout + p.stderr


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-ref', help='git revision containing the comparison C heap')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='fpr-heap-index-') as temporary:
        tmp = Path(temporary)
        fixture = ROOT / 'tests/builtin_heap_index.c'
        heap = ROOT / 'machine/builtin/heap.c'
        common = ['-std=c11', '-Iruntime', '-Imachine/builtin', '-Wall', '-Wextra', '-Werror']
        host = tmp / 'host'
        run(['clang', *common, '-DFPR_POSIX', '-DFPR_BUILTIN_ARC', '-DFPR_BUILTIN_HEAP_TEST',
             '-fsanitize=address,undefined', '-g', fixture, heap, '-o', host])
        output = run([host])
        assert 'INDEXED BUILTIN HEAP HOLDS' in output, output
        print('Native ASan/UBSan: ' + output, end='', flush=True)
        for case, message in CASES.items():
            assert message in run([host, case], 3)
        print(f'Native explicit refusals: {len(CASES)} passed', flush=True)
        for fixture_name, flags, marker in [
                ('builtin_heap.c', [], 'BUILTIN HEAP HOLDS'),
                ('builtin_arc_heap.c', ['-DFPR_BUILTIN_ARC'], 'ARC LAYOUT AND DEEP RELEASE HOLD')]:
            run(['clang', *common, '-DFPR_POSIX', *flags, '-fsanitize=address,undefined', '-g',
                 ROOT / 'tests' / fixture_name, heap, '-o', host])
            assert marker in run([host])
        print('Existing manual-Rc and exact-layout/deep-ARC sanitizer fixtures: passed', flush=True)
        for limit in (65536, 8388608):
            run(['clang', *common, '-DFPR_POSIX', '-DFPR_BUILTIN_ARC', '-DFPR_BUILTIN_HEAP_TEST',
                 f'-DFPR_BUILTIN_HEAP_MAX_BYTES={limit}', f'-DHEAP_TEST_ARENA_BYTES={limit}',
                 '-DHEAP_CONFIG_ONLY', '-Wno-unused-function', '-fsanitize=address,undefined', '-g',
                 fixture, heap, '-o', host])
            assert 'CONFIGURED BUILTIN HEAP HOLDS' in run([host])
            assert 'configured heap exceeds maximum' in run([host, 'configured-max'], 3)
            for case in ('oversized-alloc', 'oversized-realloc'):
                assert CASES[case] in run([host, case], 3)
        for limit, message in [('0', 'must be positive'), ('-1', 'must be positive'), ('64', 'is too small')]:
            output = run(['clang', *common, '-DFPR_POSIX', f'-DFPR_BUILTIN_HEAP_MAX_BYTES={limit}',
                          '-c', heap, '-o', tmp/'bad-limit.o'], 1)
            assert message in output, output
        print('Native bounded 64 KiB/8 MiB heaps, oversized arena refusal and invalid configuration rejection: passed', flush=True)

        (tmp / 'start.S').write_text(START)
        (tmp / 'hal.c').write_text(HAL)
        (tmp / 'link.ld').write_text(LINK)
        baseline = None
        if args.baseline_ref:
            baseline = tmp / 'baseline.c'
            baseline.write_text(run(['git', 'show', f'{args.baseline_ref}:machine/builtin/heap.c']))

        def build(width, name, source=heap, extra=()):
            image = tmp / f'rv{width}-{name}.elf'
            run(['riscv64-unknown-elf-gcc', *common,
                 f'-march=rv{width}im_zicsr', '-mabi=' + ('ilp32' if width == 32 else 'lp64'),
                 '-mcmodel=medany', '-Os', '-ffreestanding', '-fno-builtin', '-nostdlib', '-nostartfiles',
                 '-DFPR_BUILTIN', '-DFPR_BUILTIN_ARC', '-DHEAP_FREESTANDING', *extra,
                 '-ffunction-sections', '-fdata-sections', '-Wl,--gc-sections',
                 '-T', tmp / 'link.ld', tmp / 'start.S', tmp / 'hal.c',
                 fixture, source, ROOT / 'machine/virt/memshim.c', '-lgcc', '-o', image])
            attributes = run(['riscv64-unknown-elf-readelf', '-A', image])
            arch = re.search(r'Tag_RISCV_arch:\s*"([^"]+)"', attributes).group(1)
            assert not re.search(r'_(?:a|c|f|d)\d', arch), arch
            return image

        def boot(width, image, expected=0):
            return run([f'qemu-system-riscv{width}', '-machine', 'virt', '-smp', '1', '-m', '16M',
                        '-nographic', '-bios', 'none', '-icount', 'shift=0,sleep=off', '-kernel', image], expected)

        for width in (32, 64):
            image = build(width, 'contracts', extra=['-DFPR_BUILTIN_HEAP_TEST'])
            output = boot(width, image)
            assert 'INDEXED BUILTIN HEAP HOLDS' in output, output
            print(f'RV{width}IM QEMU: ' + output, end='', flush=True)
            # Every refusal executes at each XLEN, rather than merely assembling.
            for case, message in CASES.items():
                image = build(width, case, extra=['-DFPR_BUILTIN_HEAP_TEST', f'-DHEAP_CASE="{case}"'])
                assert message in boot(width, image, 3)
            print(f'RV{width} explicit refusals: {len(CASES)} passed', flush=True)
            for limit in (65536, 8388608):
                flags = ['-DFPR_BUILTIN_HEAP_TEST', f'-DFPR_BUILTIN_HEAP_MAX_BYTES={limit}',
                         f'-DHEAP_TEST_ARENA_BYTES={limit}', '-DHEAP_CONFIG_ONLY', '-Wno-unused-function']
                image = build(width, f'configured-{limit}', extra=flags)
                assert 'CONFIGURED BUILTIN HEAP HOLDS' in boot(width, image)
                image = build(width, f'over-limit-{limit}', extra=[*flags, '-DHEAP_CASE="configured-max"'])
                assert 'configured heap exceeds maximum' in boot(width, image, 3)
                for case in ('oversized-alloc', 'oversized-realloc'):
                    image = build(width, f'{case}-{limit}', extra=[*flags, f'-DHEAP_CASE="{case}"'])
                    assert CASES[case] in boot(width, image, 3)
            image = build(width, 'bounded-contracts', extra=['-DFPR_BUILTIN_HEAP_TEST',
                                                           '-DFPR_BUILTIN_HEAP_MAX_BYTES=8388608'])
            assert 'INDEXED BUILTIN HEAP HOLDS' in boot(width, image)
            print(f'RV{width} bounded 64 KiB/8 MiB heaps, oversized refusal and complete bounded contracts: passed', flush=True)
            if width == 32:
                output = run(['riscv64-unknown-elf-gcc', *common, '-march=rv32im_zicsr', '-mabi=ilp32',
                              '-DFPR_BUILTIN', '-DFPR_BUILTIN_HEAP_MAX_BYTES=4294967296ULL',
                              '-c', heap, '-o', tmp/'bad-rv32-limit.o'], 1)
                assert 'maximum exceeds address space' in output, output
            if baseline:
                image = build(width, 'baseline', source=baseline,
                              extra=['-DHEAP_WORK_ONLY', '-Wno-unused-function'])
                print(f'RV{width} baseline QEMU: ' + boot(width, image), end='', flush=True)


if __name__ == '__main__':
    main()
