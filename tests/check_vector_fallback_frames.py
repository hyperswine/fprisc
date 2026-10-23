#!/usr/bin/env python3
"""Generic vector fallback calls in typed RV64/x64 code.

These fixtures include captured and record callbacks that use the generic
runtime tier. Both backends must emit complete typed functions and the hosted
fallback fixture must print its independent reference result. Native return-PC
and frame invariants have separate large-frame C oracles.
"""
import os, re, subprocess, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
ENV = {**os.environ, 'FPR_HOME': str(ROOT), 'LC_ALL': 'C.UTF-8'}
for k in ('FPR_PATH', 'FPR_FOREIGN', 'FPRISC_ROOT'):
    ENV.pop(k, None)
FIXTURES = ['vecfallback', 'veccaps', 'veccaps_fold', 'vecfuse_capture', 'vecshape', 'veckinds', 'typedvector']
EXPECT = 'fallback frames: ok 5 cap 27 43'

def run(args):
    mode=dict(ENV)
    p = subprocess.run([str(a) for a in args], cwd=ROOT, env=mode, capture_output=True, text=True, timeout=300)
    assert p.returncode == 0, f'{args}: exit {p.returncode}\n{p.stdout[-2000:]}{p.stderr[-4000:]}'
    return p.stdout

with tempfile.TemporaryDirectory(prefix='fpr-fallback-frames-') as d:
    tmp = Path(d)
    for name in FIXTURES:
        src = ROOT / 'tests/base' / f'{name}.fpr'
        for target in ('rv64', 'x64'):
            run(['./fprc', '--profile=base', f'--target={target}', src, tmp / f'{name}.{target}.s'])
        x64 = (tmp / f'{name}.x64.s').read_text()
        assert x64.startswith('# typed IR: no translation') and '# wcet:' not in x64
        rv64=(tmp/f'{name}.rv64.s').read_text()
        assert rv64.startswith('# typed IR: no translation') and '# wcet:' not in rv64
    exe = tmp / 'vecfallback'
    run(['./fpr', 'build', ROOT / 'tests/base/vecfallback.fpr', '-o', exe])
    got = run([exe]).strip()
    assert got == EXPECT, (got, EXPECT)
    print(f'Vector fallback calls: complete RV64/x64 typed code across {len(FIXTURES)} fixtures, '
          f'typed x64 emits without translation, fallbacks run ({EXPECT}): PASS')
