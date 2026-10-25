#!/usr/bin/env python3
"""Shared compiler options and executable-cache behavior across mode changes."""
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
subprocess.run(['make', 'fpr'], cwd=ROOT, env=env, check=True, capture_output=True, timeout=300)
ghc = ['cabal', 'exec', '--', 'runghc'] if shutil.which('cabal') else ['runghc']
subprocess.run([*ghc, '-w', '-icompiler', 'tests/CompilerOptions.hs'], cwd=ROOT,
               env=env, check=True, timeout=60)

with tempfile.TemporaryDirectory(prefix='fpr-options-') as directory:
    temp = Path(directory)
    source = temp / 'receive_cache.fpr'
    # Reuse the proven receive-state fixture with a shorter second run. The
    # first 100-turn assertion already distinguishes the disabled region pass.
    source.write_text((ROOT / 'tests/base/receiveturns.fpr').read_text()
                      .replace('1000000', '1000').replace('one million', 'one thousand'))
    isolated = {k: v for k, v in env.items() if not k.startswith(('FPR_', 'FPRC_'))}
    isolated.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=str(temp / 'cache'),
                    FPR_HARTS='1', FPR_HEAP_MB='64')
    run_dir = temp / 'cache/fpr/run'

    def run(settings=None):
        return subprocess.run([str(ROOT / 'fpr'), 'run', str(source), '--harts', '4'],
                              cwd=ROOT, env={**isolated, **(settings or {})},
                              capture_output=True, text=True, timeout=180)

    first = run()
    assert first.returncode == 0 and 'one thousand ordinary recursive receives bounded' in first.stdout, first.stdout + first.stderr
    first_entries = {p.name: p.stat().st_mtime_ns for p in run_dir.iterdir()}
    assert len(first_entries) == 1, first_entries
    disabled = run({'FPR_NO_RECEIVE_TURNS': '1'})
    assert disabled.returncode != 0 and 'receive turns: caller heap grew' in disabled.stdout + disabled.stderr, disabled.stdout + disabled.stderr
    assert len(list(run_dir.iterdir())) == 2, list(run_dir.iterdir())
    # A default alias must reuse the original executable without rebuilding it.
    again = run({'FPR_NO_RECEIVE_TURNS': '0', 'FPR_TYPED_IR_BACKEND': 'mixed'})
    assert again.returncode == 0 and again.stdout == first.stdout, again.stdout + again.stderr
    assert len(list(run_dir.iterdir())) == 2
    assert all((run_dir / name).stat().st_mtime_ns == stamp for name, stamp in first_entries.items())
    retired = run({'FPR_TYPED_IR_BACKEND': 'legacy'})
    assert retired.returncode != 0 and 'legacy backend has been retired' in retired.stderr
    assert len(list(run_dir.iterdir())) == 2
    foreign = temp / 'foreign.fpr'
    foreign.write_text('unusedCacheProbe : Int -> Int.\n')
    with_foreign = run({'FPR_FOREIGN': str(foreign)})
    assert with_foreign.returncode == 0 and with_foreign.stdout == first.stdout, with_foreign.stdout + with_foreign.stderr
    assert len(list(run_dir.iterdir())) == 3
    # The same declaration path with a different contract must invalidate the
    # executable too; recording only the FPR_FOREIGN path misses this change.
    foreign.write_text('unusedCacheProbe : String -> String.\n')
    changed_foreign = run({'FPR_FOREIGN': str(foreign)})
    assert changed_foreign.returncode == 0 and changed_foreign.stdout == first.stdout, changed_foreign.stdout + changed_foreign.stderr
    assert len(list(run_dir.iterdir())) == 4
print('Compiler options native cache: default/off/default aliases preserve receive-region behavior and reuse; retired backend refused before cache access')
