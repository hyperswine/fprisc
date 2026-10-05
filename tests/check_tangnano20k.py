#!/usr/bin/env python3
"""RV32 builtin port checks. Add --port PORT for physical SimpleRisc tests."""
import argparse
from pathlib import Path
import os
import pty
import re
import select
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)


def command(args, expected=0, timeout=90):
    p = subprocess.run(list(map(str, args)), capture_output=True, text=True, timeout=timeout)
    assert p.returncode == expected, f'{args}: exit {p.returncode}\n{p.stdout}\n{p.stderr}'
    return p.stdout + p.stderr


def loader_probe(image, response, expected):
    # A fake UART validates the host's distinction between a CPU halt and a
    # runtime success, plus fragmented reads. It does not validate the FPGA.
    master, slave = pty.openpty()
    p = subprocess.Popen(['python3', 'tools/run_simple_risc.py', str(image),
                          '--port', os.ttyname(slave), '--baud', '115200', '--timeout', '.4'],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        data = b''
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            if select.select([master], [], [], .05)[0]:
                data += os.read(master, 65536)
            if b'P\x01\x00\x73\x00\x00\x00R' in data:
                for chunk in (response[:3], response[3:]):
                    os.write(master, chunk)
                    time.sleep(.01)
                break
        else:
            raise AssertionError(f'loader sent no valid frame: {data!r}')
        stdout, stderr = p.communicate(timeout=4)
        assert p.returncode == expected, (stdout, stderr)
    finally:
        if p.poll() is None:
            p.kill()
            p.communicate()
        os.close(master)
        os.close(slave)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port')
    parser.add_argument('--freq-mhz', type=float, default=96)
    args = parser.parse_args()
    command(['make', 'fpr'], timeout=300)
    with tempfile.TemporaryDirectory(prefix='fpr-tangnano20k-') as temp:
        tmp = Path(temp)
        image = tmp / 'builtin.elf'
        binary = image.with_suffix('.bin')
        def build(source, extra=()):
            command(['make', 'bare-metal-builtin', 'BUILTIN_BOARD=tangnano20k',
                     f'PROG={source}', f'BUILD={tmp}', f'IMAGE={image}', *extra])
        source = ROOT / 'tests/builtin_tangnano20k.fpr'
        build(source)
        symbols = command(['riscv64-unknown-elf-nm', image])
        assert not re.search(r'\b(?:fpr_\w*(?:actor|sched|fuel)\w*|buddy_\w*|qos_\w*)\b', symbols)
        assert not command(['riscv64-unknown-elf-nm', '-u', image]).strip()
        disassembly = command(['riscv64-unknown-elf-objdump', '-d', image])
        assert not re.search(r'\t(?:wfi|amo\w*|lr\.w|sc\.w|fadd\S*|fld|fsd)\s', disassembly)
        poweroff = re.search(r'<hal_poweroff>:\n(.*?)(?=\n\n|\Z)', disassembly, re.S)
        assert poweroff, 'linked image must contain the board exit adapter'
        exit_code = poweroff.group(1)
        assert re.search(r'\tlui\s+\w+,0x100\b', exit_code), 'exit must address the finisher'
        assert re.search(r'\tsw\s+\w+,0\(\w+\)', exit_code), 'exit must write the finisher'
        assert not re.search(r'\t(?:ecall|csrw\s+mtvec,)', exit_code), 'exit must preserve guest trap state'
        assert 0 < binary.stat().st_size <= 65536
        assert 'call fpr_fuel_exhausted' not in (tmp / 'builtin.s').read_text()
        rejected = command(['./fprc', '--system=bare-metal', '--profile=builtin',
                            '--target=rv32', '--arc', source, tmp / 'bad.s'], 1)
        assert 'manual ownership only' in rejected
        floating = tmp / 'float.fpr'
        floating.write_text('profile builtin.\nmain = F64.toInt 1.5.\n')
        rejected = command(['./fprc', '--system=bare-metal', '--target=rv32', floating, tmp / 'bad.s'], 1)
        assert 'F64' in rejected and '64-bit value ABI' in rejected, rejected
        dependency = tmp / 'float_dep.fpr'
        dependency.write_text('asInt x = F64.toInt x.\n')
        floating.write_text('profile builtin.\nFloatDep = use "./float_dep".\nmain = Unit.\n')
        rejected = command(['./fprc', '--system=bare-metal', '--target=rv32', floating, tmp / 'bad.s'], 1)
        assert 'F64' in rejected and '64-bit value ABI' in rejected, rejected
        command(['make', '-n', 'bare-metal-builtin', 'BUILTIN_BOARD=tangnano20k', 'ARC=1'], 2)
        oversized = tmp / 'oversized.c'
        oversized.write_text('__attribute__((used,section(".text.entry"))) const char excess[65536] = {1};\n')
        command(['make', 'bare-metal-builtin', 'BUILTIN_BOARD=tangnano20k',
                 f'PROG={source}', f'BUILD={tmp}', f'IMAGE={image}', f'BUILTIN_EXTRA={oversized}'], 2)
        csr_source = ROOT / 'tests/builtin_tangnano20k_csr.fpr'
        build(csr_source)
        csr_disassembly = command(['riscv64-unknown-elf-objdump', '-d', image])
        assert re.search(r'\tcsrr\s+', csr_disassembly), 'CSR runtime reads missing'
        assert re.search(r'\tcsrw\s+', csr_disassembly), 'CSR runtime writes missing'
        assert not command(['riscv64-unknown-elf-nm', '-u', image]).strip()
        print('RV32 link, ISA, CSR code generation, memory bounds and ARC refusals: PASS')
        # Tiny binary for the fake loader; production image rebuilt below.
        probe = tmp / 'probe.bin'
        probe.write_bytes(b'\x73\0\0\0')
        loader_probe(probe, b'FPR EXIT 0\nDONE', 0)
        loader_probe(probe, b'DONE', 1)
        loader_probe(probe, b'FPR EXIT 1\nDONE', 1)
        loader_probe(probe, b'', 1)
        print('UART host success, unexpected halt, panic and timeout: PASS')
        if not args.port:
            print('Physical FPGA tests: SKIPPED (supply --port)')
            return
        def board(expected):
            result = command(['python3', 'tools/run_simple_risc.py', binary, '--port', args.port,
                              '--freq-mhz', args.freq_mhz, '--timeout', '15'], expected)
            return result
        build(source)
        for _ in range(3):
            assert 'TANG NANO BUILTIN HOLDS\nFPR EXIT 0\nDONE' in board(0)
        print('Physical board: three RV32 builtin smoke runs: PASS')
        build(csr_source)
        for _ in range(3):
            assert 'TANG NANO CSR HOLDS\nFPR EXIT 0\nDONE' in board(0)
        print('Physical board: three FP-RISC CSR runs: PASS')
        cases = [
            ('shift', 'Word.shl (Word.fromInt 1) 32', 'shift out of range'),
            ('mask', 'Word.mask 32 1', 'mask out of range'),
            ('unaligned', 'Mem.readWord (Addr.fromWord (Word.fromInt 3))', 'unaligned access'),
            ('exhaustion', 'Mem.alloc 60000', 'out of memory'),
            ('csr', 'CPU.csrRead 0', 'unknown CSR'),
            ('irq', 'CPU.irqSave Unit', 'operations are unsupported'),
            ('atomic', 'Mem.atomicExchange (Mem.alloc 16) (Word.fromInt 1)', 'operations are unsupported'),
        ]
        for name, expr, message in cases:
            failure = tmp / f'{name}.fpr'
            failure.write_text(f'profile builtin.\nmain = {expr}.\n')
            build(failure)
            output = board(1)
            assert message in output and 'FPR EXIT 1\nDONE' in output, output
            print(f'Physical board refusal ({name}): PASS')
        build(source)
        assert 'TANG NANO BUILTIN HOLDS' in board(0)
        print('Physical board recovery after all failures: PASS')


if __name__ == '__main__':
    main()
