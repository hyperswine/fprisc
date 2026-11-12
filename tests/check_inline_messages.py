#!/usr/bin/env python3
"""Small flat messages carried in their ring slot (runtime/actors.c send_inline)
keep order, strings, selective receive, unread messages at death and the
bounded-inbox charges of the ordinary path, at 1, 2 and 4 harts."""
from pathlib import Path
import os, subprocess, sys, tempfile

ROOT = Path(__file__).resolve().parents[1]
EXPECTED = {
    'inlinemsg': 'inlinemsg: 3000 kept in order with 0 out of place, string bytes 8000 of 8000; result 7 taken past three, then 654321; 200 deaths with 49 unread each\n',
    'inlinebounded': 'inlinebounded: limit 5 took 5 refused 3, then took 5 refused 3, 0+0 out of order; bytes admit 8 small and 8 wide (92/92 refused); result 9 past three with 0 out of order, fifth mailbox full\n',
}

def main():
    compiler = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'fpr'
    env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT))
    env.pop('FPR_FOREIGN', None)
    with tempfile.TemporaryDirectory(prefix='fpr-inline-') as directory:
        for name, expected in EXPECTED.items():
            executable = Path(directory) / name
            p = subprocess.run([compiler, 'build', f'tests/base/{name}.fpr', '-o', executable],
                               cwd=ROOT, env=env, capture_output=True, text=True, timeout=300)
            assert p.returncode == 0, p.stdout + p.stderr
            for harts in ('1', '2', '4'):
                for run in range(3):
                    p = subprocess.run([executable], env=dict(env, FPR_HARTS=harts),
                                       capture_output=True, text=True, timeout=120)
                    assert p.returncode == 0 and p.stdout == expected, (name, harts, run, p.stdout, p.stderr)
            print(f'inline messages: {name} at 1, 2 and 4 harts PASS', flush=True)

if __name__ == '__main__': main()
