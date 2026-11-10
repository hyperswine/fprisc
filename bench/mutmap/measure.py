#!/usr/bin/env python3
"""measure.py RUNS OUT.json BENCHDIR DATADIR -- the MutMap benchmark (docs/2026-11-10-MUTMAP.md).
1 warm-up round, then RUNS rounds in shuffled interleaved order; per job:
median wall (s, perf_counter around GNU time), min, max, median peak RSS (MB, %M)."""
import json, os, random, statistics, subprocess, sys, time
# BENCHDIR/bin holds <program>.<compiler> binaries built from bench/mutmap/*.fpr
H = sys.argv[3] if len(sys.argv) > 3 else '.'; D = sys.argv[4] if len(sys.argv) > 4 else 'data'
RUNS = int(sys.argv[1]) if len(sys.argv) > 1 else 7
jobs = {}
for exe in sorted(os.listdir(H + '/bin')):
    jobs[exe] = [H + '/bin/' + exe] + ([D + '/corpus.txt'] if exe.startswith('wordfreq') else [])
def run1(c):
    t0 = time.perf_counter()
    p = subprocess.run([os.environ.get('GNU_TIME', '/usr/bin/time'), '-f', '%M', '-o', '/tmp/mutmap_rss'] + c, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    dt = time.perf_counter() - t0
    assert p.returncode == 0, c
    return dt, int(open('/tmp/mutmap_rss').read().split()[-1])
res = {k: [] for k in jobs}
keys = list(jobs)
for k in keys: run1(jobs[k])
for r in range(RUNS):
    random.shuffle(keys)
    for k in keys: res[k].append(run1(jobs[k]))
    print(f'round {r+1}/{RUNS} done', flush=True)
out = {k: {'wall_med': statistics.median([x[0] for x in v]), 'wall_min': min(x[0] for x in v), 'wall_max': max(x[0] for x in v),
           'rss_mb_med': statistics.median([x[1] for x in v]) / 1024, 'raw': v} for k, v in res.items()}
json.dump(out, open(sys.argv[2] if len(sys.argv) > 2 else 'raw.json', 'w'), indent=1)
for k in jobs: print(f"{k:30s} {out[k]['wall_med']:.3f} s (min {out[k]['wall_min']:.3f} max {out[k]['wall_max']:.3f})  {out[k]['rss_mb_med']:.0f} MB")
