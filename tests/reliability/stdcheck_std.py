#!/usr/bin/env python3
"""`fpr stdcheck` (the std proof pass: intervals, measures, WCET terms) over every
std/*.fpr. Modules in stdcheck-known-failures.txt are expected to fail (with the
recorded reason); any other failure, or a listed module that now passes, fails
this check. Runs in parallel; about 3 s."""
import os, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
known = {}
for line in (Path(__file__).parent / 'stdcheck-known-failures.txt').read_text().splitlines():
    if line and not line.startswith('#'):
        m, _, why = line.partition('\t'); known[m] = why
with tempfile.TemporaryDirectory(prefix='fpr-stdcheck-') as d:
    env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=d)
    def one(src):
        p = subprocess.run([str(ROOT / 'fpr'), 'stdcheck', str(src)], capture_output=True, text=True, timeout=300, env=env, cwd=ROOT)
        lines = (p.stdout + p.stderr).strip().splitlines()
        ok = bool(lines) and lines[-1].startswith('stdcheck: OK')
        first = next((l for l in lines if l.startswith('error') or '<-- signed' in l), lines[-1] if lines else '')
        return src.stem, ok, first
    mods = sorted((ROOT / 'std').glob('*.fpr')) + sorted((ROOT / 'tests/reliability/stdcheck').glob('*.fpr'))
    with ThreadPoolExecutor(os.cpu_count() or 4) as ex: res = list(ex.map(one, mods))
bad = 0
for m, ok, first in res:
    if not ok and m not in known: bad += 1; print(f'FAIL {m}: {first}')
    if ok and m in known: bad += 1; print(f'NOW PASSES {m}: remove it from stdcheck-known-failures.txt')
print(f'stdcheck: {sum(ok for _, ok, _ in res)}/{len(res)} modules (std + regressions) OK, {len(known)} known failures')
sys.exit(1 if bad else 0)
