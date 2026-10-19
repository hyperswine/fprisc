#!/usr/bin/env python3
"""Sanitized graph collector and real RV32/RV64 board root-capture adapter.

No FPGA programming. QEMU uses the same linker/root/register sources as the
board. Collection before every allocation stresses C register/stack liveness.
"""
from pathlib import Path
import argparse
import json
import subprocess
import tempfile
from check_builtin_heap_index import START, HAL

ROOT = Path(__file__).resolve().parents[1]


def run(cmd, expected=0, timeout=120):
    p = subprocess.run([str(x) for x in cmd], cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    assert p.returncode == expected, (cmd, p.returncode, p.stdout, p.stderr)
    return p.stdout+p.stderr


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--classifier-report', type=Path, action='append', default=[],
                        help='also gate a completed 10-run 512-row classifier results.json')
    args=parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='fpr-board-gc-') as tmp:
        tmp = Path(tmp)
        flags = ['-Iruntime', '-Imachine/builtin', '-DFPR_BUILTIN_GC', '-Wall', '-Wextra', '-Werror']
        native = tmp/'native'
        run(['clang', *flags, '-DFPR_POSIX', '-O2', '-g', '-fsanitize=address,undefined',
             'tests/builtin_gc.c', 'machine/builtin/heap.c', '-o', native])
        assert 'CONSERVATIVE HEAP HOLDS' in run([native])
        assert 'Builtin: out of memory' in run([native, 'live-oom'], expected=3)
        print('Native ASan/UBSan: graph, cycles, interior/one-past pointers, pressure, coalescing and live OOM PASS', flush=True)
        (tmp/'start.S').write_text(START)
        (tmp/'hal.c').write_text(HAL)
        for xlen in (32,64):
            elf=tmp/f'roots{xlen}.elf'
            command=['riscv64-unknown-elf-gcc', *flags, f'-march=rv{xlen}im',
                 f'-mabi={"ilp32" if xlen==32 else "lp64"}', '-mcmodel=medany', '-O2',
                 '-ffreestanding', '-fno-builtin', '-nostdlib', '-nostartfiles',
                 '-DFPR_BUILTIN_GC_STRESS=1', '-DFPR_BUILTIN_HEAP_MAX_BYTES=8388608',
                 '-Wl,--no-warn-rwx-segments', '-T', 'machine/tangnano20k/link.ld',
                 tmp/'start.S', tmp/'hal.c', 'tests/tangnano20k_gc_roots.c',
                 'tests/tangnano20k_gc_registers.S', 'machine/tangnano20k/gc_registers.S',
                 'machine/tangnano20k/gc_roots.c', 'machine/builtin/heap.c', '-o', elf]
            run(command)
            emulator=[f'qemu-system-riscv{xlen}', '-machine','virt','-m','8M','-bios','none',
                      '-kernel',elf,'-display','none','-monitor','none','-serial','stdio']
            out=run(emulator)
            assert 'RISCV GC ROOTS HOLD' in out, out
            print(f'RV{xlen}: caller/callee registers, stack, static roots, realloc and pressure PASS', flush=True)
            broken=tmp/'missing-register.S'
            source=(ROOT/'machine/tangnano20k/gc_registers.S').read_text()
            assert source.count('SAVE x30,30*W(sp)')==1
            broken.write_text(source.replace('SAVE x30,30*W(sp)', 'SAVE zero,30*W(sp)'))
            command[command.index('machine/tangnano20k/gc_registers.S')]=broken
            run(command)
            assert 'GC ROOT CHECK FAILED' in run(emulator, expected=1)
            print(f'RV{xlen}: missing caller-register root is rejected PASS', flush=True)
    for path in args.classifier_report:
        report=json.loads(path.read_text())
        assert report['repeats']>=10 and report['reference']['train_rows']==512
        assert report['reference']['test_rows']==128 and report['reference']['bins']==16
        assert report['reference']['max_depth']==6 and report['reference']['min_leaf']==5
        execution=report['executions'].get('board', report['executions'].get('qemu'))
        assert execution and execution['passed'] and len(execution['elapsed_us_runs'])==report['repeats']
        samples=execution['heap_samples'];assert len(samples)>2
        limit=execution['usable_heap_block_bytes'];assert limit<8*1024*1024
        assert all(s['peak']<=limit for s in samples)
        # Each GC line precedes the final exit snapshot. Bound retained data,
        # not total churn; exercise reclamation of much more than one arena.
        assert max(s['live'] for s in samples[:-1])<1024*1024
        assert samples[-1]['reclaimed']>10*limit and samples[-1]['collections']>=10
        print(f'{path}: repeated classifier exact results and bounded retained heap PASS',flush=True)


if __name__=='__main__':
    main()
