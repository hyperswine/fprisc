#!/usr/bin/env python3
"""Difference-bound discharge: values, the boundary trap and emission."""
import os
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAXI = 4611686018427387903  # 2^62 - 1
SOURCE = '''unsafe base.
count i n acc = if i >= n then acc else count (i + 1) n (acc + i).
over i n acc = if i > n then acc else over (i + 1) n acc.
fib n = if n < 2 then n else fib (n - 1) + fib (n - 2).
main = case Sys.args Unit of
    ["overflow"] -> print (over {lo} {hi} 0)
  | _ -> print "count {{count 0 1000000 0}} boundary {{count {bm1} {hi} 0}} fib {{fib 25}}".
'''.format(lo=MAXI - 1, hi=MAXI, bm1=MAXI - 1)
EXPECTED = 'count 499999500000 boundary {} fib 75025\n'.format(MAXI - 1)


def main():
    with tempfile.TemporaryDirectory(prefix='fpr-interval-') as directory:
        tmp = Path(directory)
        source = tmp / 'loops.fpr'
        source.write_text(SOURCE)
        env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=str(tmp / 'cache'))
        for no_interval in ('0', '1', '0'):
            # Alternate within the same cache to catch a missing option identity.
            mode = dict(env, FPR_NO_INTERVAL=no_interval)
            exe = tmp / 'loops'
            p = subprocess.run([str(ROOT / 'fpr'), 'build', source, '--harts', '4', '-o', exe],
                               cwd=ROOT, env=mode, capture_output=True, text=True, timeout=180)
            assert p.returncode == 0, p.stdout + p.stderr
            for harts in ('1', '4'):
                native = dict(mode, FPR_HARTS=harts)
                p = subprocess.run([exe], env=native, capture_output=True, text=True, timeout=60)
                assert p.returncode == 0 and p.stdout == EXPECTED, (no_interval, harts, p.returncode, p.stdout, p.stderr)
                # over's counter reaches maxInt with the exit false: i + 1
                # overflows and the kept check traps with the runtime's text
                p = subprocess.run([exe, 'overflow'], env=native, capture_output=True, text=True, timeout=60)
                assert p.returncode == 1 and 'Int overflow' in p.stdout + p.stderr, (
                    no_interval, harts, p.returncode, p.stdout, p.stderr)
            print(f'interval: no-interval={no_interval}: values, boundary exactness and the overflow trap 1/4 harts PASS', flush=True)
        # The discharged add drops its fit-check slow path on every selector.
        bodies = []
        for disabled in ('0', '1'):
            assembly = tmp / f'a64-{disabled}.s'
            p = subprocess.run([str(ROOT / 'fpr'), 'compile', '--target=a64', source, assembly],
                               cwd=ROOT, env=dict(env, FPR_NO_INTERVAL=disabled), capture_output=True, text=True, timeout=180)
            assert p.returncode == 0, p.stdout + p.stderr
            bodies.append(assembly.read_text())
        assert bodies[0] != bodies[1]
        print('interval emission: a64 discharge boundary PASS', flush=True)


if __name__ == '__main__':
    main()
