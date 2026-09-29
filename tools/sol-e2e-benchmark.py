#!/usr/bin/env python3
"""End-to-end warm/miss/disabled startup and transactional-read comparison."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import shutil
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--baseline', type=Path, required=True)
    ap.add_argument('--binary', type=Path, default=ROOT / 'fpr')
    ap.add_argument('--runs', type=int, default=5)
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--rts-tick', type=float, help='Override both binaries timer interval in seconds to isolate compiler/cache changes')
    a = ap.parse_args()
    if a.rts_tick is not None and (not math.isfinite(a.rts_tick) or a.rts_tick <= 0): ap.error('rts-tick must be positive')
    if a.runs < 1: ap.error('runs must be positive')
    bins = {'before': a.baseline.resolve(), 'after': a.binary.resolve()}
    env = {k: v for k, v in os.environ.items() if not k.startswith('SOL_')}
    env.pop('GHCRTS', None)
    env.update(SOL_JIT='0', SOL_GPU='0', SOL_TABLE='0')
    with tempfile.TemporaryDirectory(prefix='sol-e2e-') as tmp:
        w = Path(tmp)
        cases = {'hello': ('> print "hello".\n', b'hello\n'),
                 'imports': (f'p = use "{ROOT}/sol/lib/proc.sol".\nc = use "{ROOT}/sol/lib/csv.sol".\nj = use "{ROOT}/sol/lib/json.sol".\n> print "imported".\n', b'imported\n')}
        for size in (65536, 262144, 1048576):
            data = w / f'input-{size}.txt'; data.write_bytes(b'a' * size)
            cases[f'read_{size}'] = (f'> s = readPath @{data}; print "{{strlen s}}".\n', f'{size}\n'.encode())
        for name, (src, _) in cases.items(): (w / (name + '.sol')).write_text(src)
        jobs = [(v, mode, name) for v in bins for mode in ('hit', 'miss', 'disabled') for name in cases]
        samples = {j: [] for j in jobs}
        def run(job, extra=None, rts=False):
            version, mode, name = job
            cache = w / ('cache-' + version + '-' + mode)
            if mode == 'miss' and cache.exists(): shutil.rmtree(cache)
            settings = env | {'SOL_CACHE_DIR': str(cache), 'SOL_CACHE': '0' if mode == 'disabled' else '1'} | (extra or {})
            rts_flags = ([f'-V{a.rts_tick}'] if a.rts_tick is not None else []) + (['-s'] if rts else [])
            cmd = [str(bins[version]), 'sol', str(w / (name + '.sol'))] + (['+RTS', *rts_flags, '-RTS'] if rts_flags else [])
            start = time.perf_counter_ns()
            p = subprocess.run(cmd, env=settings, capture_output=True, timeout=60)
            elapsed = (time.perf_counter_ns() - start)/1e6
            assert p.returncode == 0 and p.stdout == cases[name][1] and (extra or rts or not p.stderr), (job, p)
            return elapsed, p.stderr.decode()
        for job in jobs: run(job)
        rng = random.Random(0)
        for _ in range(a.runs):
            order = jobs.copy(); rng.shuffle(order)
            for job in order: samples[job].append(run(job)[0])
        rows = [dict(version=v, mode=m, case=n, samples_ms=s, median_ms=statistics.median(s)) for (v,m,n),s in samples.items()]
        phases = {v: {n: run((v,'hit',n), {'SOL_TIMINGS':'1'})[1] for n in cases} for v in bins}
        rts = {v: run((v,'hit','read_1048576'), rts=True)[1] for v in bins}
        report = dict(method=f'1 warmup + {a.runs} shuffled samples; fresh processes, warm filesystem; misses remove compiled and module artifacts; JIT/GPU/table disabled; wall measurements without timing instrumentation',
                      rts_tick_override=a.rts_tick, platform=platform.platform(), timestamp_utc=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),
                      binary_sha256={v:hashlib.sha256(b.read_bytes()).hexdigest() for v,b in bins.items()}, rows=rows, separate_instrumented_samples=phases, separate_rts_read_1m=rts)
        a.output.parent.mkdir(parents=True, exist_ok=True);a.output.write_text(json.dumps(report,indent=2)+'\n')
        for r in rows: print(f"{r['version']:6} {r['mode']:8} {r['case']:14} {r['median_ms']:9.2f} ms")


if __name__ == '__main__': main()
