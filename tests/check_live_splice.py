#!/usr/bin/env python3
"""Compile and execute the real server splice generator on reproducible cases."""
import json, os, random, subprocess, tempfile
from pathlib import Path
root = Path(__file__).resolve().parents[1]
rng = random.Random(42)
cases = [([], []), (['a'], []), ([], ['a']), (['a'], ['a'])]
for _ in range(40):
    cases.append(tuple([rng.choice(['a', 'b', 'λ', '{x}', '"']) for _ in range(rng.randrange(9))] for _ in range(2)))
def literal(xs):
    return '[' + ', '.join(json.dumps(x, ensure_ascii=False).replace('{', '\\{') for x in xs) + ']'
with tempfile.TemporaryDirectory(prefix='live-splice-') as temp:
    p = Path(temp)
    source = p / 'splice.fpr'
    source.write_text('unsafe base.\nL = use "std/live".\nmain =\n' + ''.join(
        f'  _ = print (L.splice {literal(a)} {literal(b)});\n' for a,b in cases) + '  0.\n')
    env = {**os.environ, 'FPR_HOME':str(root), 'XDG_CACHE_HOME':str(p/'cache')}
    subprocess.run([str(root/'fpr'), 'build', str(source), '-o', str(p/'splice')], cwd=root, env=env, check=True, capture_output=True)
    result = subprocess.run([str(p/'splice')], check=True, capture_output=True, text=True)
    for (a,b), line in zip(cases,result.stdout.splitlines(),strict=True):
        start,n,insert = json.loads(line)
        assert a[:start]+insert+a[start+n:] == b
print('Server splice reconstruction: 44 deterministic cases PASS')
