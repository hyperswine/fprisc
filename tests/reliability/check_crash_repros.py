#!/usr/bin/env python3
"""Compiler crash regressions: every tests/reliability/crash/*.fpr is an
ill-formed program that once crashed `fpr check`. Each must now end with an
ordinary diagnostic (exit 1) and never a Haskell exception or CallStack."""
import os, subprocess, sys, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
BAD = ('CallStack', 'Prelude.', 'Exception', 'error, called at', 'Non-exhaustive', 'impossible')
fails = 0
with tempfile.TemporaryDirectory(prefix='fpr-crash-') as d:
    env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=d)
    for src in sorted((ROOT / 'tests/reliability/crash').glob('*.fpr')):
        p = subprocess.run([str(ROOT / 'fpr'), 'check', str(src)], capture_output=True, text=True, timeout=120, env=env)
        out = p.stdout + p.stderr
        ok = p.returncode == 1 and not any(b in out for b in BAD) and ('TYPE ERRORS' in out or 'unexpected' in out)
        print(f'{"PASS" if ok else "FAIL"} {src.name}')
        if not ok: fails += 1; print(out[-1500:])
sys.exit(1 if fails else 0)
