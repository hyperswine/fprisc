#!/usr/bin/env python3
"""Fresh-process string scan and JSON scaling, with execution phase samples."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import re
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--baseline', type=Path, required=True)
    p.add_argument('--binary', type=Path, default=ROOT / 'fpr')
    p.add_argument('--runs', type=int, default=5)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    if a.runs < 1: p.error('runs must be positive')
    binaries = {'before': a.baseline.resolve(), 'after': a.binary.resolve()}
    env = {k: v for k, v in os.environ.items() if not k.startswith('SOL_')}
    env.update(SOL_JIT='0', SOL_GPU='0', SOL_TABLE='0', SOL_CACHE='0', SOL_TIMINGS='1')
    with tempfile.TemporaryDirectory(prefix='sol-text-bench-') as tmp:
        w = Path(tmp)
        cases = {}
        for size in (1000, 4000, 16000):
            data = w / f'text-{size}.txt'; data.write_text('aλ😀z' * (size // 4))
            source = 'scan : unsafe String -> Int -> Int -> Int.\nscan s i acc = case i > strlen s of True -> acc | False -> scan s (i + 1) (acc + charAt s i).\n'
            source += f'> s = readPath @{data}; print "{{scan s 1 0}}".\n'
            cases[f'scan_{size}'] = (source, f'{sum(map(ord, data.read_text()))}\n'.encode())
        for size in (100, 400, 1600):
            data = w / f'json-{size}.json'; data.write_text('[' + ','.join(['42'] * size) + ']')
            source = f'J = use "{ROOT}/sol/lib/json.sol".\n> s = readPath @{data}; r = J.parse s; case r of Ok (J.JArr xs) -> print "{{List.len xs}}" | _ -> print "failed".\n'
            cases[f'json_{size}'] = (source, f'{size}\n'.encode())
        for name, (source, _) in cases.items(): (w / (name + '.sol')).write_text(source)
        jobs = [(v, n) for v in binaries for n in cases]
        samples = {j: [] for j in jobs}
        rng = random.Random(0)
        for turn in range(a.runs + 1):
            order = jobs.copy(); rng.shuffle(order)
            for version, name in order:
                start = time.perf_counter_ns()
                r = subprocess.run([str(binaries[version]), 'sol', str(w / (name + '.sol'))], env=env, capture_output=True, timeout=120)
                wall = (time.perf_counter_ns() - start) / 1e6
                assert r.returncode == 0 and r.stdout == cases[name][1], (name, r)
                execute = float(re.search(rb'\[sol timing\] execute: ([\d.]+) ms', r.stderr).group(1))
                if turn: samples[version, name].append({'wall_ms': wall, 'execute_ms': execute})
        rows = [dict(version=v, case=n, samples=s, median_execute_ms=statistics.median(x['execute_ms'] for x in s), median_wall_ms=statistics.median(x['wall_ms'] for x in s)) for (v, n), s in samples.items()]
        report = dict(method=f'1 warmup + {a.runs} shuffled samples; fresh processes, warm filesystem; cache/JIT/GPU/table disabled; instrumented execution includes file read and print; -O0 development binaries',
                      platform=platform.platform(), binary_sha256={v:hashlib.sha256(b.read_bytes()).hexdigest() for v,b in binaries.items()}, rows=rows)
        a.output.parent.mkdir(parents=True, exist_ok=True)
        a.output.write_text(json.dumps(report, indent=2)+'\n')
        for row in rows: print(f"{row['version']:6} {row['case']:12} execute={row['median_execute_ms']:9.2f} wall={row['median_wall_ms']:9.2f} ms")


if __name__ == '__main__': main()
