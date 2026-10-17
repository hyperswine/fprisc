#!/usr/bin/env python3
"""Contracted pagination arithmetic and its real inventory projection.

Uses the existing ./fpr, without rebuilding it. The Python oracle uses divmod
and arbitrary precision; native arithmetic is exercised at tagged-Int limits.
Only the constant pagination core has declared bounds: this makes no claim
about the work of inventory's filtering, ranking or sorting.
"""
from pathlib import Path
import os
import re
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MAX = (1 << (struct.calcsize('P') * 8 - 2)) - 1
MIN = -MAX - 1


def literal(n):
    return str(n) if n >= 0 else f'(0 - {MAX} - 1)' if n == MIN else f'(0 - {-n})'


def sequence(ns):
    return '[' + ','.join(literal(n) for n in ns) + ']'


def reference(size, count, requested):
    whole, tail = divmod(count, size)
    pages = max(1, whole + bool(tail))
    index = max(0, min(requested, pages - 1))
    return index, pages, index * size


def run(args, env, *, ok=True):
    p = subprocess.run(list(map(str, args)), cwd=ROOT, env=env,
                       capture_output=True, text=True, timeout=240)
    assert (p.returncode == 0) == ok, f'{args}: {p.returncode}\n{p.stdout}{p.stderr}'
    return p


with tempfile.TemporaryDirectory(prefix='fpr-pagination-') as name:
    tmp = Path(name)
    env = {**os.environ, 'XDG_CACHE_HOME': os.environ.get('XDG_CACHE_HOME', str(tmp / 'cache')),
           'FPR_HOME': str(ROOT)}

    def build(name, body, *, ok=True, cost=True):
        src, binary = tmp / f'{name}.fpr', tmp / name
        src.write_text('profile base.\nP = use "std/pagination".\n' + body)
        p = run([ROOT / 'fpr', 'build', src, *(['--cost'] if cost else []), '-o', binary], env, ok=ok)
        return binary, p.stdout + p.stderr

    groups = [
        (list(range(1, 10)), list(range(33)), [-3, 0, 1, 2, 9, 33]),
        ([1, 2, 3, 20, MAX // 2, MAX - 1, MAX],
         [0, 1, 2, 19, 20, 21, MAX // 2, MAX - 1, MAX],
         [MIN, -1, 0, 1, 2, MAX // 2, MAX - 1, MAX]),
    ]
    calls = '\n'.join(f'  _ = group {sequence(ss)} {sequence(ns)} {sequence(rs)};'
                      for ss, ns, rs in groups)
    binary, report = build('boundaries', '''L = use "std/list".
emit size count request =
  p = P.plan size count request;
  print "{size},{count},{request}:{p.index},{p.pages},{p.first}".
group sizes counts requests = L.fold (fn acc size ->
  L.fold (fn acc count -> L.fold (fn acc request -> emit size count request) Unit requests) Unit counts) Unit sizes.
main =
''' + calls + '\n  Unit.\n')
    assert re.search(r'pages@\w+: declared work <= 8 .* PROVEN', report), report
    assert re.search(r'plan@\w+: declared work <= 25 .* PROVEN', report), report
    assert re.search(r'plan@\w+: declared alloc <= 32 .* PROVEN', report), report
    assert 'UNPROVED' not in report and ' OVER ' not in report, report
    want = [f'{size},{count},{request}:' + ','.join(map(str, reference(size, count, request)))
            for sizes, counts, requests in groups
            for size in sizes for count in counts for request in requests]
    for harts in ['1', '4']:
        got = run([binary], {**env, 'FPR_HARTS': harts}).stdout.splitlines()
        assert got == want, next(((a, b) for a, b in zip(got, want) if a != b), (len(got), len(want)))
    print(f'Pagination: {len(want)} independent-reference cases on 1/4 harts, including tagged Int extrema; constant budgets prove', flush=True)

    golden = ROOT / 'tests/std/pagination.fpr'
    golden_exe = tmp / 'golden'
    run([ROOT / 'fpr', 'build', golden, '-o', golden_exe], env)
    assert run([golden_exe], env).stdout == golden.with_suffix('.expected').read_text()

    binary, _ = build('refuse', '''Program = use "std/program".
call size count = p = P.plan size count 0; p.first.
main = case Program.args Unit of
    ["size-zero"] -> print (call 0 1)
  | ["size-negative"] -> print (call (0 - 1) 1)
  | ["count-negative"] -> print (call 1 (0 - 1))
  | ["pages-zero"] -> print (P.pages 0 1)
  | ["pages-negative"] -> print (P.pages 1 (0 - 1))
  | _ -> Unit.
''')
    for arg, function, predicate in [('size-zero', 'plan', 'size > 0'),
                                     ('size-negative', 'plan', 'size > 0'),
                                     ('count-negative', 'plan', 'count >= 0'),
                                     ('pages-zero', 'pages', 'size > 0'),
                                     ('pages-negative', 'pages', 'count >= 0')]:
        p = run([binary, arg], env, ok=False)
        out = p.stdout + p.stderr
        assert p.returncode == 1 and function in out and predicate in out, out
    _, refused = build('too-small', '''small : Unit -> Int | work small <= 1 | alloc small <= 31.
small _ = p = P.plan 20 100 0; p.first.
main = print (small Unit).
''', ok=False)
    assert 'small: declared work <= 1' in refused and 'OVER' in refused, refused
    assert 'small: declared alloc <= 31' in refused and 'derived 32' in refused, refused
    print('Pagination: invalid internal size/count fail with named contracts; insufficient work/allocation bounds fail compilation', flush=True)

    # Import the production projection rather than mirroring its page logic.
    app = ROOT / 'examples/inventory.fpr'
    binary, _ = build('inventory-project', f'''I = use "{app}".
L = use "std/list".
item n = {{id = n, name = "item {{n}}", loc = "room", sub = "", desc = "", tags = Nil,
          created = n, at = n, by = "sam", moves = Nil}}.
emit count request =
  session = {{I.noSess | sid = 7, user = "sam", page = request}};
  model = {{I.initModel | sess = [session], items = L.map item (L.range 1 count)}};
  v = I.project 20 200 7 model;
  ids = L.map (fn it -> it.id) v.items;
  print "{{count}},{{request}}:{{v.page}},{{v.pages}},{{v.first}}:{{ids}}".
main =
  _ = emit 0 100;
  _ = emit 21 100;
  _ = emit 41 1;
  _ = emit 41 (0 - 1);
  _ = emit 1 2;
  _ = print (I.imax 1 0, I.imax 1 (0 - 1), I.imax 1 20);
  Unit.
''', cost=False)
    expected = []
    for count, request in [(0, 100), (21, 100), (41, 1), (41, -1), (1, 2)]:
        index, pages, first = reference(20, count, request)
        ids = list(range(count, 0, -1))[first:first + 20]
        expected.append(f'{count},{request}:{index},{pages},{first}:[{", ".join(map(str, ids))}]')
    expected.append('(1, 1, 20)')
    for harts in ['1', '4']:
        got = run([binary], {**env, 'FPR_HARTS': harts}).stdout.splitlines()
        assert got == expected, (got, expected)
    print('Inventory: actual projection keeps sorted page contents, empty/shrunk/late/negative requests, and historical config normalization on 1/4 harts', flush=True)
