#!/usr/bin/env python3
"""Typed vectors: element mismatches, layouts, generic ownership and map output."""
from pathlib import Path
import os, subprocess, tempfile
ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
def run(args, **kw):
    return subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=120, **kw)
with tempfile.TemporaryDirectory(prefix='typed-vector-') as d:
    tmp = Path(d)
    bad = {
        'push': ('main = Vec.push "oops" (Vec.iota 2).', 'cannot unify'),
        'put': ('main = Vec.put 0 "oops" (Vec.iota 2).', 'cannot unify'),
        'read': ('bad : Vector Int -> String .\nbad v = (x, v2) = Vec.at 0 v; _ = Vec.free v2; x.\nmain = print (bad (Vec.iota 2)).', 'cannot unify'),
        'map-input': ('main = Vec.map strlen (Vec.iota 2).', 'cannot unify'),
        'layout': ('main = Vec.push 3 (Vec.newAs "d").', 'cannot unify'),
        'tuple-layout': ('main = Vec.push (1.0, 2) (Vec.newAs "id").', 'cannot unify'),
        'dynamic-layout': ('make s = Vec.newAs s.\nmain = make "d".', 'requires a literal layout'),
        'layout-alias': ('make = Vec.newAs.\nmain = make "d".', 'requires a literal layout'),
        'boxed-float': ('main = Vec.push 1.0 (Vec.newAs "b").', 'boxed columns'),
        'bare': ('bad : Vector -> Int .\nbad v = _ = Vec.free v; 1.\nmain = bad (Vec.iota 2).', 'requires one element type'),
        'numeric': ('main = Vec.scale 2 (Vec.push 1.0 (Vec.newAs "d")).', 'cannot unify'),
        'ambiguous-layout': ('main = _ = Vec.free (Vec.new Unit); print "no".', 'vector output layout is ambiguous'),
        'index-escape': ('main = print ((Vec.iota 2) ! 1).', 'cannot unify'),
        'linearity': ('main = v = Vec.iota 2; _ = Vec.free v; _ = Vec.free v; print "no".', 'linear'),
    }
    for name, (source, needle) in bad.items():
        src = tmp / (name + '.fpr')
        src.write_text(source + '\n')
        p = run(['./fprc', '--profile=base', '--check-only', src, tmp / 'bad.s'])
        assert p.returncode != 0 and needle in p.stdout+p.stderr, (name, p.returncode, p.stdout, p.stderr)
    print('Typed Vector: 14 element/layout/ownership refusal paths PASS')
    positive = tmp / 'positive.fpr'
    positive.write_text((ROOT / 'tests/base/typedvector.fpr').read_text())
    exe = tmp / 'positive'
    p = run(['./fpr', 'build', positive, '-o', exe])
    assert p.returncode == 0, p.stdout+p.stderr
    p = run([exe])
    assert p.returncode == 0 and p.stdout.strip() == 'typed: 2 7 2.5 ok 2.25 3 True', p.stdout+p.stderr
    # The same typed result holds with multiple runtime harts.
    p = run([exe], env={**os.environ, 'FPR_HARTS': '2'})
    assert p.returncode == 0 and p.stdout.strip() == 'typed: 2 7 2.5 ok 2.25 3 True', p.stdout+p.stderr
    for flags in (['--target=x64'], []):
        p = run(['./fprc', '--profile=base', *flags, positive, tmp / 'cross.s'])
        assert p.returncode == 0, p.stdout+p.stderr
    print('Typed Vector: generic identity, same-element generic map, Int/F64/tuple/String/Bool maps and inferred float constructors PASS')
    # HostedBytecode shares the type engine, with self-describing numeric values.
    src = tmp / 'hosted.sol'
    src.write_text('> Vec.push "oops" (Vec.range 1 2).\n')
    p = run(['./fpr', 'sol', src])
    assert p.returncode != 0 and 'cannot unify' in p.stdout+p.stderr, p.stdout+p.stderr
    src.write_text('> print (Vec.toList (Vec.map (fn x -> "ok") (Vec.range 1 2))).\n')
    p = run(['./fpr', 'sol', src])
    assert p.returncode == 0 and 'ok' in p.stdout, p.stdout+p.stderr
    print('Typed Vector: HostedBytecode rejects mixed elements and executes a type-changing map PASS')
