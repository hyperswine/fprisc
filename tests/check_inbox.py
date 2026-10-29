#!/usr/bin/env python3
"""Opt-in inbox quota races, ownership and transactional admission."""
import os
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='fpr-inbox-') as directory:
    out = Path(directory)
    env = dict(os.environ, XDG_CACHE_HOME=os.environ.get('XDG_CACHE_HOME', str(out/'cache')))
    wrapper = out/'cc-inbox'
    wrapper.write_text('#!/bin/sh\nexec cc -DFPR_INBOX_TEST -DFPR_ADMISSION_TEST "$@"\n')
    wrapper.chmod(0o755)
    def run(args, env=env):
        p = subprocess.run(list(map(str,args)), cwd=ROOT, env=env, capture_output=True,text=True,timeout=180)
        assert p.returncode == 0, p.stdout+p.stderr
        return p.stdout
    for name in ('inbox', 'inboxshared', 'inboxownership', 'inboxkill', 'inboxadmission'):
        exe = out/name
        args = ['./fpr','build',f'tests/base/{name}.fpr','--harts','4','-o',exe]
        if name == 'inboxownership': args += ['--with','tests/base/inbox_probe.c']
        if name in ('inboxkill','inboxadmission'):
            args += ['--cc',wrapper,'--with','tests/base/inbox_probe.c','--with','tests/base/admission_probe.c']
        run(args)
        for harts in (1,4,4):
            text = run([exe],dict(env,FPR_HARTS=str(harts),FPR_HEAP_MB='64'))
            assert 'HOLDS' in text and 'PANIC' not in text, text
        print(name+': one/four harts HOLDS',flush=True)
    run(['cc','-O2','-DFPR_POSIX','-I','runtime','-c','runtime/actors.c','-o',out/'actors.o'])
    symbols = run(['nm',out/'actors.o'])
    assert 'fpr_inbox_test_' not in symbols, symbols
    print('Production actor runtime has no inbox fault hook dependency HOLDS',flush=True)
