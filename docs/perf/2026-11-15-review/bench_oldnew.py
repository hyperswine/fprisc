#!/usr/bin/env python3
"""Load-gated interleaved timing: median wall and peak RSS of N runs.
usage: bench.py --runs 5 --out X.json w1 w2 ...   (run from apps/)"""
import argparse, json, os, random, statistics, subprocess, tempfile, time, sys
from pathlib import Path
H = Path('.').resolve()
ARGS = {'csv': ['data/sales.csv'], 'wordfreq': ['data/corpus.txt']}
def base(n): return n.split('_')[0]
def gate(maxload):
    waited = 0
    while os.getloadavg()[0] > maxload and waited < 600:
        time.sleep(5); waited += 5
    return os.getloadavg()[0]
def timed(cmd):
    with tempfile.TemporaryFile() as out:
        t0 = time.perf_counter()
        p = subprocess.Popen(cmd, stdout=out, stderr=subprocess.DEVNULL)
        _, st, ru = os.wait4(p.pid, 0)
        dt = time.perf_counter() - t0
        out.seek(0); o = out.read()
    return os.waitstatus_to_exitcode(st), o, dt, ru.ru_maxrss / 1024, ru.ru_utime, ru.ru_stime
ap = argparse.ArgumentParser(); ap.add_argument('names', nargs='+'); ap.add_argument('--runs', type=int, default=5)
ap.add_argument('--out'); ap.add_argument('--maxload', type=float, default=1.5); a = ap.parse_args()
jobs = {}
for n in a.names:
    for d,suf in (('bin-fpr','.old'),('bin-new','.new')):
      for exe in (H/d).glob(n):
        label = exe.name + suf
        jobs[label] = ([str(exe)] + ARGS.get(base(n), []), (H/'expected'/f'{base(n)}.out').read_bytes())
res = {k: [] for k in jobs}; loads = []
for k,(c,e) in jobs.items():
    rc,o,*_ = timed(c)
    if rc or o != e: sys.exit(f'{k}: rc {rc} output {"ok" if o==e else "DIFFERS"}')
for r in range(a.runs):
    keys = list(jobs); random.shuffle(keys)
    for k in keys:
        loads.append(gate(a.maxload))
        rc,o,dt,rss,ut,stt = timed(jobs[k][0]); assert rc == 0 and o == jobs[k][1], k
        res[k].append((dt, rss, ut, stt))
    print(f'round {r+1}', file=sys.stderr, flush=True)
rows = {k: {'wall_med': statistics.median(x[0] for x in v), 'wall_min': min(x[0] for x in v),
            'rss_mb_med': statistics.median(x[1] for x in v), 'user_med': statistics.median(x[2] for x in v),
            'sys_med': statistics.median(x[3] for x in v), 'raw': v} for k,v in res.items()}
meta = {'date': time.strftime('%Y-%m-%d %H:%M %Z'), 'runs': a.runs, 'load1_at_start_of_each_run': [round(l,2) for l in loads],
        'nproc': os.cpu_count()}
if a.out: json.dump({'meta': meta, 'rows': rows}, open(a.out, 'w'), indent=1)
for k,r in rows.items(): print(f"{k:24s} {r['wall_med']:7.3f} s (min {r['wall_min']:.3f})  {r['rss_mb_med']:7.0f} MB  user {r['user_med']:.3f} sys {r['sys_med']:.3f}")
