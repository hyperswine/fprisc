#!/usr/bin/env python3
"""Fail each initial actor reservation, with no production injection API."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='fpr-admission-') as folder:
    tmp = Path(folder)
    wrapper = tmp / 'cc-admission'
    wrapper.write_text('#!/bin/sh\nexec cc -DFPR_ADMISSION_TEST "$@"\n')
    wrapper.chmod(0o755)
    env = dict(os.environ, XDG_CACHE_HOME=str(tmp / 'cache'))
    def run(args, **kwargs):
        p = subprocess.run(list(map(str, args)), cwd=root, env=kwargs.pop('env', env),
                           text=True, capture_output=True, timeout=180, **kwargs)
        assert p.returncode == 0, p.stdout + p.stderr
        return p
    exe = tmp / 'admission'
    run(['./fpr', 'build', 'tests/base/admission.fpr', '--harts', '4', '--cc', wrapper,
         '--with', 'tests/base/admission_probe.c', '-o', exe])
    for harts in ('1', '4'):
        out = run([exe], env=dict(env, FPR_HARTS=harts)).stdout
        assert 'HOLDS' in out and 'FAILED' not in out and 'refusals=306' in out and 'cancel-returned=True' in out and 'cancelled=True' in out, out
        print(f'{harts} harts: {out.strip()}')
    # Production compilation must have no dependency on the fault hook.
    run(['cc', '-O2', '-DFPR_POSIX', '-I', 'runtime', '-c', 'runtime/actors.c', '-o', tmp / 'actors.o'])
    symbols = run(['nm', tmp / 'actors.o']).stdout
    assert 'fpr_admission_test_' not in symbols, symbols
    print('Initial actor admission: all six rollback phases; no publication, bounded reserve reuse, cancellation and late replies, later spawn; production fault hook absent: PASS')
