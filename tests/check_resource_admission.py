#!/usr/bin/env python3
"""Refuse unsound source resource contracts before physical arena admission.

This validates requested-object equations only, not whole-image heap/stack
fit. Native probes independently observe retained tree and closure layouts.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
TREE = '''Tree = Type (Leaf | Node Tree Tree).
grow : (n : Int | measure n) -> Tree{bound}.
grow n | n <= 0 = Leaf.
grow n = Node (grow (n - 1)) (grow (n - 1)).
resourceTreeBytes : Tree -> Int.
main = print (resourceTreeBytes (grow 5)).
'''
PAP = '''sum3 a b c = a + b + c.
partial : Int -> (Int -> Int -> Int){bound}.
partial a = sum3 a.
resourcePapBytes : (Int -> Int -> Int) -> Int.
main = print (resourcePapBytes (partial 1)).
'''
GROWING = '''grow : (n : Int | measure n) -> String -> String{bound}.
grow n s | n <= 0 = s.
grow n s = grow (n - 1) (strcat s s).
main = print (strlen (grow 5 "a")).
'''


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--baseline', type=Path)
    ap.add_argument('--record', type=Path)
    args = ap.parse_args()
    rows = []
    with tempfile.TemporaryDirectory(prefix='fpr-resource-admission-') as directory:
        tmp = Path(directory)
        base = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
        base.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=str(tmp/'cache'),
                    FPR_NO_LOOP_REGIONS='1', FPR_NO_CALL_REGIONS='1')

        def build(name, text, *, compiler=None, probe=False):
            src, exe = tmp/(name+'.fpr'), tmp/name
            src.write_text(text)
            env = dict(base)
            if probe:
                env.update(FPR_COST_PROBE='1', FPR_COST_REPORT='1')
            p = subprocess.run([compiler or ROOT/'fpr', 'build', '--cost', src, '--harts', '4',
                                '--with', ROOT/'tests/base/resource_cost_probe.c', '-o', exe],
                               cwd=ROOT, env=env, text=True, capture_output=True, timeout=180)
            return p, exe, env

        cases = [('branching', TREE, ' | alloc grow <= 24 * n + 24 ', 'UNPROVED', '744\n', 31, 992),
                 ('partial', PAP, ' | alloc partial <= 24 ', 'OVER', '56\n', 1, 64),
                 ('growing', GROWING, ' | alloc grow <= (16 + 2 * len s) * (n + 1) ', 'UNPROVED', '32\n', None, None)]
        for name, template, bound, diagnostic, expected, requests, physical in cases:
            p, _, _ = build(name+'-bad', template.format(bound=bound))
            assert p.returncode != 0 and diagnostic in p.stdout+p.stderr, (name,p.stdout[-4000:],p.stderr[-2000:])
            rows.append(dict(case=name, mode='undersized-contract', result='refused', diagnostic=diagnostic))
            if args.baseline:
                p, _, _ = build(name+'-old', template.format(bound=bound), compiler=args.baseline)
                assert p.returncode == 0, (name,p.stdout[-3000:],p.stderr[-3000:])
                rows.append(dict(case=name, mode='baseline-undersized-contract', result='incorrectly-accepted'))
            p, exe, env = build(name+'-observed', template.format(bound=''), probe=True)
            assert p.returncode == 0, (name,p.stdout[-3000:],p.stderr[-3000:])
            for harts in (1,4):
                r = subprocess.run([exe], env=dict(env,FPR_HARTS=str(harts)), text=True,
                                   capture_output=True, timeout=30)
                assert r.returncode == 0 and r.stdout == expected, (name,harts,r)
                cost = json.loads(re.search(r'\[fpr cost\] (\{.*\})',r.stderr)[1])
                if requests is not None:
                    assert cost['alloc_requests'] == requests and cost['alloc_bytes'] == physical, (name,cost)
                rows.append(dict(case=name, mode='native-observation', harts=harts,
                                 stdout=r.stdout, allocations=cost['alloc_requests'], physical_bytes=cost['alloc_bytes']))
            print(f'{name}: undersized contract refused; independent native observations on 1/4 harts PASS',flush=True)

        # The correct PAP capacity is still accepted, and a one-call-per-path
        # recursive builder retains its useful linear allocation contract.
        p, _, _ = build('partial-correct', PAP.format(bound=' | alloc partial <= 56 '))
        assert p.returncode == 0, (p.stdout[-3000:],p.stderr[-3000:])
        linear = '''build : (n : Int | measure n) -> List Int -> List Int | alloc build <= 24 * max 0 n + 24.
build n xs | n <= 0 = xs.
build n xs = if n % 2 == 0 then build (n - 1) (n :: xs) else build (n - 1) ((n + 1) :: xs).
main = build 5 [].
'''
        p, _, _ = build('linear-correct', linear)
        assert p.returncode == 0, (p.stdout[-3000:],p.stderr[-3000:])
        rows.extend([dict(case=n,result='accepted') for n in ('correct-PAP-capacity','exclusive-linear-recursion')])
        print('Correct PAP capacity and exclusive linear recursion contracts PASS',flush=True)
    if args.record:
        sha = lambda p: hashlib.sha256(Path(p).read_bytes()).hexdigest()
        args.record.write_text(json.dumps(dict(schema='resource-equation-soundness-v1',
            compiler_sha256=sha(ROOT/'fpr'), baseline_sha256=sha(args.baseline) if args.baseline else None,
            sources={p:sha(ROOT/p) for p in ['compiler/Cost.hs','tests/ResourceCosts.hs',
                       'tests/check_resource_admission.py','tests/base/resource_cost_probe.c']},
            rows=rows, limitations=['Requested-object equations, not physical arena admission.',
                'Native observations use normal compact cells, with call/loop regions disabled to isolate objects.',
                'No claim about target WCET, stack fit, or complete runtime storage.']),indent=2)+'\n')


if __name__ == '__main__':
    main()
