#!/usr/bin/env python3
"""Compile and check larger FP-RISC workloads on a physical SimpleRisc board.

Times run from the program's BEGIN line to its verified exit, excluding UART
upload and startup. One exclusive UART session covers the whole suite.
"""
import argparse
import importlib.util
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import select
import subprocess
import time
import os
import sys

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('simple_risc_loader', ROOT / 'tools/run_simple_risc.py')
loader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(loader)


def references():
    composite = bytearray(36001)
    for p in range(2, 190):
        if not composite[p]:
            for k in range(p*p, 36001, p):
                composite[k] = 1
    primes = [p for p in range(2, 36001) if not composite[p]]
    values, state = [], 123
    for _ in range(8192):
        state = (state * 109 + 89) % 65536
        values.append(state)
    def digest(xs):
        h = 0
        for x in xs:
            h = (h*257+x) % 1000003
        return h
    matrix = [sum(((r*k+3*r+5*k) % 17) * ((k+2*c+7) % 19)
                  for k in range(64)) for r in range(64) for c in range(64)]
    state, checksum = 123, 0
    for _ in range(1000000):
        state = (state*109+89) % 65521
        checksum = (checksum+state) % 1000003
    return {
        'sieve': (f'SIEVE primes={len(primes)} sum={sum(primes)}', 36001),
        'sort': (f'SORT n=8192 hash={digest(sorted(values))}', 32768),
        'matrix': (f'MATRIX n=64 hash={digest(matrix)} sum={sum(matrix)}', 24576),
        'tree': (f'TREE nodes=447 rounds=8 sum={447*448//2}', 447*80),
        'tree_near': (f'TREE nodes=500 rounds=8 sum={500*501//2}', 500*80),
        'tree_limit': ('Builtin panic: Builtin: out of memory', 600*80),
        'compute': (f'COMPUTE iterations=1000000 checksum={checksum}', 0),
    }


def compile_program(name, directory, ram='bram', compressed=False, legacy=False, baseline_heap=None):
    image = directory / name / 'program.elf'
    environment = dict(os.environ)
    environment.update(FPR_NO_RV32_FAST=str(int(legacy)),
                       FPR_NO_INDEXED_MEMORY=str(int(legacy)))
    extra = []
    if baseline_heap:
        image.parent.mkdir(parents=True, exist_ok=True)
        old_heap = image.parent / 'baseline-heap.c'
        old_heap.write_text(subprocess.check_output(['git', 'show', baseline_heap+':machine/builtin/heap.c'], cwd=ROOT, text=True))
        runtime = ['machine/builtin/tangnano20k/crt0.S','machine/builtin/tangnano20k/board.c',
                   'machine/builtin/tangnano20k/machine.c',str(old_heap),'machine/builtin/unsafe.c',
                   'runtime/runtime.c','runtime/bits.c','machine/virt/memshim.c']
        extra = ['BUILTIN_RT='+' '.join(runtime)]
    p = subprocess.run(['make', 'bare-metal-builtin', 'BUILTIN_BOARD=tangnano20k',
                        'BUILTIN_RAM='+ram, 'BUILTIN_RVC='+str(int(compressed)), *extra,
                        f'PROG=tests/tangnano20k_stress/{name}.fpr',
                        f'BUILD={image.parent}', f'IMAGE={image}'], cwd=ROOT,
                       capture_output=True, text=True, timeout=180, env=environment)
    if p.returncode:
        raise RuntimeError(p.stdout+p.stderr)
    symbols = subprocess.check_output(['riscv64-unknown-elf-nm', str(image)], text=True)
    def symbol(n):
        return int(re.search(rf'^([0-9a-f]+) \w {n}$', symbols, re.M)[1], 16)
    heap = symbol('_heap_end')-symbol('_heap_start')
    binary = image.with_suffix('.bin').read_bytes()
    return binary, heap


