#!/usr/bin/env python3
"""Allocator geometry against guarded execution, sanitizers and both XLENs."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

from check_builtin_heap_index import START, HAL, LINK

ROOT = Path(__file__).resolve().parents[1]


def run(args, expected=0):
    p = subprocess.run(list(map(str,args)),cwd=ROOT,capture_output=True,text=True,timeout=120)
    assert p.returncode==expected,(args,p.returncode,p.stdout,p.stderr)
    return p.stdout+p.stderr


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--require-execution',action='store_true')
    ap.add_argument('--record',type=Path)
    args=ap.parse_args()
    sources=['machine/builtin/heap.c','machine/builtin/builtin.h','tests/builtin_heap_geometry.c',
             'tests/check_builtin_heap_geometry.py','tests/check_builtin_heap_index.py']
    record=dict(schema='builtin-heap-geometry-v1',sources={n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in sources},checks=[])
    with tempfile.TemporaryDirectory(prefix='fpr-heap-geometry-') as directory:
        out=Path(directory)
        common=['-std=c11','-Iruntime','-Imachine/builtin','-Wall','-Wextra','-Werror',
                '-DFPR_BUILTIN_ARC','-DFPR_BUILTIN_HEAP_STATS']
        fixture=ROOT/'tests/builtin_heap_geometry.c'
        heap=ROOT/'machine/builtin/heap.c'
        host=out/'host'
        run(['clang',*common,'-DFPR_POSIX','-fsanitize=address,undefined','-g',fixture,heap,'-o',host])
        output=run([host])
        assert 'BUILTIN HEAP GEOMETRY HOLDS' in output,output
        negative=run([host,'short'],3)
        assert 'SHORT ARENA REFUSED WITHOUT LOST PAYLOADS' in negative,negative
        record['checks'].append(dict(target='host-asan-ubsan',status='PASS',output=output,short_arena=negative))
        run(['clang',*common,'-DFPR_POSIX','-DFPR_BUILTIN_HEAP_MAX_BYTES=65536',
             '-fsanitize=address,undefined','-g',fixture,heap,'-o',host])
        bounded=run([host])
        assert 'BUILTIN HEAP GEOMETRY HOLDS' in bounded,bounded
        record['checks'].append(dict(target='host-asan-ubsan-64k',status='PASS',output=bounded))
        print('Host ASan/UBSan: geometry, observed blocks, exact/short fixed arena PASS',flush=True)
        (out/'start.S').write_text(START)
        (out/'hal.c').write_text(HAL)
        (out/'link.ld').write_text(LINK)
        for width in (32,64):
            missing=[t for t in ('riscv64-unknown-elf-gcc',f'qemu-system-riscv{width}') if not shutil.which(t)]
            if missing:
                assert not args.require_execution,missing
                record['checks'].append(dict(target=f'rv{width}',status='SKIP',missing=missing))
                continue
            images={}
            outputs={}
            for mode in ('exact','short'):
                image=out/f'{width}-{mode}.elf'
                run(['riscv64-unknown-elf-gcc','-ffixed-x27',*common,f'-march=rv{width}im_zicsr',
                     '-mabi='+('ilp32' if width==32 else 'lp64'),'-mcmodel=medany','-Os','-ffreestanding',
                     '-fno-builtin','-nostdlib','-nostartfiles','-DFPR_BUILTIN','-DHEAP_FREESTANDING',
                     '-DFPR_BUILTIN_HEAP_MAX_BYTES=65536',
                     *(['-DHEAP_CASE'] if mode=='short' else []),'-ffunction-sections','-fdata-sections',
                     '-Wl,--gc-sections','-T',out/'link.ld',out/'start.S',out/'hal.c',fixture,heap,
                     ROOT/'machine/virt/memshim.c','-lgcc','-o',image])
                output=run([f'qemu-system-riscv{width}','-machine','virt','-smp','1','-m','16M',
                            '-nographic','-bios','none','-kernel',image],3 if mode=='short' else 0)
                marker='SHORT ARENA REFUSED WITHOUT LOST PAYLOADS' if mode=='short' else 'BUILTIN HEAP GEOMETRY HOLDS'
                assert marker in output,output
                images[mode]=hashlib.sha256(image.read_bytes()).hexdigest();outputs[mode]=output
            record['checks'].append(dict(target=f'rv{width}',status='PASS',configured_maximum_bytes=65536,image_sha256=images,output=outputs))
            print(f'RV{width} QEMU: geometry, observed blocks, exact/short fixed arena PASS',flush=True)
    if args.record:
        args.record.write_text(json.dumps(record,indent=2)+'\n')


if __name__=='__main__':
    main()
