#!/usr/bin/env python3
"""Build FP-RISC's SimpleRisc CSR fixture; optionally run it on the board."""
import argparse
from pathlib import Path
import re
import tempfile
from check_tangnano20k import command, ROOT


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port')
    parser.add_argument('--freq-mhz', type=float, default=96)
    args = parser.parse_args()
    command(['make', 'fpr'], timeout=300)
    with tempfile.TemporaryDirectory(prefix='fpr-tang-csr-') as directory:
        path = Path(directory)
        elf = path / 'csr.elf'
        command(['make', 'bare-metal-builtin', 'BUILTIN_BOARD=tangnano20k',
                 f'PROG={ROOT / "tests/builtin_tangnano20k_csr.fpr"}',
                 f'BUILD={path}', f'IMAGE={elf}'])
        assert not command(['riscv64-unknown-elf-nm', '-u', elf]).strip()
        assembly = command(['riscv64-unknown-elf-objdump', '-d', elf])
        assert re.search(r'\tcsrr\s+', assembly)
        assert re.search(r'\tcsrw\s+', assembly)
        binary = elf.with_suffix('.bin')
        assert 0 < binary.stat().st_size <= 65536
        print('PASS: FP-RISC RV32 CSR compilation, link and image bounds', flush=True)
        if not args.port:
            print('Hardware: SKIPPED (supply --port)')
            return
        for run in range(3):
            output = command(['python3', 'tools/run_simple_risc.py', binary,
                              '--port', args.port, '--freq-mhz', args.freq_mhz,
                              '--timeout', '15'])
            assert 'TANG NANO CSR HOLDS\nFPR EXIT 0\nDONE' in output, output
            print(f'PASS: FP-RISC CSR hardware run {run + 1}', flush=True)


if __name__ == '__main__':
    main()
