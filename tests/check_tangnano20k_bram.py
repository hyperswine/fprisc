#!/usr/bin/env python3
"""Check BRAM near-capacity/OOM fixtures against actual IM and IMC link bounds.

The board images are linked normally, then their generated FP-RISC assembly
executes on QEMU's virt UART/finisher adapter with exactly the same heap start
and end. Test code/BSS lives outside that BRAM window so adapter size cannot
change admission. This tests heap bounds and recovery, not FPGA execution.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('scalar_gate', ROOT / 'tests/check_riscv_scalar.py')
scalar = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scalar)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--fixtures-dir', type=Path, default=ROOT / 'tests/tangnano20k_stress')
args = parser.parse_args()
environment = {**scalar.ENV, 'FPR_NO_INDEXED_MEMORY': '0'}
rows = []
with tempfile.TemporaryDirectory(prefix='fpr-bram-bounds-') as temp:
    directory = Path(temp)
    for compressed in (False, True):
        for name in ('tree_near', 'tree_limit'):
            out = directory / ('imc' if compressed else 'im') / name
            out.mkdir(parents=True)
            source = args.fixtures_dir / (name + '.fpr')
            nodes = int(re.search(r'tree = build 1 (\d+)', source.read_text())[1])
            image = out / 'board.elf'
            scalar.run(['make', '-s', 'bare-metal-builtin', 'BUILTIN_BOARD=tangnano20k',
                        'BUILTIN_RAM=bram', f'BUILTIN_RVC={int(compressed)}',
                        f'PROG={source}', f'BUILD={out}', f'IMAGE={image}'], environment)
            symbols = scalar.run(['riscv64-unknown-elf-nm', image])
            def symbol(n):
                return int(re.search(rf'^([0-9a-f]+) \w {n}$', symbols, re.M)[1], 16)
            low, high = (symbol('_heap_start') + 15) & ~15, symbol('_heap_end') & ~15
            bitmap = ((((high - low) // 16 + 7) // 8) + 15) & ~15
            usable = high - low - bitmap
            # RV32 Node: 8-byte header + three 4-byte fields ->32-byte payload;
            # the preserved eight-word block header +16-byte preheader is48.
            occupied = nodes * 80
            if name == 'tree_near':
                assert occupied + 512 <= usable, ('near fixture lacks safety margin', compressed, occupied, usable)
            else:
                assert occupied >= usable + 1024, ('OOM fixture lacks safety margin', compressed, occupied, usable)
            scalar.setup(out, 32)
            link = out / 'link.ld'
            link.write_text('''
OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY {
 BOOT (rx) : ORIGIN = 0x80000000, LENGTH = 4K
 CODE (rwx) : ORIGIN = 0x80400000, LENGTH = 4M
}
SECTIONS {
 .text.entry : { KEEP(*(.text.entry)) } > BOOT
 .text : { *(.text .text.*) } > CODE
 .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > CODE
 .data : { *(.data .data.*) PROVIDE(__global_pointer$ = . + 0x800); *(.sdata .sdata.*) } > CODE
 .bss (NOLOAD) : { . = ALIGN(16); _bss_start = .; *(.bss .bss.* .sbss .sbss.* COMMON) . = ALIGN(16); _bss_end = .; } > CODE
''' + f'_heap_start = {low}; _heap_end = {high}; _stack_top = 0x80010000;\n' + '}\n')
            asm = out / 'builtin.s'
            units = Path(str(asm) + '.units').read_text().splitlines()
            guest = out / 'qemu.elf'
            scalar.run(['riscv64-unknown-elf-gcc',
                        '-march=rv32im' + ('c' if compressed else '') + '_zicsr_zifencei',
                        '-mabi=ilp32', '-mcmodel=medany', '-Os', '-ffreestanding', '-nostdlib',
                        '-nostartfiles', '-fno-builtin', '-DFPR_NHARTS=1', '-DFPR_BUILTIN',
                        '-DFPR_SIMPLE_RISC', '-DFPR_BUILTIN_HEAP_MAX_BYTES=65536',
                        '-ffunction-sections', '-fdata-sections', '-Wl,--gc-sections',
                        '-Wl,--no-warn-rwx-segments', '-I', 'runtime', '-I', 'machine/builtin',
                        '-T', link, out / 'crt.S', out / 'host.c', 'machine/builtin/heap.c',
                        'machine/builtin/unsafe.c', 'machine/builtin/tangnano20k/machine.c',
                        'runtime/runtime.c', 'runtime/bits.c', 'machine/virt/memshim.c',
                        asm, *units, '-o', guest], environment)
            output = scalar.execute(32, guest, 0 if name == 'tree_near' else 1)
            if name == 'tree_near':
                expected = f'BEGIN tree_near\nTREE nodes={nodes} rounds=8 sum={nodes*(nodes+1)//2}\n'
                assert output == expected, output
            else:
                assert output == 'BEGIN tree_limit\nBuiltin: out of memory\n', output
            rows.append({'mode': 'IMC' if compressed else 'IM', 'fixture': name,
                         'nodes': nodes, 'arena_bytes': high-low, 'bitmap_bytes': bitmap,
                         'usable_block_bytes': usable, 'node_bytes': occupied,
                         'margin_bytes': usable-occupied})
print(json.dumps(rows, indent=2))
print('BRAM IM/IMC near-capacity success and explicit exhaustion at actual linked heap bounds: PASS')
