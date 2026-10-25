#!/usr/bin/env python3
"""Typed source-to-Core lowering, scope/type/ownership lint and exact erasure."""
import os
from pathlib import Path
import re
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
             ('closure_layout', 'closure-layout False False True 7 8 9\n'),
             ('recursive_locals', 'recursive-locals 21 7 23 29 21 31 37 41 3 43 47 53\n')]
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
    # The new code/capture contracts must reach every ISA's native selector.
    # Execution above is host-native; these are portable emission checks.
    for target in ('x64', 'rv32', 'rv64'):
        output = Path(directory) / f'recursive-{target}.s'
        compiled = subprocess.run([str(ROOT / 'fpr'), 'compile', f'--target={target}',
                                   str(ROOT / 'tests/typed_core/recursive_locals.fpr'), str(output)],
                                  cwd=ROOT, env=native, capture_output=True, text=True, timeout=120)
        assert compiled.returncode == 0, compiled.stdout + compiled.stderr
        code = output.read_text()
        headers = re.findall(r'^# fn (\$typed_recursive_\S+).* typed-ir (\w+) ', code, re.M)
        assert headers and all(isa == target for _, isa in headers), headers
print('Typed Core native contracts: dictionaries, captures, recursive locals, record updates and layout-dependent closure identity on one/four harts passed')
print('Typed recursive locals: x64/RV32/RV64 native emission passed (execution is host-native only)')
