"""Run Haskell checks in tests/*.hs as the cabal test suites (fp-risc.cabal).

One `cabal test` builds the named suites against the compiled compiler
library and runs them, instead of `runghc` interpreting the whole compiler
once per driver. Without cabal, falls back to runghc. The caller holds
check_base's 'cabal' lock: cabal shares dist-newstyle.
"""
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def run_units(names, env, timeout=600):
    if shutil.which('cabal'):
        subprocess.run(['cabal', 'test', *[f'test:{n}' for n in names], '--test-show-details=direct'],
                       cwd=ROOT, env=env, check=True, timeout=timeout)
        return
    for name in names:
        subprocess.run(['runghc', '-w', '-icompiler', '-itests', f'tests/{name}.hs'],
                       cwd=ROOT, env=env, check=True, timeout=timeout)
