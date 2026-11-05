#!/usr/bin/env python3
"""Compare the builtin heap's allocation/release work at a git revision.

Both heaps use the same uninstrumented fixture, compiler flags and QEMU icount
configuration. Counts are deterministic guest instructions, not hardware cycles
or wall time. Setup/heap initialization and printing are outside each sample.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tests'))
from check_builtin_heap_index import START,HAL,LINK,run


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--baseline-ref',required=True)
    ap.add_argument('--record',type=Path)
    args=ap.parse_args()
    revision=run(['git','rev-parse','--verify',args.baseline_ref+'^{commit}']).strip()
    baseline=run(['git','show',revision+':machine/builtin/heap.c'])
    current=ROOT/'machine/builtin/heap.c'
    fixture=ROOT/'tests/builtin_heap_index.c'
    flags=['-std=c11','-Iruntime','-Imachine/builtin','-Wall','-Wextra','-Werror','-Wno-unused-function',
           '-mcmodel=medany','-Os','-ffreestanding','-fno-builtin','-nostdlib','-nostartfiles',
           '-DFPR_BUILTIN','-DFPR_BUILTIN_ARC','-DHEAP_FREESTANDING','-DHEAP_WORK_ONLY',
           '-ffunction-sections','-fdata-sections','-Wl,--gc-sections']
    record=dict(schema='builtin-heap-cost-v1',baseline_revision=revision,
                baseline_heap_sha256=hashlib.sha256(baseline.encode()).hexdigest(),
                heap_sha256=hashlib.sha256(current.read_bytes()).hexdigest(),
                fixture_sha256=hashlib.sha256(fixture.read_bytes()).hexdigest(),
                tool_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                compiler=run(['riscv64-unknown-elf-gcc','--version']).splitlines()[0],
                flags=flags,measure='deterministic guest instruction counts; no statistics/lookup counters; not hardware cycles or wall time',records=[])
    with tempfile.TemporaryDirectory(prefix='fpr-heap-cost-') as directory:
        out=Path(directory)
        for name,text in [('start.S',START),('hal.c',HAL),('link.ld',LINK),('before.c',baseline)]:
            (out/name).write_text(text)
        for width in (32,64):
            arch=[f'-march=rv{width}im_zicsr','-mabi='+('ilp32' if width==32 else 'lp64')]
            qemu=[f'qemu-system-riscv{width}','-machine','virt','-smp','1','-m','16M',
                  '-nographic','-bios','none','-icount','shift=0,sleep=off']
            samples={}
            for name,source in [('before',out/'before.c'),('after',current)]:
                image=out/f'{width}-{name}.elf'
                run(['riscv64-unknown-elf-gcc',*flags,*arch,'-T',out/'link.ld',out/'start.S',out/'hal.c',
                     fixture,source,ROOT/'machine/virt/memshim.c','-lgcc','-o',image])
                output=run([*qemu,'-kernel',image])
                counts={n:int(c) for n,c in re.findall(r'HEAP WORK nodes=(\d+) cycles=(\d+)',output)}
                assert set(counts)=={'512','2048','8192'} and 'INDEXED BUILTIN HEAP HOLDS' in output,output
                samples[name]=dict(guest_instruction_counts=counts,image_sha256=hashlib.sha256(image.read_bytes()).hexdigest())
            ratios={n:samples['after']['guest_instruction_counts'][n]/c for n,c in samples['before']['guest_instruction_counts'].items()}
            record['records'].append(dict(target=f'rv{width}',architecture_flags=arch,qemu_command=qemu,
                                          qemu_version=run([qemu[0],'--version']).splitlines()[0],samples=samples,ratios=ratios))
            print(f'RV{width}: after/before guest instruction counts {ratios}',flush=True)
    if args.record:
        args.record.write_text(json.dumps(record,indent=2)+'\n')


if __name__=='__main__':
    main()
