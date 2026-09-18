#!/usr/bin/env python3
"""First-order automatic ARC acceptance and explicit feature-boundary tests."""
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


def boot(image):
    return run(['qemu-system-riscv64', '-machine', 'virt', '-m', '128M', '-nographic',
                '-bios', 'none', '-kernel', image], timeout=30)


def build(source, image, directory, heap=16384, extra=()):
    run(['make', 'bare-metal-builtin', 'ARC=1', 'ARC_CHECK=1', f'BUILTIN_HEAP_BYTES={heap}',
         f'PROG={source}', f'IMAGE={image}', f'BUILD={directory}', *extra])


run(['make', 'fpr'], timeout=300)
with tempfile.TemporaryDirectory(prefix='fpr-arc-') as temp:
    tmp = Path(temp)
    image = tmp / 'test.elf'
    build('tests/builtin_arc.fpr', image, tmp)
    assert 'AUTOMATIC ARC HOLDS' in boot(image)
    asm = (tmp / 'builtin.s').read_text()
    assert 'j fpr_fn_loop' in asm, 'ARC lost tail-call elimination'
    symbols = run(['riscv64-unknown-elf-nm', image])
    assert not re.search(r'\b(?:fpr_apply\w*|fpr_\w*(?:actor|sched|fuel)\w*)\b', symbols)
    print('10,000 sharing/escape cycles in 16 KiB; zero live allocations; tail calls: PASS')

    deep = tmp / 'deep.fpr'
    deep.write_text('build n xs = case n == 0 of True -> xs | False -> build (n - 1) (Cons n xs).\n'
                    'main = build 6000 Nil.\n')
    build(deep, image, tmp, heap=1048576)
    boot(image)  # startup must release main's deep returned value with a 64 KiB stack
    print('Returned 6,000-node graph released without recursive destruction: PASS')

    # QEMU-virt scratch RAM outside the deliberately tiny managed heap.
    # The nullary function uses explicit memory as its termination counter.
    nullary = tmp / 'nullary.fpr'
    nullary.write_text(
        'again = p = Addr.fromWord (Word.fromInt 2164260864); '
        'n = Word.toInt (Mem.read32 p); case n == 0 of True -> Unit | False -> '
        '_ = Mem.write32 p (Word.fromInt (n - 1)); again.\n'
        'main = p = Addr.fromWord (Word.fromInt 2164260864); '
        '_ = Mem.write32 p (Word.fromInt 10000); again.\n')
    build(nullary, image, tmp)
    boot(image)
    assert 'j fpr_fn_again' in (tmp/'builtin.s').read_text()
    print('Nullary tail recursion with effectful termination: PASS')

    prelude = tmp / 'prelude.fpr' 
    prelude.write_text('dropFirst xs = case xs of Cons h t -> t | Nil -> Nil.\n')
    source = tmp / 'unit.fpr'
    source.write_text('main = print (dropFirst [1, 2, 3]).\n')
    normal = tmp / 'manual.s'
    run(['./fprc', '--profile=bare-metal-builtin', f'--prelude={prelude}', source, normal])
    normal_units = Path(str(normal)+'.units').read_text()
    build(source, image, tmp, extra=[f'FPRC_FLAGS=--prelude={prelude}'])
    assert '[2, 3]' in boot(image)
    assert normal_units != (tmp/'builtin.s.units').read_text()
    build(source, image, tmp, extra=[f'FPRC_FLAGS=--prelude={prelude}'])
    assert '[2, 3]' in boot(image), 'cached ARC module failed'
    print('Cross-unit ownership and separate ARC cache, including cached rebuild: PASS')

    cases = {
        'float': 'main = 1.5.\n',
        'float-field': 'main = [1.5].\n',
        'closure': 'main = fn x -> x.\n',
        'indirect': 'apply f x = f x.\nmain = apply (fn x -> x) 1.\n',
        'partial': 'add a b = a + b.\nmain = add 1.\n',
        'manual-rc': 'main = Rc.retain [1].\n',
    }
    for name, code in cases.items():
        source = tmp / f'{name}.fpr'
        source.write_text(code)
        output = run(['./fprc', '--profile=bare-metal-builtin', '--arc', source, tmp/f'{name}.s'], 1)
        assert 'automatic ARC:' in output, output
        assert not (tmp/f'{name}.s').exists()
    print('Floats, closures, indirect/partial calls and explicit RC rejected: PASS')

    host = tmp / 'heap-test'
    run(['clang', '-std=c11', '-O1', '-DFPR_POSIX', '-DFPR_BUILTIN_ARC', '-Ihal/core', '-Ihal/builtin',
         '-fsanitize=address,undefined', '-g', 'tests/builtin_arc_heap.c', 'hal/builtin/heap.c', '-o', host])
    assert 'ARC LAYOUT AND DEEP RELEASE HOLD' in run([host])
    print('Exact layouts, shared edges and 12,000-node drops under ASan/UBSan: PASS')
