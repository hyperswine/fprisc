#!/usr/bin/env python3
"""Compile and execute the real server splice generator on reproducible cases."""
import json, os, random, subprocess, tempfile
from pathlib import Path
root = Path(__file__).resolve().parents[1]
rng = random.Random(42)
cases = [([], []), (['a'], []), ([], ['a']), (['a'], ['a'])]
for _ in range(40):
    cases.append(tuple([rng.choice(['a', 'b', 'λ', '{x}', '"']) for _ in range(rng.randrange(9))] for _ in range(2)))
# page-shaped: a list of distinct cards between a header and a footer, edited
# the ways a live page is (insert on top + drop the last, delete + backfill,
# edit in place, reorder) -- where v3's several splices should stay small
def page(ids): return ['head'] + [f'card{i}' for i in ids] + ['foot']
shaped = [(page(range(20, 0, -1)), page(range(21, 1, -1))),
          (page(range(20, 0, -1)), page([20, 19, 17, 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0])),
          (page(range(10)), page([0, 1, 2, 99, 4, 5, 6, 7, 8, 9])),
          (page(range(10)), page([9, 8, 7, 6, 5, 4, 3, 2, 1, 0])),
          (page(range(40)), page(range(40, 80)))]
for _ in range(60):
    a = [rng.choice('abcdefgh') for _ in range(rng.randrange(14))]
    b = list(a)
    for _ in range(rng.randrange(4)):
        op = rng.randrange(3)
        if op == 0: b.insert(rng.randrange(len(b) + 1), rng.choice('xyz'))
        elif op == 1 and b: del b[rng.randrange(len(b))]
        elif b: b[rng.randrange(len(b))] = rng.choice('xyz')
    shaped.append((a, b))
def literal(xs):
    return '[' + ', '.join(json.dumps(x, ensure_ascii=False).replace('{', '\\{') for x in xs) + ']'
with tempfile.TemporaryDirectory(prefix='live-splice-') as temp:
    p = Path(temp)
    source = p / 'splice.fpr'
    source.write_text('unsafe base.\nL = use "std/live".\nmain =\n' + ''.join(
        f'  _ = print (L.splice {literal(a)} {literal(b)});\n' for a,b in cases) + ''.join(
        f'  _ = print (L.multi {literal(a)} {literal(b)});\n' for a,b in cases + shaped) + '  0.\n')
    env = {**os.environ, 'FPR_HOME':str(root), 'XDG_CACHE_HOME':str(p/'cache')}
    subprocess.run([str(root/'fpr'), 'build', str(source), '-o', str(p/'splice')], cwd=root, env=env, check=True, capture_output=True)
    result = subprocess.run([str(p/'splice')], check=True, capture_output=True, text=True)
    lines = result.stdout.splitlines()
    assert len(lines) == len(cases) * 2 + len(shaped), len(lines)
    for (a,b), line in zip(cases,lines[:len(cases)],strict=True):
        start,n,insert = json.loads(line)
        assert a[:start]+insert+a[start+n:] == b
    moved = []
    for (a,b), line in zip(cases + shaped,lines[len(cases):],strict=True):
        cur = list(a)
        for start,n,insert in json.loads(line):
            assert 0 <= start and 0 <= n and start + n <= len(cur), (a, b, line)
            cur = cur[:start]+insert+cur[start+n:]
        assert cur == b, (a, b, line)
        moved.append(sum(len(ins) for _,_,ins in json.loads(line)))
    # a card on top that pushes the last one off: ONE card inserted, not twenty
    assert moved[len(cases)] == 1, moved[len(cases)]
    # a card deleted and the next one backfilled: one inserted
    assert moved[len(cases) + 1] == 1, moved[len(cases) + 1]
print(f'Server splice reconstruction: {len(cases)} single-splice (v2) and {len(cases) + len(shaped)} multi-splice (v3) cases PASS')
