#!/usr/bin/env python3
"""Transport policy plus native socket behavior; isolated loopback resources only."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='fpr-transport-') as directory:
    tmp = Path(directory)
    env = {**os.environ, 'FPR_HOME': str(ROOT), 'XDG_CACHE_HOME': str(tmp / 'cache')}

    def build(source, name):
        binary = tmp / name
        result = subprocess.run([str(ROOT / 'fpr'), 'build', str(ROOT / source), '-o', str(binary)],
                                cwd=ROOT, env=env, capture_output=True, text=True, timeout=180)
        assert result.returncode == 0, result.stdout + result.stderr
        return binary

    unit = build('tests/std/transport.fpr', 'unit')
    sockets = build('tests/sockettransport.fpr', 'sockets')
    readiness = build('tests/readiness.fpr', 'readiness')
    regular = tmp / 'regular-file'
    regular.write_text('not a socket\n')
    expected = (ROOT / 'tests/std/transport.expected').read_text()
    for harts in ('1', '4'):
        case_env = {**env, 'FPR_HARTS': harts}
        pure = subprocess.run([str(unit)], env=case_env, cwd=tmp,
                              capture_output=True, text=True, timeout=30)
        assert pure.returncode == 0 and pure.stdout == expected, pure.stdout + pure.stderr
        print(f'{harts} hart(s): {pure.stdout.strip()}', flush=True)
        native = subprocess.run([str(sockets), str(regular)], env=case_env, cwd=tmp,
                                capture_output=True, text=True, timeout=30)
        assert native.returncode == 0, native.stdout + native.stderr
        assert native.stdout == ('sockettransport: real TCP fragmentation/EOF, duplex, '
                                 'backpressure/deadline, cancellation, actor ownership, '
                                 'close and readiness PASS\n'), native.stdout + native.stderr
        print(f'{harts} hart(s): {native.stdout.strip()}', flush=True)
        watched = subprocess.run([str(readiness)], env=case_env, cwd=tmp,
                                 capture_output=True, text=True, timeout=30)
        assert watched.returncode == 0, watched.stdout + watched.stderr
        assert watched.stdout == ('readiness: directions, deadlines, duplicate waiters, '
                                  'cancellation barriers, quiet parking, transport, stop '
                                  'and fallback PASS\n'), watched.stdout + watched.stderr
        print(f'{harts} hart(s): {watched.stdout.strip()}', flush=True)
