#!/usr/bin/env python3
"""Actual diagnostic products and native/Sol source-location contracts."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
env = {**os.environ, 'FPR_HOME': str(ROOT), 'FPR_PATH': str(ROOT), 'SOL_CACHE': '0'}
for keg in ('/opt/homebrew/opt/libarchive/lib/pkgconfig', '/usr/local/opt/libarchive/lib/pkgconfig'):
    if Path(keg).is_dir():
        env['PKG_CONFIG_PATH'] = keg + ':' + env.get('PKG_CONFIG_PATH', '')
        break
subprocess.run(['make', 'fpr'], cwd=ROOT, env=env, check=True, capture_output=True, timeout=300)
sys.path.insert(0, str(ROOT / 'tests'))
from haskell_units import run_units
run_units(['Diagnostics'], env, timeout=180)

with tempfile.TemporaryDirectory(prefix='fpr-diagnostics-') as directory:
    out = Path(directory)
    body = 'unsafe base.\nlate =\n  value = "a" % "b";\n  value.\n'
    source = out / 'late.fpr'
    source.write_text(body)
    for args in (['compile', '--check-only', '--prelude=', str(source), str(out / 'unused.s')],
                 ['sol', str(source)]):
        ran = subprocess.run([str(ROOT / 'fpr'), *args], cwd=ROOT, env=env,
                             capture_output=True, text=True, timeout=120)
        assert ran.returncode != 0, ran.stdout + ran.stderr
        assert f'{source}:3:11: in late: (%) is not defined for String' in ran.stdout + ran.stderr
        assert '@' not in ran.stdout + ran.stderr
    # A qualified imported binding must use the module's file and offsets.
    module = out / 'bad.fpr'
    module.write_text(body)
    root = out / 'root.fpr'
    root.write_text('unsafe base.\nBad = use "./bad".\nmain = print Bad.late.\n')
    ran = subprocess.run([str(ROOT / 'fpr'), 'compile', '--check-only', str(root), str(out / 'root.s')],
                         cwd=ROOT, env=env, capture_output=True, text=True, timeout=120)
    assert ran.returncode != 0
    assert f'{module}:3:11: in late@' in ran.stdout + ran.stderr, ran.stdout + ran.stderr
    assert '~ ' not in ran.stdout + ran.stderr
    unsafe = out / 'unsafe.fpr'
    unsafe.write_text('self x = self x.\n')
    for args in (['compile', '--check-only', '--prelude=', str(unsafe), str(out / 'unsafe.s')],
                 ['sol', str(unsafe)]):
        ran = subprocess.run([str(ROOT / 'fpr'), *args], cwd=ROOT, env=env,
                             capture_output=True, text=True, timeout=120)
        assert ran.returncode != 0
        assert f'{unsafe}:1: self is unsafe (recursive)' in ran.stdout + ran.stderr, ran.stdout + ran.stderr
    long_chain = out / 'long_ownership.fpr'
    lines = ['unsafe base.', 'Token 1 = Type Int.',
             'chain0 : a -> (a,a).', 'chain0 x = (x,x).']
    for index in range(1, 91):
        lines += [f'chain{index} : a -> (a,a).', f'chain{index} x = chain{index - 1} x.']
    lines += ['owned : Token -> (Token,Token).', 'owned t = chain90 t.']
    long_chain.write_text('\n'.join(lines) + '\n')
    for args in (['compile', '--check-only', '--prelude=', str(long_chain), str(out / 'long.s')],
                 ['sol', str(long_chain)]):
        ran = subprocess.run([str(ROOT / 'fpr'), *args], cwd=ROOT, env=env,
                             capture_output=True, text=True, timeout=120)
        assert ran.returncode != 0
        assert 'duplicates or discards its argument' in ran.stdout + ran.stderr, ran.stdout + ran.stderr
        assert f'{long_chain}:186:11: in owned:' in ran.stdout + ran.stderr, ran.stdout + ran.stderr
print('Structured diagnostics CLI: native/Sol delayed operator locations and qualified module source ownership passed')
