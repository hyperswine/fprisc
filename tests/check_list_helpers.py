#!/usr/bin/env python3
"""Helper exposure must preserve sharing, argument effects and trap order."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HEAD = 'List = use "std/list".\n'


def run(args, env):
    return subprocess.run(list(map(str, args)), cwd=ROOT, env=env,
                          text=True, capture_output=True, timeout=180)


def main():
    cases = {
        'shared-producer': ('''main =
  xs = List.map (fn x -> print x >> x) [1, 2, 3];
  print (List.sum xs, List.length xs).
''', '1\n2\n3\n(6, 3)\n', None),
        'helper-effects': ('''mapped xs = List.map (fn x -> print x >> x) xs.
main = print (List.sum (mapped [1, 2, 3])).
''', '1\n2\n3\n6\n', None),
        'shared-helper': ('''mapped xs = List.map (fn x -> print x >> x) xs.
main =
  xs = mapped [1, 2, 3];
  print (List.sum xs, List.length xs).
''', '1\n2\n3\n(6, 3)\n', None),
        'helper-capture': ('''mapped k xs = List.map (fn x -> x + k) xs.
main = print (List.sum (mapped (print "capture" >> 2) (List.range 1 3))).
''', 'capture\n12\n', None),
        'helper-body-before-input': ('''mapped xs = print "body" >> List.map (fn x -> x + 1) xs.
main = print (List.sum (mapped (List.map (fn x -> print x >> x) [1, 2]))).
''', '1\n2\nbody\n5\n', None),
        'helper-argument-trap': ('''mapped k xs = List.map (fn x -> x + k) xs.
main = print (List.sum (mapped (100 / 0) (List.map (fn x -> print x >> x) [1, 2]))).
''', '', 'division by zero'),
        'helper-callback-trap': ('''mapped xs = List.map (fn x -> print x >> 100 / x) xs.
main = print (List.sum (mapped [1, 0, 2])).
''', '1\n0\n', 'division by zero'),
        'helper-before-overflow': ('''mapped xs = List.map (fn x -> print x >> x) xs.
main =
  xs = mapped [0, 1, 2];
  n = 4611686018427387903 + 1;
  print (List.sum xs + n).
''', '0\n1\n2\n', 'overflow'),
        'helper-conditional': ('''mapped xs = List.map (fn x -> print x >> x) xs.
main =
  xs = mapped [1, 2];
  print (if False then List.sum xs else 42).
''', '1\n2\n42\n', None),
        'helper-captured-list': ('''mapped xs = List.map (fn x -> print x >> x) xs.
main =
  xs = mapped [1, 2];
  f = fn x -> x + List.sum xs;
  print (f 10, f 20).
''', '1\n2\n(13, 23)\n', None),
        'helper-max-endpoint': ('''folded xs = List.fold (fn z x -> z) 0 xs.
main = print (folded (List.range 4611686018427387903 4611686018427387903)).
''', '0\n', None),
        'helper-min-endpoint': ('''folded xs = List.fold (fn z x -> print x >> z) 0 xs.
main = print (folded (List.range (0 - 4611686018427387903 - 1) (0 - 4611686018427387903 - 1))).
''', '', 'overflow'),
    }
    with tempfile.TemporaryDirectory(prefix='fpr-list-helpers-') as directory:
        tmp = Path(directory)
        env = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
        env.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), FPR_HARTS='1',
                   XDG_CACHE_HOME=str(tmp / 'cache'))
        for name, (body, stdout, error) in cases.items():
            src = tmp / f'{name}.fpr'
            src.write_text(HEAD + body)
            results = []
            for mode in ('default', 'NO_LIST_FUSE', 'NO_SPEC', 'NO_INLINE'):
                variant = dict(env, **({} if mode == 'default' else {f'FPR_{mode}': '1'}))
                exe = tmp / f'{name}-{mode}'
                p = run([ROOT / 'fpr', 'build', src, '--harts', '1', '-o', exe], variant)
                assert p.returncode == 0, (name, mode, p.stdout, p.stderr)
                p = run([exe], variant)
                assert p.stdout == stdout, (name, mode, p.stdout, p.stderr)
                assert (p.returncode == 0 and not p.stderr) if error is None else (
                    p.returncode != 0 and error in p.stderr.lower()), (name, mode, p)
                results.append((p.returncode, p.stdout, p.stderr))
            assert all(r == results[0] for r in results), (name, results)
            print(f'List helper effects/sharing: {name} PASS', flush=True)

        # Inlining may expose imported wrappers but must keep home code/captures.
        (tmp / 'helpers.fpr').write_text(HEAD + '''small k xs = List.filter (fn x -> x <= k) xs.
triple xs = List.map (fn x -> x * 3) xs.
''')
        src = tmp / 'imported.fpr'
        src.write_text(HEAD + '''H = use "helpers".
main = print (List.sum (H.triple (H.small 500 (List.range 1 1000)))).
''')
        for mode in ('default', 'NO_SPEC'):
            variant = dict(env, FPR_COST_PROBE='1', **({} if mode == 'default' else {'FPR_NO_SPEC': '1'}))
            exe = tmp / ('imported-' + mode)
            p = run([ROOT / 'fpr', 'build', src, '--harts', '1', '-o', exe], variant)
            assert p.returncode == 0, (mode, p.stdout, p.stderr)
            p = run([exe], dict(variant, FPR_COST_REPORT='1'))
            assert p.returncode == 0 and p.stdout == '375750\n', (mode, p)
            match = re.search(r'\[fpr cost\] (\{.*\})', p.stderr)
            assert match, p.stderr
            ledger = json.loads(match.group(1))
            # Without specialization the composed captured callback needs one
            # closure. Neither mode should materialize an intermediate list.
            assert ledger['alloc_requests'] == (0 if mode == 'default' else 1), (mode, ledger)
        print('List helpers: imported captures, 0 requests (1 closure without specialization) PASS', flush=True)


if __name__ == '__main__':
    main()
