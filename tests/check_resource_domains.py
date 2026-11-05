#!/usr/bin/env python3
"""Signed resource inputs, exact max budgets and enforced domain boundaries.

These are source-equation checks, not physical-arena or timing certificates.
The optional baseline is the codegen-175 compiler before signed-domain fixes.
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
COUNT = '''count : (n : Int | measure n) -> Int -> Int{bound}.
count n acc | n <= 0 = acc.
count n acc = count (n - 1) (acc + 1).
main = print (count {value} 0).
'''
SIGNED_BAD = COUNT.format(bound=' | work count <= 5 * n + 5 ', value='(-2)')
MAX_BAD = '''count : (xs : List Int | measure xs) -> Int | work count <= max (6 * len xs) 6.
count xs = case xs of Nil -> 0 | x :: r -> x + count r.
main = print (count [1,2]).
'''
NEGATIVE_TERM = '''identity : (n : Int) -> Int | work identity <= 1 - n.
identity n = n.
main = print (identity 3).
'''
UNKNOWN_SPAN = '''Chain = Type (End Int | Link Chain).
seed n = n + 1.
walk : (i : Int | measure (lim - i)) -> Int -> Chain.
walk i lim | i >= lim = End i.
walk i lim = Link (walk (i + 1) lim).
make : Unit -> Chain{bound}.
make u = walk (seed 0) (seed 5).
resourceChainBytes : Chain -> Int.
main = print (resourceChainBytes (make Unit)).
'''
DOMAIN = '''plus : Int -> (n : Int | {predicate}) -> Int | work plus <= n + 2.
plus a n = a + n.
apply f n = f n.
main = {call}.
'''


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--baseline', type=Path)
    ap.add_argument('--record', type=Path)
    args = ap.parse_args()
    rows = []
    with tempfile.TemporaryDirectory(prefix='fpr-resource-domains-') as directory:
        tmp = Path(directory)
        env = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
        env.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=str(tmp/'cache'),
                   FPR_NO_CALL_REGIONS='1', FPR_NO_LOOP_REGIONS='1')

        def build(name, source, compiler=None):
            src, exe = tmp/(name+'.fpr'), tmp/name
            src.write_text(source)
            p = subprocess.run([compiler or ROOT/'fpr', 'build', '--cost', src,
                                '--harts', '4', '--with', ROOT/'tests/base/resource_cost_probe.c', '-o', exe], cwd=ROOT, env=env,
                               text=True, capture_output=True, timeout=180)
            return p, exe

        for name, source in [('signed-budget', SIGNED_BAD), ('max-budget', MAX_BAD),
                             ('negative-declared-term', NEGATIVE_TERM),
                             ('unknown-span', UNKNOWN_SPAN.format(bound=' | alloc make <= 16 '))]:
            p, _ = build(name, source)
            assert p.returncode != 0 and 'COST: ERRORS' in p.stdout, (name,p.stdout[-4000:],p.stderr)
            rows.append(dict(case=name,result='refused',
                             diagnostics=[line.strip() for line in p.stdout.splitlines() if ': declared ' in line]))
            if args.baseline:
                old, old_exe = build(name+'-old', source, args.baseline)
                assert old.returncode == 0, (name,old.stdout[-4000:],old.stderr)
                rows.append(dict(case=name,result='incorrectly-accepted-by-baseline',
                                 diagnostics=[line.strip() for line in old.stdout.splitlines() if ': declared ' in line]))
                if name == 'unknown-span':
                    r = subprocess.run([old_exe],env=env,capture_output=True,text=True,timeout=30)
                    assert r.returncode == 0 and r.stdout == '96\n', r
                    rows.append(dict(case=name,mode='baseline-bounded-execution',
                                     declared_bytes=16,observed_retained_requested_bytes=int(r.stdout)))
        print('Signed, max, negative-term and unknown-span budget regressions PASS',flush=True)

        sources = [(f'count-{label}', COUNT.format(bound='', value=value), answer)
                   for label,value,answer in [('negative','(-2)','0\n'),
                     ('min','(0 - 4611686018427387903 - 1)','0\n'),
                     ('zero','0','0\n'),('positive','5','5\n')]]
        sources.append(('negative-span', '''walk : (i : Int | measure (lim - i)) -> Int -> Int.
walk i lim | i >= lim = 7.
walk i lim = walk (i + 1) lim.
main = print (walk 10 (-10)).
''', '7\n'))
        for name, source, answer in sources:
            p, exe = build(name, source)
            assert p.returncode == 0, (name,p.stdout[-4000:],p.stderr)
            # Main still contains opaque printing, but its known work cannot
            # be negative. Extract only the equation's trailing constant.
            line = re.search(r'^  main\s+work  <= (.*)$',p.stdout,re.M)[1]
            assert '(-' not in line and ' + ' in line, line
            known = int(line.rsplit(' + ',1)[1])
            assert known > 0, line
            for harts in (1,4):
                r = subprocess.run([exe],env=dict(env,FPR_HARTS=str(harts)),capture_output=True,
                                   text=True,timeout=30)
                assert r.returncode == 0 and r.stdout == answer, (name,harts,r)
                rows.append(dict(case=name,harts=harts,stdout=r.stdout,known_work=known))
            if args.baseline:
                old, old_exe = build(name+'-old', source, args.baseline)
                assert old.returncode == 0, (name,old.stdout[-4000:],old.stderr)
                r = subprocess.run([old_exe],env=env,capture_output=True,text=True,timeout=30)
                assert r.returncode == 0 and r.stdout == answer, (name,r)
                old_line = re.search(r'^  main\s+work  <= (.*)$',old.stdout,re.M)[1]
                rows.append(dict(case=name,mode='baseline',stdout=r.stdout,work=old_line))
        p, exe = build('unknown-span-observed', UNKNOWN_SPAN.format(bound=''))
        assert p.returncode == 0, (p.stdout[-4000:],p.stderr)
        allocation = re.search(r'^  make\s+work  <= .*\n\s+alloc <= (.*) bytes$',p.stdout,re.M)[1]
        assert 'ω(?)' in allocation, allocation
        for harts in (1,4):
            r = subprocess.run([exe],env=dict(env,FPR_HARTS=str(harts)),capture_output=True,text=True,timeout=30)
            assert r.returncode == 0 and r.stdout == '96\n', (harts,r)
            rows.append(dict(case='unknown-span-observed',harts=harts,stdout=r.stdout,allocation=allocation))
        print('Negative inputs, minimum Int, negative span and ordinary outputs on 1/4 harts PASS',flush=True)

        # Explicit clamps preserve the entire original input domain. Predicates
        # constrain a domain and must remain enforced at all calling forms.
        p, _ = build('signed-clamped', COUNT.format(bound=' | work count <= 5 * max 0 n + 5 ',value='(-2)'))
        assert p.returncode == 0 and 'PROVEN' in p.stdout, (p.stdout[-4000:],p.stderr)
        rows.append(dict(case='signed-clamped',result='accepted'))
        for name,call,ok in [
            ('direct-positive','print (plus 10 3)',True),
            ('direct-negative','print (plus 10 (-3))',False),
            ('partial-positive','f = plus 10; print (f 3)',True),
            ('partial-negative','f = plus 10; print (f (-3))',False),
            ('escaped-positive','print (apply (plus 10) 3)',True),
            ('escaped-negative','print (apply (plus 10) (-3))',False),
        ]:
            p, exe = build(name,DOMAIN.format(predicate='n >= 0',call=call))
            assert p.returncode == 0 and 'PROVEN' in p.stdout, (name,p.stdout[-4000:],p.stderr)
            for harts in (1,4):
                r = subprocess.run([exe],env=dict(env,FPR_HARTS=str(harts)),capture_output=True,
                                   text=True,timeout=30)
                if ok:
                    assert r.returncode == 0 and r.stdout == '13\n', (name,harts,r)
                else:
                    assert r.returncode != 0 and 'precondition violated' in r.stdout+r.stderr, (name,harts,r)
                    assert '7\n' not in r.stdout, (name,harts,r)
                rows.append(dict(case=name,harts=harts,result='success' if ok else 'precondition-failure'))
        # A predicate permitting negative inputs cannot grant a natural domain.
        p, _ = build('domain-not-natural',DOMAIN.format(predicate='n >= -5',call='print (plus 10 (-3))'))
        assert p.returncode != 0 and 'COST: ERRORS' in p.stdout, (p.stdout[-4000:],p.stderr)
        rows.append(dict(case='domain-not-natural',result='refused'))
        print('Explicit clamps and direct/partial/escaped precondition boundaries PASS',flush=True)
    if args.record:
        sha = lambda p: hashlib.sha256(Path(p).read_bytes()).hexdigest()
        args.record.write_text(json.dumps(dict(schema='resource-domains-v1',
            compiler_sha256=sha(ROOT/'fpr'),baseline_sha256=sha(args.baseline) if args.baseline else None,
            sources={p:sha(ROOT/p) for p in ['compiler/Cost.hs','compiler/Compile.hs',
                       'tests/ResourceCosts.hs','tests/check_resource_domains.py','tests/base/resource_cost_probe.c']},rows=rows,
            limitations=['Source work/requested-object equations only, not physical arena or timing admission.',
                         'Result-size declarations remain assumptions.']),indent=2)+'\n')


if __name__ == '__main__':
    main()
