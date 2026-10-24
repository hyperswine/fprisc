#!/usr/bin/env python3
"""Frontend owners preserve parser identity, cache bytes, scope and diagnostics."""
import hashlib
import json
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
ghc = ['cabal', 'exec', '--', 'runghc'] if shutil.which('cabal') else ['runghc']
with tempfile.TemporaryDirectory(prefix='fpr-frontend-') as directory:
    binary = Path(directory) / 'surface.bin'
    p = subprocess.run([*ghc, '-w', '-icompiler', 'tests/Frontend.hs', str(binary)],
                       cwd=ROOT, env=env, capture_output=True, text=True, timeout=180)
    assert p.returncode == 0, (p.stdout, p.stderr)
    golden = json.loads((ROOT / 'tests/frontend/compat.json').read_text())
    assert hashlib.sha256(binary.read_bytes()).hexdigest() == golden['binary_sha256'], 'surface Binary cache bytes changed'
    assert 'module-hash=' + golden['module_hash'] in p.stdout, 'module identity changed'
    print(p.stdout, end='')
