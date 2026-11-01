#!/usr/bin/env python3
"""A hosted program's diagnostics go to stderr (#39 item C).

stdout carries what the program printed and nothing else; a panic's last
words and [warn]/[ERR] log echo are on stderr; [log] echo stays on stdout.
FPR_DIAG_STDOUT=1 is the rollback switch and restores one stream."""
import os, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FPR = ROOT / 'fpr'
env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT))
env.pop('FPR_CC', None); env.pop('FPR_DIAG_STDOUT', None)
with tempfile.TemporaryDirectory() as t:
    src = Path(t) / 'p.fpr'
    src.write_text('unsafe base. main = _ = print "data"; error "boom".\n')
    exe = Path(t) / 'p'
    b = subprocess.run([str(FPR), 'build', str(src), '-o', str(exe)], env=env, capture_output=True, text=True, timeout=300)
    assert b.returncode == 0, b.stdout + b.stderr
    diag = '[ERR] boom\n\n*** FPRISC PANIC [actor 0]: boom ***\n'
    p = subprocess.run([str(exe)], env=env, capture_output=True, text=True, timeout=60)
    assert p.returncode == 1 and p.stdout == 'data\n' and p.stderr == diag, (p.returncode, p.stdout, p.stderr)
    r = subprocess.run([str(exe)], env=dict(env, FPR_DIAG_STDOUT='1'), capture_output=True, text=True, timeout=60)
    assert r.returncode == 1 and r.stdout == 'data\n' + diag and r.stderr == '', (r.stdout, r.stderr)
print('panic_stderr: panic on stderr, stdout clean, FPR_DIAG_STDOUT=1 rollback: PASS')
