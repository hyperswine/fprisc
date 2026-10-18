#!/usr/bin/env python3
"""Refuse linked libraries requiring ISA extensions absent from this board."""
import argparse
import re
import subprocess
import sys

def check(report, compressed=False, xlen=64):
    if xlen not in (32, 64):
        raise ValueError('board XLEN must be 32 or 64')
    if f'ELF{xlen}' not in report or "little endian" not in report:
        raise ValueError(f'board requires a little-endian ELF{xlen} image')
    flags = re.search(r'Flags:\s+(0x[0-9a-f]+)', report)
    arch = re.search(r'Tag_RISCV_arch:\s+"([^"]+)"', report)
    if not flags or int(flags[1], 16) not in ((0, 1) if compressed else (0,)) or not arch:
        raise ValueError('board requires a soft-float ABI and explicitly selected compressed instructions')
    extensions = arch[1].split('_')
    allowed = (f'rv{xlen}i', 'm', 'zicsr', 'zifencei', 'zmmul') + (('c',) if compressed else ())
    for extension in extensions:
        if not any(re.fullmatch(name + r'\d+p\d+', extension) for name in allowed):
            raise ValueError(f'unsupported board ISA extension: {extension}')
    if not extensions[0].startswith(f'rv{xlen}i') or not any(re.fullmatch(r'm\d+p\d+', e) for e in extensions):
        raise ValueError(f'board image must declare RV{xlen}IM')

if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('image')
    p.add_argument('--xlen', type=int, choices=(32, 64), default=64)
    p.add_argument('--compressed', action='store_true')
    a = p.parse_args()
    report = subprocess.check_output(['riscv64-unknown-elf-readelf', '-Ah', a.image], text=True)
    check(report, compressed=a.compressed, xlen=a.xlen)
    print(f'PASS: linked ELF uses the selected RV{a.xlen}IM/IMC soft-float ABI; no A/F/D libraries')
