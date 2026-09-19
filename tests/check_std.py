#!/usr/bin/env python3
"""The standard library (std/*.fpr, docs/STD.md): every module, on this machine.

Each tests/std/<name>.fpr prints what it computed; tests/std/<name>.expected is
that output, reviewed by hand once.  --bless rewrites the expectations."""
import os, subprocess, sys, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
bless = '--bless' in sys.argv
subprocess.run(['make', 'fpr'], check=True, capture_output=True, timeout=600)
fpr = str(ROOT / 'fpr')
def check(name, args=(), cwd=None, label=''):
    src = ROOT / 'tests' / 'std' / f'{name}.fpr'
    p = subprocess.run([fpr, 'run', str(src), *args], capture_output=True, text=True, timeout=300, cwd=cwd)
    assert p.returncode == 0, f'{name}: exit {p.returncode}\n{p.stdout}\n{p.stderr}'
    want = src.with_suffix('.expected')
    if bless: want.write_text(p.stdout)
    assert p.stdout == want.read_text(), f'{name}: output differs from {want.name}\n{p.stdout}'
    print(f'{label}: PASS')
check('foundation', label='Option, Order, Result; values print as they are written')
check('list', label='List: map/filter/fold/find/zip/group, a stable merge sort of 300,000')
check('string', label='String: split/join/trim/replace/search/slices/toInt, 1.3 MB through join and split')
check('map', label='Map and Set: a persistent AVL tree, 100,000 keys in and half out, ascending iteration')
check('json', label='Json: parse with line and column, escapes and surrogate pairs, deterministic render, a 640 KB round trip')
with tempfile.TemporaryDirectory(prefix='fpr-std-') as t:
    tree = Path(t) / 'tree'
    (tree / 'sub' / 'deep').mkdir(parents=True)
    (tree / 'a.txt').write_text('hello\n')
    (tree / 'sub' / 'b.fpr').write_text('fn main\n')
    (tree / 'sub' / 'deep' / 'c d.fpr').write_text('x\n')
    check('posix', args=['one', 'two words'], cwd=t, label='Path, File, Dir, Proc, Program, Clock: walk, glob, create and remove, three held streams, 3.9 MB through a pipe')
    out = Path(t) / 'r.json'
    p = subprocess.run([fpr, 'run', str(ROOT / 'examples' / 'report.fpr'), 'tree', str(out)], capture_output=True, text=True, timeout=300, cwd=t)
    assert p.returncode == 0 and 'tree: 3 files' in p.stdout and '"files":3' in out.read_text(), p.stdout + p.stderr
    p = subprocess.run([fpr, 'run', str(ROOT / 'examples' / 'report.fpr'), '/no/such/dir'], capture_output=True, text=True, timeout=300)
    assert p.returncode == 1 and 'No such file or directory' in p.stderr, p.stderr
    print('examples/report.fpr, the automation acceptance program: a report and its JSON; failures said in words, exit 1: PASS')
