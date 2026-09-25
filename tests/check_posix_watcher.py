#!/usr/bin/env python3
"""Exercise watcher failure cleanup and a deterministic concurrent re-arm."""
from pathlib import Path
import os, shlex, subprocess, tempfile
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='fpr-watcher-test-') as d:
    binary = str(Path(d) / 'watcher')
    subprocess.run(shlex.split(os.environ.get('CC', 'cc')) +
                   ['-O2', '-DFPR_POSIX', '-I'+str(root/'runtime'),
                    '-I'+str(root/'machine/posix'), str(root/'tests/posix_watcher.c'),
                    '-lpthread', '-o', binary], check=True)
    subprocess.run([binary], check=True, timeout=15)