def run(fd, name, image, expected, baud, timeout, exit_code=0):
    loader.write_all(fd, b'X', 2)
    loader.receive(fd, .02)
    data = loader.frame(image)
    loader.write_all(fd, data, max(3, len(data)*10/baud+3))
    output = bytearray()
    begun = None
    deadline = time.monotonic()+timeout
    last_report = time.monotonic()
    while time.monotonic() < deadline:
        if select.select([fd], [], [], .05)[0]:
            chunk = os.read(fd, 4096)
            output.extend(chunk)
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
            if begun is None and f'BEGIN {name}\n'.encode() in output:
                begun = time.monotonic()
            if output.endswith(b'DONE'):
                break
        if time.monotonic()-last_report >= 30:
            print(f'\n[{name}: still running, {time.monotonic()-(begun or last_report):.1f} s]', flush=True)
            last_report = time.monotonic()
    elapsed = time.monotonic()-begun if begun is not None else None
    want = f'BEGIN {name}\n{expected}\nFPR EXIT {exit_code}\nDONE'.encode()
    if bytes(output) != want:
        raise RuntimeError(f'{name}: expected {want!r}, got {bytes(output[:500])!r}')
    print(f'\nPASS {name}: {elapsed:.3f} seconds', flush=True)
    return elapsed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', required=True)
    parser.add_argument('--freq-mhz', type=float, default=96)
    parser.add_argument('--timeout', type=float, default=180)
    parser.add_argument('--repeat', type=int, default=1)
    parser.add_argument('--ram', choices=['bram','sdram'], default='bram')
    parser.add_argument('--compressed', action='store_true', help='requires a compressed-capable FPGA image')
    parser.add_argument('--legacy-codegen', action='store_true', help='same compiler with RV32 fast paths and indexed fusion disabled')
    parser.add_argument('--baseline-heap-ref', help='compare against the C heap at this local git revision')
    parser.add_argument('--only', choices=['sieve','sort','matrix','tree','tree_near','tree_limit','compute'])
    parser.add_argument('--report', type=Path, default=ROOT / 'build/tangnano20k-stress/results.json')
    args = parser.parse_args()
    if args.freq_mhz <= 0 or args.timeout <= 0 or args.repeat < 1:
        parser.error('frequency, timeout and repeat must be positive')
    refs = references()
    names = [args.only] if args.only else list(refs)
    if args.ram == 'sdram' and not args.only:
        # The original BRAM exhaustion sizes are deliberately not OOM in 8 MiB.
        names = [name for name in names if name not in ('tree_near','tree_limit')]
    if args.ram == 'sdram' and args.only == 'tree_limit':
        parser.error('tree_limit is a 64 KiB BRAM exhaustion fixture')
    programs = {}
    for name in names:
        mode = args.ram + ('-c' if args.compressed else '-im') + ('-legacy' if args.legacy_codegen else '-fast')
        image, heap = compile_program(name, ROOT / 'build/tangnano20k-stress' / mode,
                                      args.ram, args.compressed, args.legacy_codegen, args.baseline_heap_ref)
        programs[name] = (image, heap)
        print(f'Built {name}: image {len(image)} B; heap {heap} B; workload {refs[name][1]} B', flush=True)
    baud = round(args.freq_mhz*1e6/868)
    rows = []
    complete = False
    fd = loader.open_port(args.port, baud)
    try:
        loader.write_all(fd, b'\x03', 2)
        loader.receive(fd, .1)
        for iteration in range(args.repeat):
            for name in names:
                image, heap = programs[name]
                exit_code = 1 if name == 'tree_limit' else 0
                elapsed = run(fd, name, image, refs[name][0], baud, args.timeout, exit_code)
                rows.append({'program':name, 'run':iteration+1, 'seconds':elapsed,
                             'expected_exit':exit_code, 'image_bytes':len(image), 'heap_bytes':heap,
                             'workload_bytes':refs[name][1], 'expected':refs[name][0]})
        complete = True
    finally:
        try:
            loader.write_all(fd, b'\x03', 2)
            loader.receive(fd, .25)
        finally:
            os.close(fd)
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps({'finished_at':datetime.now(timezone.utc).isoformat(),
                                          'frequency_mhz':args.freq_mhz, 'complete':complete,
                                          'ram':args.ram, 'compressed':args.compressed,
                                          'legacy_codegen':args.legacy_codegen, 'baseline_heap_ref':args.baseline_heap_ref,
                                          'requested_runs':len(names)*args.repeat, 'passed_runs':rows}, indent=2)+'\n')
    print(f'PASS: {len(rows)} physical FP-RISC workload runs at {args.freq_mhz:g} MHz')


if __name__ == '__main__':
    main()
