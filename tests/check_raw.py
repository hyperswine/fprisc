#!/usr/bin/env python3
"""Raw-value ARC and resumable RV64 interrupt acceptance tests."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)


def run(args, expected=0, timeout=60):
    p = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=timeout)
    if p.returncode != expected:
        raise AssertionError(f'{args}: exit {p.returncode}\n{p.stdout}\n{p.stderr}')
    return p.stdout + p.stderr


run(['make', 'fpr'], timeout=300)
with tempfile.TemporaryDirectory(prefix='fpr-raw-') as temp:
    tmp = Path(temp)
    image = tmp/'test.elf'

    def build(source, *extra):
        run(['make', 'bare-metal-builtin', 'ARC=1', 'ARC_CHECK=1', 'BUILTIN_HEAP_BYTES=16384',
             f'PROG={source}', f'BUILD={tmp}', f'IMAGE={image}', *extra])

    def boot(expected=0):
        return run(['qemu-system-riscv64', '-machine', 'virt', '-m', '128M', '-nographic',
                    '-bios', 'none', '-kernel', image], expected, timeout=20)

    build('tests/builtin_raw.fpr')
    assert 'RAW REPRESENTATIONS HOLD' in boot()
    print('10,000 allocation-free word steps; mixed managed/raw fields; F32/F64: PASS')

    for name, expression in [
        ('float', '1.5'), ('float-fields', '[1.5, 2.5]'),
        ('raw-word', 'Word.not (Word.fromInt 0)'), ('raw-address', 'Addr.null Unit'),
        ('word-render', 'print [Word.fromInt 7, Word.fromInt 8]'),
    ]:
        source = tmp/f'{name}.fpr'
        source.write_text(f'main = {expression}.\n')
        build(source)
        result = boot()
        if name == 'word-render':
            assert '[7, 8]' in result, result
    print('Raw main results, float graphs and raw-field rendering: PASS')

    source = tmp/'float-equality.fpr'
    source.write_text('check b = case b of True -> Unit | False -> error "float equality".\n'
                      'main = nan = f64frombits 2146959360 0; xs = [nan]; '
                      '_ = check (xs != xs); '
                      '_ = check ([0.0] == [f64frombits 2147483648 0]); Unit.\n')
    build(source)
    boot()
    print('Float-field equality preserves NaN and signed-zero semantics: PASS')

    prelude = tmp/'prelude.fpr'
    prelude.write_text('flipBits w = Word.not w.\n')
    source = tmp/'import.fpr'
    source.write_text('main = print (Word.toInt (flipBits (Word.fromInt 0))).\n')
    build(source, f'FPRC_FLAGS=--prelude={prelude}')
    assert '-1' in boot()
    assert (tmp/'builtin.s.units').read_text() == '', 'ARC must analyze imported representations together'
    print('Imported function shares raw calling convention: PASS')

    source = tmp/'bad-representation.fpr'
    source.write_text('identity x = x.\nmain = _ = identity 1; identity (Word.fromInt 1).\n')
    output = run(['./fprc', '--profile=bare-metal-builtin', '--arc', source, tmp/'bad.s'], 1)
    assert 'incompatible representations' in output or 'cannot unify Int with Word' in output
    print('Conflicting representation instantiations rejected: PASS')

    build('tests/builtin_interrupt.fpr',
          'BUILTIN_EXTRA=tests/builtin_interrupt_probe.S tests/builtin_interrupt_probe.c',
          'BUILTIN_LDFLAGS=-Wl,--wrap=fpr_fn_main,--wrap=fpr_fn_machineInterrupt')
    assert 'INTERRUPTS RESUME' in boot()
    print('All GPR/FPR state and fcsr restored; 1,000 resumed interrupts with ARC work: PASS')

    # Exhaustive branches compile with a fatal fallback in Core; that fallback
    # is non-returning and allocation-free, so ordinary handler dispatch is legal.
    source = tmp/'branch.fpr'
    source.write_text('machineInterrupt c p v = case Word.bitTest c 63 of True -> Unit | False -> Unit.\n'
                      'main = Unit.\n')
    build(source)
    boot()
    run(['./fprc', '--profile=bare-metal-builtin', source, tmp/'manual.s'], 1)

    failures = {
        'allocation': 'Mem.alloc 8',
        'construction': '[1, 2]',
        'reentrant': 'CPU.irqEnable Unit',
        'csr-control': 'CPU.csrWrite 768 (Word.fromInt 8)',
        'print': 'print 1',
        'transitive': 'helper Unit',
    }
    for name, expr in failures.items():
        source = tmp/f'{name}.fpr'
        source.write_text('helper u = Mem.alloc 8.\n'
                          f'machineInterrupt c p v = _ = {expr}; Unit.\nmain = Unit.\n')
        output = run(['./fprc', '--profile=bare-metal-builtin', '--arc', source, tmp/f'{name}.s'], 1)
        assert 'interrupt contract' in output, output
    print('Handler allocation/control restrictions checked through helper calls: PASS')

    # Faulting inside a handler must use the emergency fatal path, never recurse
    # through the suspended-program stack held in mscratch.
    source = tmp/'handler-fault.fpr'
    source.write_text('machineInterrupt c p v = _ = CPU.csrRead 4095; Unit.\n'
                      'main = _ = CPU.csrWrite 772 (Word.fromInt 8); '
                      '_ = Mem.write32 (Addr.fromWord (Word.fromInt 33554432)) (Word.fromInt 1); '
                      'CPU.irqEnable Unit.\n')
    build(source)
    assert 'mcause=0x0000000000000002' in boot(1)
    print('Synchronous fault within handler reaches fatal emergency stack: PASS')
