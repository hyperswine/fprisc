#!/usr/bin/env python3
"""Integration tests; requires compiler build tools, RISC-V GCC, QEMU and clang."""
from pathlib import Path
import os
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)


def run(args, expected=0, timeout=60):
    p = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=timeout)
    if p.returncode != expected:
        raise AssertionError(f'{args}: exit {p.returncode}\n{p.stdout}\n{p.stderr}')
    return p.stdout + p.stderr


def boot(image, expected=0):
    return run(['qemu-system-riscv64', '-machine', 'virt', '-smp', '2', '-m', '128M',
                '-nographic', '-bios', 'none', '-kernel', image], expected, timeout=15)


def build(source, image, directory):
    run(['make', 'bare-metal-builtin', f'PROG={source}', f'IMAGE={image}', f'BUILD={directory}'])


run(['make', 'fpr'], timeout=300)
with tempfile.TemporaryDirectory(prefix='fpr-builtin-') as temp:
    tmp = Path(temp)
    image = tmp / 'test.elf'
    build('tests/builtin.fpr', image, tmp)
    assert 'BUILTIN HOLDS' in boot(image)
    symbols = run(['riscv64-unknown-elf-nm', image])
    assert not re.search(r'\b(?:fpr_\w*(?:actor|sched|fuel)\w*|buddy_\w*|qos_\w*)\b', symbols), symbols
    assert not run(['riscv64-unknown-elf-nm', '-u', image]).strip()
    assert 'call fpr_fuel_exhausted' not in (tmp / 'builtin.s').read_text()
    print('Standalone QEMU program and scheduler-free link: PASS')

    cases = [
        ('shift-negative', 'Word.shl (Word.fromInt 1) -1', 'shift out of range'),
        ('shift-width', 'Word.shr (Word.fromInt 1) 64', 'shift out of range'),
        ('mask-range', 'Word.mask 64 1', 'mask out of range'),
        ('negative-size', 'Mem.alloc -1', 'negative size'),
        ('unaligned', 'Mem.readWord (Addr.fromWord (Word.fromInt 3))', 'unaligned access'),
    ]
    for name, expr, message in cases:
        source = tmp / f'{name}.fpr'
        source.write_text(f'main = {expr}.\n')
        build(source, image, tmp)
        assert message in boot(image, 1)
    print('Invalid shifts, mask, size and alignment: PASS')

    source = tmp / 'wrong-type.fpr'
    source.write_text('main = Mem.read8 123.\n')
    output = run(['./fprc', '--profile=bare-metal-builtin', source, tmp / 'bad.s'], 1)
    assert 'Int' in output and 'Addr' in output
    run(['./fprc', '--profile=bare-metal-builtin', '--target=rv32', source, tmp / 'bad.s'], 1)
    print('Type and unsupported-target rejection: PASS')

    # Both builds must keep their own module cache, including custom preludes.
    prelude = tmp / 'prelude.fpr'
    prelude.write_text('helper x = x + 1.\n')
    source.write_text('main = helper 4.\n')
    normal = tmp / 'normal.s'
    builtin = tmp / 'standalone.s'
    run(['./fprc', '--profile=bare-metal', f'--prelude={prelude}', source, normal])
    run(['./fprc', f'--prelude={prelude}', '--profile=bare-metal-builtin', source, builtin])
    normal_unit = Path(Path(str(normal) + '.units').read_text().strip())
    builtin_unit = Path(Path(str(builtin) + '.units').read_text().strip())
    assert normal_unit != builtin_unit
    assert 'call fpr_fuel_exhausted' in normal_unit.read_text()
    assert 'call fpr_fuel_exhausted' not in builtin_unit.read_text()
    print('Profile-specific module caches and explicit prelude: PASS')

    host = tmp / 'heap-test'
    run(['clang', '-std=c11', '-DFPR_POSIX', '-Iruntime', '-Imachine/builtin',
         '-fsanitize=address,undefined', '-g', 'tests/builtin_heap.c', 'machine/builtin/heap.c', '-o', host])
    assert 'BUILTIN HEAP HOLDS' in run([host])
    for case in ['overflow', 'double-free', 'shared-realloc']:
        run([host, case], 3)
    print('Heap, reallocation, sharing and error paths under ASan/UBSan: PASS')
