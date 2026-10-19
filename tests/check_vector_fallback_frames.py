#!/usr/bin/env python3
"""Vector-specialization fallback frames keep ra in the frame's top word.

The generic fallbacks of the Vec specializations (mapAs, captured map and
filter, captured fold, map-closure, map-then-fold) build a closure in a
small stack frame before tail-jumping to the C tier.  They used to save ra
at 0(sp) and spill arguments upward from 8(sp), so the last argument
landed in the frame's top word.  On RV64/AArch64 that is harmless; on x64
the top word IS the hardware return address (X64.hs rule 1), so the
fallback "returned" into the heap: e.g. `Vec.map (fn p -> "ok")` over a
vector of tuples segfaulted on x86-64.

Checks:
  * X64.hs raGuard unit cases (tests/X64Frames.hs);
  * across the vector fixtures, every rv64 frame that saves ra saves it at
    F-8, and the x64 lowering (which runs raGuard) accepts them;
  * tests/base/vecfallback.fpr, whose calls all leave through fallback
    frames, prints the reference line on this host.
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
    p = subprocess.run([str(a) for a in args], cwd=ROOT, env=ENV, capture_output=True, text=True, timeout=300)
    assert p.returncode == 0, f'{args}: exit {p.returncode}\n{p.stdout[-2000:]}{p.stderr[-4000:]}'
    return p.stdout

# X64.hs needs only base: plain runghc, no cabal package db
print(run(['runghc', '-w', '-icompiler', 'tests/X64Frames.hs']), end='')

with tempfile.TemporaryDirectory(prefix='fpr-fallback-frames-') as d:
    tmp = Path(d)
    fallbacks = 0
    for name in FIXTURES:
        src = ROOT / 'tests/base' / f'{name}.fpr'
        for target in ('rv64', 'x64'):
            run(['./fprc', '--profile=base', f'--target={target}', src, tmp / f'{name}.{target}.s'])
        lines = (tmp / f'{name}.rv64.s').read_text().splitlines()
        section = ''
        for prev, line in zip(lines, lines[1:]):
            if line.startswith('# '):
                section = line
            a = re.fullmatch(r'    addi sp, sp, -(\d+)', prev)
            s = re.fullmatch(r'    sd ra, (\d+)\(sp\)', line)
            if a and s:
                assert int(s.group(1)) == int(a.group(1)) - 8, (name, section, prev, line)
                fallbacks += section.startswith('# Vec.')
    assert fallbacks >= 15, ('too few Vec specialization frames seen; the static check is vacuous', fallbacks)
    exe = tmp / 'vecfallback'
    run(['./fpr', 'build', ROOT / 'tests/base/vecfallback.fpr', '-o', exe])
    got = run([exe]).strip()
    assert got == EXPECT, (got, EXPECT)
    print(f'Vector fallback frames: ra in the top word across {len(FIXTURES)} fixtures ({fallbacks} Vec frames), '
          f'x64 lowering accepts them, fallbacks run ({EXPECT}): PASS')
