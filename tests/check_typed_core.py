#!/usr/bin/env python3
"""Typed source-to-Core lowering, scope/type/ownership lint and exact erasure."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
env = dict(os.environ)
for keg in ('/opt/homebrew/opt/libarchive/lib/pkgconfig', '/usr/local/opt/libarchive/lib/pkgconfig'):
    if Path(keg).is_dir():
        env['PKG_CONFIG_PATH'] = keg + ':' + env.get('PKG_CONFIG_PATH', '')
        break
subprocess.run(['make', 'fpr'], cwd=ROOT, env=env, check=True,
               capture_output=True, timeout=300)
ghc = ['cabal', 'exec', '--', 'runghc'] if shutil.which('cabal') else ['runghc']
subprocess.run([*ghc, '-w', '-icompiler', 'tests/TypedCore.hs'], cwd=ROOT,
               env=env, check=True, timeout=180)

# An independent native answer catches source/typed-IR agreement on a wrong
# binding, and exercises the real native driver rather than only its helpers.
with tempfile.TemporaryDirectory(prefix='fpr-typed-core-') as directory:
    native = dict(env, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT))
    native.pop('FPR_FOREIGN', None)
    cases = [('contracts', 'typed-core 14 5 10 9 42 60 19\n'),
             ('closure_layout', 'closure-layout False False True 7 8 9\n')]
    for case, expected in cases:
      for harts in (1, 4):
        output = Path(directory) / f'{case}-{harts}'
        built = subprocess.run([str(ROOT / 'fpr'), 'build',
                                str(ROOT / f'tests/typed_core/{case}.fpr'),
                                '--harts', str(harts), '-o', str(output)],
                               cwd=ROOT, env=native, capture_output=True, text=True, timeout=120)
        assert built.returncode == 0, built.stdout + built.stderr
        ran = subprocess.run([str(output)], cwd=ROOT, env=native,
                             capture_output=True, text=True, timeout=30)
        assert ran.returncode == 0, ran.stdout + ran.stderr
        assert ran.stdout == expected, ran.stdout
print('Typed Core native contracts: dictionaries, captures, record updates and layout-dependent closure identity on one/four harts passed')
