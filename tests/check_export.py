#!/usr/bin/env python3
"""Library units: an FP-RISC file compiled with --lib/--export links beside a
program unit and its entries are callable from C with the plain RV64 ABI.
Then the allocator itself, machine/builtin/heap.fpr, in place of heap.c."""
from pathlib import Path
import os, subprocess, tempfile
ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
def run(args, expected=0, timeout=120):
    p = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=timeout)
    if p.returncode != expected:
        raise AssertionError(f'{args}: exit {p.returncode}\n{p.stdout}\n{p.stderr}')
    return p.stdout + p.stderr
def boot(image, expected=0, timeout=20):
    return run(['qemu-system-riscv64', '-machine', 'virt', '-smp', '2', '-m', '128M',
                '-nographic', '-bios', 'none', '-kernel', image], expected, timeout=timeout)
run(['make', 'fpr'], timeout=300)
with tempfile.TemporaryDirectory(prefix='fpr-export-') as temp:
    tmp = Path(temp)
    # 1. the library unit: exports need signatures, and every type must cross
    out = run(['make', 'builtin-lib', 'LIB=tests/builtin_export.fpr',
               'LIB_EXPORT=mix,half,isEven,scale,poke,peek,where,sumCell', f'BUILD={tmp}'])
    lib = tmp / 'lib-builtin_export.s'
    asm = lib.read_text()
    assert 'export mix : KWord KInt KBool -> KWord' in out, out
    for sym in ['mix', 'half', 'isEven', 'scale', 'poke', 'peek', 'where', 'sumCell']:
        assert f'\n{sym}:\n' in asm, sym
    assert '.weak fpr_fn_Cons' in asm or '.weak fpr_fn_True' in asm, 'library stubs must be weak'
    assert 'la a0, _heap_state' in asm, 'Addr.symbol should be one la'
    print('Library unit: qualified names, weak shared stubs, C entries with the declared contract: PASS')
    # a refused export: no signature / a managed type / a non-literal symbol
    bad = tmp / 'bad.fpr'
    bad.write_text('nosig x = x.\n')
    r = run(['./fprc', '--profile=bare-metal-builtin', '--arc', '--lib', '--export=nosig', bad, tmp / 'bad.s'], 1)
    assert 'no declared signature' in r, r
    bad.write_text('L = Type (L a).\nf : Int -> L .\nf n = L n.\n')
    r = run(['./fprc', '--profile=bare-metal-builtin', '--arc', '--lib', '--export=f', bad, tmp / 'bad.s'], 1)
    assert 'not a C-representable type' in r, r
    bad.write_text('g s = Addr.symbol s.\nmain = g "x".\n')
    r = run(['./fprc', '--profile=bare-metal-builtin', '--arc', bad, tmp / 'bad.s'], 1)
    assert 'string literal' in r, r
    print('Refusals: unsigned export, managed type at the boundary, computed symbol name: PASS')
    # 2. two units + the C probe in one image
    image = tmp / 'export.elf'
    run(['make', 'bare-metal-builtin', 'ARC=1', 'ARC_CHECK=1', 'PROG=tests/builtin_export_main.fpr',
         f'IMAGE={image}', f'BUILD={tmp}',
         f'BUILTIN_EXTRA={lib} tests/builtin_export_probe.c',
         'BUILTIN_LDFLAGS=-Wl,--wrap=fpr_fn_main'])
    out = boot(image)
    assert 'EXPORTS HOLD' in out and 'EXPORT PROGRAM RAN' in out, out
    assert not run(['riscv64-unknown-elf-nm', '-u', image]).strip()
    print('C -> FP-RISC across every boundary type, a library beside a program, Addr.symbol resolved by the linker: PASS')
    # 3. the allocator in FP-RISC: the existing ARC and raw programs, heap.c out of the link
    for prog, want, heap in [('tests/builtin_arc.fpr', 'AUTOMATIC ARC HOLDS', 16384),
                             ('tests/builtin_raw.fpr', 'RAW REPRESENTATIONS HOLD', 16384),
                             ('tests/builtin_machine.fpr', 'MACHINE PRIMITIVES HOLD', 16384)]:
        run(['make', 'bare-metal-builtin', 'ARC=1', 'ARC_CHECK=1', 'HEAP=fpr', f'BUILTIN_HEAP_BYTES={heap}',
             f'PROG={prog}', f'IMAGE={image}', f'BUILD={tmp}'])
        # the 10,000-cycle ARC program takes ~1.2 s on the FP-RISC allocator
        # against ~0.4 s on heap.c (docs/BAREMETAL-BUILTIN.md, "Speed, honestly")
        assert want in boot(image, timeout=60), prog
    symbols = run(['riscv64-unknown-elf-nm', image])
    assert 'fpr_alloc' in symbols and 'fpr_fn_alloc' in symbols, 'fpr_alloc must be the trampoline onto the fpr allocator'
    deep = tmp / 'deep.fpr'
    deep.write_text('build n xs = case n == 0 of True -> xs | False -> build (n - 1) (Cons n xs).\n'
                    'main = build 6000 Nil.\n')
    run(['make', 'bare-metal-builtin', 'ARC=1', 'ARC_CHECK=1', 'HEAP=fpr', 'BUILTIN_HEAP_BYTES=1048576',
         f'PROG={deep}', f'IMAGE={image}', f'BUILD={tmp}'])
    boot(image, timeout=60)
    oom = tmp / 'oom.fpr'
    oom.write_text('grow n xs = grow (n + 1) (Cons n xs).\nmain = grow 0 Nil.\n')
    run(['make', 'bare-metal-builtin', 'ARC=1', 'HEAP=fpr', 'BUILTIN_HEAP_BYTES=16384',
         f'PROG={oom}', f'IMAGE={image}', f'BUILD={tmp}'])
    assert 'Builtin: out of memory' in boot(image, 1, timeout=60)
    print('The allocator in FP-RISC: 10,000 ARC cycles, raw fields, machine primitives, a 6,000-node release, exhaustion refused by name: PASS')
