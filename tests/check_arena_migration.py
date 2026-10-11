#!/usr/bin/env python3
"""Exercise scratch-pool restoration across real actor migration."""
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='fpr-arena-migration-') as directory:
    exe = Path(directory) / 'probe'
    subprocess.run([str(ROOT / 'fpr'), 'build', 'tests/base/arenamigrate.fpr',
                    '--harts', '4', '-o', str(exe)], cwd=ROOT, check=True,
                   capture_output=True, text=True, timeout=180)
    for harts in (1, 4, 4, 4):
        p = subprocess.run([exe], env={**os.environ, 'FPR_HARTS': str(harts),
                           'FPR_HEAP_MB': '64'}, capture_output=True, text=True, timeout=120)
        assert p.returncode == 0, p.stdout + p.stderr
        match = re.fullmatch(r'arenamigrate: nested arenas and loopWith survive; migrations=(\d+)\n', p.stdout)
        assert match and (harts == 1 or int(match[1]) > 0), p.stdout
    print('Nested Sys.arena / Sys.loopWith: caller state survives observed migration on one/four harts PASS')
