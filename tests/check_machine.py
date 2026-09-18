#!/usr/bin/env python3
"""Machine-mode RV64 integration: instruction effects, failures and IRQ delivery."""
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


def boot(image, expected=0):
    return run(['qemu-system-riscv64', '-machine', 'virt', '-m', '128M', '-nographic',
                '-bios', 'none', '-kernel', image], expected, timeout=15)


def build(source, image, directory, arc=1):
    return run(['make', 'bare-metal-builtin', f'ARC={arc}', f'ARC_CHECK={arc}',
                f'PROG={source}', f'IMAGE={image}', f'BUILD={directory}'])


run(['make', 'fpr'], timeout=300)
with tempfile.TemporaryDirectory(prefix='fpr-machine-') as temp:
    tmp = Path(temp)
    image = tmp/'machine.elf'
    build('tests/builtin_machine.fpr', image, tmp)
    assert 'MACHINE PRIMITIVES HOLD' in boot(image)
    dump = run(['riscv64-unknown-elf-objdump', '-d', image])
    for instruction in ['amoswap.d.aqrl', 'lr.d.aq', 'sc.d.rl', 'fence.i']:
        assert instruction in dump, instruction
    assert not run(['riscv64-unknown-elf-nm', '-u', image]).strip()
    print('Bits, full-width CSR access, atomic success/failure, nested IRQ masks and fences: PASS')

    # The same APIs are callable through the ordinary/manual PAP ABI.
    manual = tmp/'manual.fpr'
    manual.write_text(Path('tests/builtin_machine.fpr').read_text().replace(
        '  _ = check (Mem.liveAllocations Unit == 0);\n', ''))
    build(manual, image, tmp, arc=0)
    assert 'MACHINE PRIMITIVES HOLD' in boot(image)
    print('Manual profile ABI: PASS')

    cases = [
        ('csr-large', 'CPU.csrRead 4096', 'CSR number out of range'),
        ('csr-negative', 'CPU.csrRead -1', 'CSR number out of range'),
        ('bit-range', 'Word.bitSet (Word.fromInt 0) 64', 'shift out of range'),
        ('irq-token', 'CPU.irqRestore 1', 'invalid IRQ token'),
        ('atomic-alignment', 'Mem.atomicExchange (Addr.fromWord (Word.fromInt 3)) (Word.fromInt 1)',
         'unaligned access'),
        # Architectural read-only CSR write must trap, not silently succeed.
        ('csr-readonly', 'CPU.csrWrite 3072 (Word.fromInt 0)', 'mcause=0x0000000000000002'),
        # CLINT MSIP: a real machine software interrupt on QEMU virt.
        ('software-irq', '_ = CPU.csrWrite 772 (Word.fromInt 8); '
         '_ = Mem.write32 (Addr.fromWord (Word.fromInt 33554432)) (Word.fromInt 1); '
         'CPU.irqEnable Unit', 'mcause=0x8000000000000003'),
    ]
    for name, expr, message in cases:
        source = tmp/f'{name}.fpr'
        source.write_text(f'main = {expr}.\n')
        build(source, image, tmp)
        assert message in boot(image, 1), name
    print('Bad arguments, hardware CSR fault and actual software-interrupt delivery: PASS')
