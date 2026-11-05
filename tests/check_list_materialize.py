#!/usr/bin/env python3
"""Materializing range pipelines: order, sharing, endpoints and catalog authority."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HEAD = 'List = use "std/list".\n'
MAX = 4611686018427387903
MIN = f'(0 - {MAX} - 1)'


def main():
    cases = {
        'filter': ('ys = List.filter (fn x -> x <= 2) (List.range 1 4); '
                   'print (ys, List.sum ys, List.length ys)', '([1, 2], 3, 2)\n', None),
        'map-filter': ('ys = List.map (fn x -> x * 2) (List.filter (fn x -> x <= 2) (List.range 1 4)); '
                       'print (ys, List.sum ys, List.length ys)', '([2, 4], 6, 2)\n', None),
        'filter-map': ('ys = List.filter (fn x -> x <= 4) (List.map (fn x -> x * 2) (List.range 1 4)); '
                       'print (ys, List.sum ys, List.length ys)', '([2, 4], 6, 2)\n', None),
        'empty': ('print (List.filter (fn x -> print x >> True) (List.range 3 2))', '[]\n', None),
        'filtered-all': ('print (List.filter (fn x -> False) (List.range 1 4))', '[]\n', None),
        'predicate-effects': ('ys = List.filter (fn x -> print x >> x <= 2) (List.range 1 4); '
                              'print (List.sum ys, List.length ys)', '1\n2\n3\n4\n(3, 2)\n', None),
        'map-effects': ('ys = List.map (fn x -> print x >> x * 2) (List.filter (fn x -> x <= 2) (List.range 1 4)); '
                        'print (List.sum ys, List.length ys)', '1\n2\n(6, 2)\n', None),
        'division-order': ('print (List.filter (fn x -> 10 / x > 0) (List.range 0 2))', '', 'division by zero'),
        'mapped-once-effects': ('print (List.filter (fn x -> x <= 4) (List.map (fn x -> print x >> x * 2) (List.range 1 4)))',
                                '1\n2\n3\n4\n[2, 4]\n', None),
        'capture-before-range': ('k = print "capture" >> 2; '
                                 'ys = List.map (fn x -> x + k) (List.filter (fn x -> x <= k) (List.range 1 4)); '
                                 'print (List.sum ys, List.length ys)', 'capture\n(7, 2)\n', None),
        'max-singleton': (f'print (List.filter (fn x -> True) (List.map (fn x -> x) (List.range {MAX} {MAX})))',
                          f'[{MAX}]\n', None),
        'max-pair': (f'print (List.map (fn x -> x) (List.filter (fn x -> True) (List.range {MAX-1} {MAX})))',
                     f'[{MAX-1}, {MAX}]\n', None),
        'min-singleton-rejected': (f'print (List.filter (fn x -> False) (List.range {MIN} {MIN}))', '', 'overflow'),
        'min-range-before-effects': (f'print (List.filter (fn x -> print x >> True) (List.range {MIN} ({MIN} + 1)))', '', 'overflow'),
        'near-min': (f'print (List.filter (fn x -> True) (List.range ({MIN} + 1) ({MIN} + 2)))',
                     f'[{-(MAX)}, {-(MAX)+1}]\n', None),
        'map-overflow': (f'print (List.map (fn x -> x + 1) (List.filter (fn x -> True) (List.range {MAX} {MAX})))', '', 'overflow'),
        'division-before-overflow': (f'print (List.filter (fn x -> x + {MAX} > 0) (List.map (fn x -> 10 / x) (List.range 0 2)))', '', 'division by zero'),
    }
    with tempfile.TemporaryDirectory(prefix='fpr-list-materialize-') as directory:
        tmp = Path(directory)
        base = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
        base.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=str(tmp/'cache'))

        def build(name, source, env):
            src = tmp/(name+'.fpr'); src.write_text(source)
            exe = tmp/name
            p = subprocess.run([ROOT/'fpr', 'build', src, '--harts', '4', '-o', exe],
                               cwd=ROOT, env=env, capture_output=True, text=True, timeout=180)
            assert not p.returncode, (name, p.stdout[-2000:], p.stderr[-6000:])
            return exe

        for name, (body, stdout, error) in cases.items():
            outcomes = []
            for mode in ('default', 'NO_LIST_FUSE', 'NO_INLINE', 'NO_SPEC'):
                env = dict(base, **({} if mode == 'default' else {f'FPR_{mode}': '1'}))
                exe = build(name+'-'+mode, HEAD+'main = '+body+'.\n', env)
                for harts in ('1', '4'):
                    p = subprocess.run([exe], env=dict(env, FPR_HARTS=harts), capture_output=True, text=True, timeout=30)
                    assert p.stdout == stdout, (name, mode, harts, p)
                    assert (p.returncode == 0 and not p.stderr) if error is None else (
                        p.returncode != 0 and error in p.stderr), (name, mode, harts, p)
                    outcomes.append((p.returncode, p.stdout, p.stderr))
            assert all(x == outcomes[0] for x in outcomes), (name, outcomes)
            print('Materializing pipeline:', name, 'PASS', flush=True)

        # Imported wrappers and captured predicates must still build only the
        # final list. The observed pair is the one boundary allocation.
        (tmp/'helpers.fpr').write_text(HEAD+'make k n = List.map (fn x -> x * 2) (List.filter (fn x -> x <= k) (List.range 1 n)).\n')
        program=HEAD+'H = use "helpers".\nmain = ys = H.make 500 1000; print (List.sum ys, List.length ys).\n'
        env=dict(base,FPR_COST_PROBE='1')
        exe=build('imported',program,env)
        p=subprocess.run([exe],env=dict(env,FPR_HARTS='1',FPR_COST_REPORT='1'),capture_output=True,text=True,timeout=30)
        assert p.returncode==0 and p.stdout=='(250500, 500)\n',p
        ledger=json.loads(re.search(r'\[fpr cost\] (\{.*\})',p.stderr)[1])
        assert ledger['alloc_requests']==501,ledger

        # The fusion target's name is not authority. A wrong decrement must
        # reject the rewrite even when the source combinators are authentic.
        catalog=(ROOT/'std/list.fpr').read_text().replace('use "option"','use "std/option"').replace('use "order"','use "std/order"')
        catalog=catalog.split('# ---- sorting')[0]
        source='List = use "untrusted".\nmain = ys = List.map (fn x -> x * 2) (List.filter (fn x -> x <= 500) (List.range 1 1000)); print (List.sum ys, List.length ys).\n'
        variants = {
            'wrong-step': catalog.replace('buildRangeGo step a (b - 1) (step b acc)', 'buildRangeGo step a (b - 2) (step b acc)'),
            'overflow-prefix': catalog.replace('buildRange step a b = buildRangeGo', f'buildRange step a b = ignored = {MAX} + 1; buildRangeGo'),
        }
        for name, altered in variants.items():
            assert altered != catalog
            (tmp/'untrusted.fpr').write_text(altered)
            exe=build('untrusted-'+name,source,env)
            p=subprocess.run([exe],env=dict(env,FPR_HARTS='1',FPR_COST_REPORT='1'),capture_output=True,text=True,timeout=30)
            assert p.returncode==0 and p.stdout=='(250500, 500)\n',p
            ledger=json.loads(re.search(r'\[fpr cost\] (\{.*\})',p.stderr)[1])
            assert ledger['alloc_requests']==1501,ledger
        print('Materializing pipeline: imported capture allocation and malformed target refusal PASS',flush=True)


if __name__ == '__main__':
    main()
