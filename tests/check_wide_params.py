#!/usr/bin/env python3
"""Typed parameters 7 and 8: RV64 emission, x64 TLS cells and hosted values.

The program's expected result is calculated independently in Python. The x64
emission must read both ABI cells, and every emitted function is typed native.
"""
import os, platform, re, subprocess, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
ENV = {**os.environ, 'FPR_HOME': str(ROOT), 'LC_ALL': 'C.UTF-8'}
for k in ('FPR_PATH', 'FPR_FOREIGN', 'FPRISC_ROOT'): ENV.pop(k, None)
FIXTURE = 'tests/base/wideparams.fpr'

def mix7(a, b, c, d, e, f, g):
    s, t = len(str(g)), len(str(g) * 2)
    return a + b + c + d + e + f + g * g + g * s + g * t + (g + g) * (g + s) + g * 3 + g

def mix8(a, b, c, d, e, f, g, h):
    s, t = len(str(h) + str(g)), len(str(h))
    return a + b + c + d + e + f + h * h + h * g + h * s + g * t + (h + g) * (h + s) + h * 5 + g * g + h + g

EXPECT = f'wide: {mix7(1, 2, 3, 4, 5, 6, 7)} {mix8(1, 2, 3, 4, 5, 6, 7, 8)} {mix7(-1, 0, 0, 0, 0, 0, 123456)}'

def run(args, env):
    p = subprocess.run([str(a) for a in args], cwd=ROOT, env=env, capture_output=True, text=True, timeout=300)
    assert p.returncode == 0, f'{args}: exit {p.returncode}\n{p.stdout}{p.stderr}'
    return p.stdout

with tempfile.TemporaryDirectory(prefix='fpr-wide-') as d:
    tmp = Path(d)
    env=ENV
    for target in ('rv64','x64'):
        out=tmp/(target+'.s')
        run(['./fpr',f'--target={target}',f'--prelude={ROOT}/core/prelude.fpr',FIXTURE,out],env)
        text=out.read_text()
        assert text.startswith('# typed IR: no translation') and '# wcet:' not in text
        if target=='x64':
            for cell in ('fpr_x64_a6','fpr_x64_a7'):
                assert re.search(rf'movq %fs:{cell}@tpoff, %\w+',text),cell
    exe=tmp/'wide'
    run(['./fpr','build',FIXTURE,'-o',exe],env)
    got=run([exe],env).strip();assert got==EXPECT,(got,EXPECT)
    print(f'Wide parameters: RV64/x64 typed emission, argument cells 7/8 and hosted results ({EXPECT}) PASS')
