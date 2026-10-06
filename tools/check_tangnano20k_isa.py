#!/usr/bin/env python3
"""Refuse linked libraries requiring ISA extensions absent from this board."""
import re
import subprocess
import sys

def check(report):
    if 'ELF64' not in report or "little endian" not in report:
        raise ValueError('board requires a little-endian ELF64 image')
    flags = re.search(r'Flags:\s+(0x[0-9a-f]+)', report)
    arch = re.search(r'Tag_RISCV_arch:\s+"([^"]+)"', report)
    if not flags or int(flags[1], 16) != 0 or not arch:
        raise ValueError('board requires LP64 without compressed instructions')
    extensions = arch[1].split('_')
    allowed = ('rv64i', 'm', 'zicsr', 'zifencei', 'zmmul')
    for extension in extensions:
        if not any(re.fullmatch(name + r'\d+p\d+', extension) for name in allowed):
            raise ValueError(f'unsupported board ISA extension: {extension}')
    if not extensions[0].startswith('rv64i') or not any(re.fullmatch(r'm\d+p\d+', e) for e in extensions):
        raise ValueError('board image must declare RV64IM')

if __name__ == '__main__':
    report = subprocess.check_output(['riscv64-unknown-elf-readelf', '-Ah', sys.argv[1]], text=True)
    check(report)
    print('PASS: linked ELF uses RV64IM/Zicsr/Zifencei, LP64; no A/C/F/D libraries')
