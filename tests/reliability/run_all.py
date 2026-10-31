#!/usr/bin/env python3
"""Run every tests/reliability/*.py check (except this driver) and report
per-check wall time. Checks are independent; up to RELIABILITY_JOBS run at
once (default 2: several build programs and use all cores themselves).
RELIABILITY_FULL=1 (the nightly schedule) asks checks for their full size."""
import os, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
HERE = Path(__file__).resolve().parent
checks = sorted(p for p in HERE.glob('*.py') if p.name != 'run_all.py')
def one(p):
    t = time.time()
    r = subprocess.run([sys.executable, '-u', str(p)], capture_output=True, text=True)
    return p.name, r.returncode, time.time() - t, r.stdout + r.stderr
fails = 0
with ThreadPoolExecutor(int(os.environ.get('RELIABILITY_JOBS', '2'))) as ex:
    for name, rc, secs, out in ex.map(one, checks):
        print(f'::group::{name} {"PASS" if rc == 0 else "FAIL"} ({secs:.0f} s)', flush=True)
        print(out[-20000:])
        print('::endgroup::')
        if rc: fails += 1; print(f'FAIL {name} ({secs:.0f} s)')
print(f'reliability: {len(checks) - fails}/{len(checks)} checks passed')
sys.exit(1 if fails else 0)
