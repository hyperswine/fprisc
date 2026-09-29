#!/usr/bin/env python3
"""Compare indexed VM execution and fresh-process startup; emit raw samples."""
import argparse
import hashlib
import json
import os
import platform
from pathlib import Path
import random
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--binary', type=Path, default=ROOT / 'fpr')
    ap.add_argument('--baseline', type=Path, required=True)
    ap.add_argument('--runs', type=int, default=7)
    ap.add_argument('--output', type=Path, required=True)
    args = ap.parse_args()
    if args.runs < 1:
        ap.error('runs must be positive')
    bins = {'before': args.baseline.resolve(), 'after': args.binary.resolve()}
    env = {k: v for k, v in os.environ.items() if not k.startswith('SOL_')}
    env.update(SOL_JIT='0', SOL_GPU='0', SOL_TABLE='0')
    with tempfile.TemporaryDirectory(prefix='sol-vm-startup-') as tmp:
        w = Path(tmp)
        cases = {'hello': ('> print "hello".\n', b'hello\n'),
                 'imports': (f'p = use "{ROOT}/sol/lib/proc.sol".\nc = use "{ROOT}/sol/lib/csv.sol".\n> print "imported".\n', b'imported\n')}
        for width in (16, 64, 256):
            src = 'step x =\n' + '\n'.join(f'  x{i} = ' + ('x' if i == 1 else f'x{i-1}') + ' + 1;' for i in range(1, width + 1)) + f'\n  x{width}.\n'
            src += 'loop : unsafe Int -> Int -> Int.\nloop n x | n == 0 = x.\nloop n x = loop (n - 1) (step x).\n> print "{loop 500 0}".\n'
            cases[f'wide_{width}'] = src, f'{width * 500}\n'.encode()
        paths = {}
        for name, (src, _) in cases.items():
            paths[name] = w / (name + '.sol')
            paths[name].write_text(src)
        jobs = [(v, 'disabled', n) for v in bins for n in cases]
        jobs += [('after', m, n) for m in ('miss', 'hit') for n in ('hello', 'imports')]
        samples = {j: [] for j in jobs}
        def run(job, timed=False):
            v, mode, name = job
            cache = w / mode
            if mode == 'miss' and cache.exists():
                for p in cache.glob('*.cache'):
                    p.unlink()
            settings = env | {'SOL_CACHE': '0' if mode == 'disabled' else '1', 'SOL_CACHE_DIR': str(cache)}
            if timed:
                settings['SOL_TIMINGS'] = '1'
            start = time.perf_counter_ns()
            p = subprocess.run([str(bins[v]), 'sol', str(paths[name])], env=settings, capture_output=True, timeout=60)
            elapsed = (time.perf_counter_ns() - start) / 1e6
            assert p.returncode == 0 and p.stdout == cases[name][1] and (timed or not p.stderr), (job, p)
            return elapsed, p.stderr.decode()
        for job in jobs:
            run(job)
        rng = random.Random(0)
        for _ in range(args.runs):
            order = jobs.copy()
            rng.shuffle(order)
            for job in order:
                samples[job].append(run(job)[0])
        phases = {n: run(('after', 'hit', n), timed=True)[1] for n in ('hello', 'imports')}
        rows = [dict(version=v, mode=m, case=n, samples_ms=s, median_ms=statistics.median(s)) for (v, m, n), s in samples.items()]
        report = {'method': f'1 warmup + {args.runs} samples; shuffled cases; fresh processes, warm filesystem, interpreter only; cache miss removes artifact before launch; VM cases include compilation',
                  'platform': platform.platform(), 'machine': platform.machine(),
                  'timestamp_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                  'binary_sha256': {v: hashlib.sha256(p.read_bytes()).hexdigest() for v, p in bins.items()},
                  'settings': {k: v for k, v in env.items() if k.startswith('SOL_')},
                  'rows': rows, 'separate_instrumented_hit_samples': phases}
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + '\n')
        for row in rows:
            print(f"{row['version']:6} {row['mode']:9} {row['case']:10} {row['median_ms']:8.2f} ms")


if __name__ == '__main__':
    main()
