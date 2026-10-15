#!/usr/bin/env python3
"""Deadline races and owned task joins, on one and four runtime harts."""
import os
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='fpr-deadlines-') as directory:
    tmp = Path(directory)
    for name, marker in (
        ('deadlines', 'deadlines: selective/FIFO/overflow/death/admission/stale/late-reply contracts HOLDS'),
        ('taskfailure', 'taskfailure: death/sibling cancellation/deadline/order/limit/inbox/cleanup contracts HOLDS'),
        ('mvudeadlines', 'mvudeadlines: live dimensions/input/ports/render/worker deadlines and watcher cleanup HOLDS'),
        ('mvuretained', 'mvuretained: HOLDS')):
        exe = tmp / name
        args = [str(ROOT/'fpr'), 'build', str(ROOT/'tests/base'/f'{name}.fpr'), '--harts', '4', '-o', str(exe)]
        if name == 'taskfailure':
            args += ['--with', str(ROOT/'tests/base/actorfail_probe.c')]
        p = subprocess.run(args, cwd=ROOT, text=True, capture_output=True, timeout=180)
        assert p.returncode == 0, p.stdout+p.stderr
        for harts in (1, 4, 4, 4):
            p = subprocess.run([exe], cwd=ROOT, env={**os.environ, 'FPR_HARTS':str(harts), 'FPR_HEAP_MB':'64'},
                               text=True, capture_output=True, timeout=30)
            assert p.returncode == 0 and marker in p.stdout and 'PANIC' not in p.stdout+p.stderr, (name, harts, p.stdout, p.stderr)
        print(f'{name}: one/four harts PASS', flush=True)
    src = tmp/'parfail.fpr'
    src.write_text('Probe.fail : Int -> Int .\nmain = par2 0 Probe.fail 0 (fn x -> x) 1.\n')
    exe = tmp/'parfail'
    p = subprocess.run([str(ROOT/'fpr'), 'build', src, '--with', str(ROOT/'tests/base/actorfail_probe.c'), '-o', exe],
                       cwd=ROOT, text=True, capture_output=True, timeout=180)
    assert p.returncode == 0, p.stdout+p.stderr
    p = subprocess.run([exe], env={**os.environ, 'FPR_HARTS':'4'}, text=True, capture_output=True, timeout=10)
    assert p.returncode == 1 and 'par2 worker: dead actor' in p.stdout+p.stderr, p.stdout+p.stderr
    print('par2: failed worker ends its join by name PASS', flush=True)
    p = subprocess.run([str(ROOT/'fpr'), 'sol', str(ROOT/'tests/std/soldeadline.sol')],
                       cwd=ROOT, text=True, capture_output=True, timeout=30)
    assert p.returncode == 0 and p.stdout.splitlines() == ['Err empty', 'Err deadline exceeded (outcome unknown)', 'Err dead actor'], p.stdout+p.stderr
    print('Sol: selective empty/live-deadline/dead contracts PASS', flush=True)
