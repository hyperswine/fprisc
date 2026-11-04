#!/usr/bin/env python3
"""Tuple fold workers: allocation and exact effects/traps against rollback."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HEAD = 'List = use "std/list".\n'


def run(args, env):
    return subprocess.run(list(map(str, args)), cwd=ROOT, env=env, text=True,
                          capture_output=True, timeout=180)


def main():
    cases = {
        'empty': ('''main = print (List.fold (fn p x -> case p of (s, c) -> (s + x, c + 1)) (7, 9) Nil).
''', '(7, 9)\n', None),
        'shared-seed': ('''main =
  seed = (7, 9);
  result = List.fold (fn p x -> case p of (s, c) -> (s + x, c + 1)) seed [1, 2, 3];
  print (seed, result).
''', '((7, 9), (13, 12))\n', None),
        'conditional-forward': ('''step p x = if x % 2 == 0 then p else case p of (s, c) -> (s + x, c + 1).
main = print (List.fold step (0, 0) (List.range 1 10)).
''', '(25, 5)\n', None),
        'field-effects': ('''step p x = case p of (s, c) -> (print "left {x}" >> (s + x), print "right {x}" >> (c + 1)).
main = print (List.fold step (print "seed" >> (0, 0)) [1, 2]).
''', 'seed\nleft 1\nright 1\nleft 2\nright 2\n(3, 2)\n', None),
        'division': ('''step p x = case p of (s, c) -> (print x >> (s + 10 / x), print "second" >> (c + 1)).
main = print (List.fold step (0, 0) [1, 0, 2]).
''', '1\nsecond\n0\n', 'division by zero'),
        'overflow-before-division': ('''step p x = case p of (s, c) -> (print x >> (s + x), 10 / c).
main = print (List.fold step (4611686018427387903, 0) [1, 2]).
''', '1\n', 'overflow'),
        'managed-fields': ('''step p x = case p of (s, xs) -> (s + x, x :: xs).
main =
  tail = [7, 8];
  result = List.fold step (0, tail) [1, 2, 3];
  print (tail, result).
''', '([7, 8], (6, [3, 2, 1, 7, 8]))\n', None),
        'callback-escape': ('''observe p = print p >> p.
step p x = case observe p of (s, c) -> (s + x, c + 1).
main = print (List.fold step (0, 0) [1, 2]).
''', '(0, 0)\n(1, 1)\n(3, 2)\n', None),
        'max-endpoint': ('''main = print (List.fold (fn p x -> case p of (s, c) -> (s, c + 1)) (0, 0)
  (List.range 4611686018427387903 4611686018427387903)).
''', '(0, 1)\n', None),
    }
    with tempfile.TemporaryDirectory(prefix='fpr-fold-scalars-') as directory:
        tmp = Path(directory)
        env = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
        env.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), FPR_HARTS='1',
                   XDG_CACHE_HOME=str(tmp / 'cache'))
        for name, (body, stdout, error) in cases.items():
            src = tmp / f'{name}.fpr'; src.write_text(HEAD + body)
            seen = []
            for disabled in (False, True):
                mode = dict(env, **({'FPR_NO_TUPLE_SCALARS': '1'} if disabled else {}))
                exe = tmp / f'{name}-{disabled}'
                p = run([ROOT / 'fpr', 'build', src, '--harts', '1', '-o', exe], mode)
                assert p.returncode == 0, (name, disabled, p.stdout, p.stderr)
                p = run([exe], mode)
                assert p.stdout == stdout, (name, disabled, p)
                assert (p.returncode == 0 and not p.stderr) if error is None else (
                    p.returncode != 0 and error in p.stderr.lower()), (name, disabled, p)
                seen.append((p.returncode, p.stdout, p.stderr))
            assert seen[0] == seen[1], (name, seen)
            print(f'Tuple folds: {name} PASS', flush=True)

        # Standalone source list: fusion is disabled so the fold worker must
        # eliminate accumulator pairs independently of producer fusion.
        src = tmp / 'allocation.fpr'
        src.write_text(HEAD + '''main = case List.fold (fn p x -> case p of (s, c) -> (s + x, c + 1))
  (0, 0) (List.range 1 1000) of (s, c) -> print "{s} {c}".
''')
        for disabled in (False, True):
            mode = dict(env, FPR_COST_PROBE='1', FPR_NO_LIST_FUSE='1',
                        **({'FPR_NO_TUPLE_SCALARS': '1'} if disabled else {}))
            exe = tmp / f'allocation-{disabled}'
            p = run([ROOT / 'fpr', 'build', src, '--harts', '1', '-o', exe], mode)
            assert p.returncode == 0, p.stderr
            p = run([exe], dict(mode, FPR_COST_REPORT='1'))
            assert (p.returncode, p.stdout) == (0, '500500 1000\n'), p
            match = re.search(r'\[fpr cost\] (\{.*\})', p.stderr)
            assert match, p.stderr
            ledger = json.loads(match.group(1))
            assert ledger['alloc_requests'] == (2005 if disabled else 1005), (disabled, ledger)
        print('Tuple folds: independent of List fusion, 2005 -> 1005 allocations PASS', flush=True)


if __name__ == '__main__':
    main()
