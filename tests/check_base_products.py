#!/usr/bin/env python3
"""Checked Base product parameters: allocations, boundaries and strictness.

Large helpers deliberately exceed ordinary inlining budgets. They run with
normal region placement as well as allocation-isolation switches. Disabling
constructor inlining is a semantic control, not an allocation-removal promise.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
CELL = 'Cell a = Type (Cell a).\n'


def chain(value='x', last='y31'):
    return '; '.join(f'y{i} = ' + (value if i == 0 else f'y{i-1}') + ' + 1'
                     for i in range(32)) + '; ' + last


def loop(count, explicit=False):
    helper = 'bump x = ' + chain() + '.\n' if explicit else (
        CELL + 'bump c = case c of Cell x -> ' + chain() + ' | _ -> 99.\n')
    call = 'bump x' if explicit else 'bump (Cell x)'
    return ('unsafe base.\n' + helper + f'go n x = if n <= 0 then x else go (n - 1) ({call}).\n'
            f'main = print (go {count} 0).\n')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--compiler', type=Path, default=ROOT/'fpr')
    ap.add_argument('--old', action='store_true', help='saved pre-change compiler allocation oracle')
    ap.add_argument('--record', type=Path)
    ap.add_argument('--benchmark', action='store_true')
    ap.add_argument('--count', type=int, default=5_000_000)
    ap.add_argument('--samples', type=int, default=13)
    args = ap.parse_args()
    compiler = args.compiler.resolve()
    rows, timing = [], []
    with tempfile.TemporaryDirectory(prefix='fpr-base-products-') as directory:
        tmp = Path(directory)
        base = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
        base.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=str(tmp/'cache'))

        def build(name, source, switches=None, isolated=False, probe=False):
            env = dict(base, **(switches or {}))
            if isolated:
                env.update(FPR_NO_LOOP_REGIONS='1', FPR_NO_CALL_REGIONS='1')
            if probe:
                env.update(FPR_COST_PROBE='1', FPR_COST_REPORT='1')
            src, exe = tmp/(name+'.fpr'), tmp/name
            src.write_text(source)
            p = subprocess.run([compiler, 'build', src, '--harts', '4', '-o', exe],
                               cwd=ROOT, env=env, text=True, capture_output=True, timeout=180)
            assert p.returncode == 0, (name, p.stdout[-2000:], p.stderr[-5000:])
            return exe, env

        def execute(build, harts=1):
            exe, env = build
            return subprocess.run([exe], env=dict(env, FPR_HARTS=str(harts)), text=True,
                                  capture_output=True, timeout=60)

        def check(name, source, expected, removal=True):
            counts = {}
            for label, switches in [('default', {}), ('boxed', {'FPR_NO_FIELD_WORKERS': '1'})]:
                built = build(name+'-'+label, source, switches, True, True)
                for harts in (1, 4):
                    p = execute(built, harts)
                    assert p.returncode == 0 and p.stdout == expected, (name, label, harts, p)
                    cost = json.loads(re.search(r'\[fpr cost\] (\{.*\})', p.stderr)[1])
                    rows.append(dict(case=name, mode=label, harts=harts, cost=cost, stdout=p.stdout))
                    counts[label] = cost['alloc_requests']
                normal = build(name+'-regions-'+label, source, switches)
                for harts in (1, 4):
                    p = execute(normal, harts)
                    assert p.returncode == 0 and p.stdout == expected and not p.stderr, (name, label, harts, p)
                    rows.append(dict(case=name, mode=label, harts=harts, regions='normal', stdout=p.stdout))
            if removal:
                assert counts['boxed']-counts['default'] == (0 if args.old else 1000), (name, counts)
            print(f'{name}: {counts}, normal regions and 1/4 harts PASS', flush=True)
            return counts

        counts = check('cell', loop(1000), '32000\n')
        assert counts == dict(default=1000 if args.old else 0, boxed=1000), counts
        counts = check('explicit', loop(1000, True), '32000\n', False)
        assert counts == dict(default=0, boxed=0), counts
        for width in (2, 4, 8):
            fields = ','.join(['x']+[f'v{i}' for i in range(1, width)])
            values = ','.join(['x']+['0']*(width-1))
            source = ('unsafe base.\nbump p = case p of ('+fields+') -> '+chain(' + '.join(fields.split(',')))+'.\n'
                      f'go n x = if n <= 0 then x else go (n - 1) (bump ({values})).\n'
                      'main = print (go 1000 0).\n')
            check('tuple'+str(width), source, '32000\n')
        record = ('unsafe base.\nbump : unsafe {x : Int, y : Int} -> Int.\n'
                  'bump p = '+chain('p.x + p.y')+'.\n'
                  'go n x = if n <= 0 then x else go (n - 1) (bump {y = 0, x = x}).\n'
                  'main = print (go 1000 0).\n')
        check('closed-record', record, '32000\n')
        generic = ('unsafe base.\n'+CELL+'retainCell c n = case c of Cell x -> '+chain('n', 'if y31 >= 0 then x else error "negative"')+'.\n'
                   'go n x = if n <= 0 then x else go (n - 1) (retainCell (Cell x) n).\n')
        check('generic-string', generic+'main = print (go 1000 "retained").\n', 'retained\n')
        check('generic-list', generic+'main = print (go 1000 [7, 8]).\n', '[7, 8]\n')

        # A dynamic receiver can supply a different nominal value even though
        # the checked function parameter has a concrete Cell type.
        helper = loop(1).split('go n')[0]
        dynamic = (helper+'receiver parent self = x = receive self; send parent (bump x).\n'
                   'main = _ = print (bump (Cell 0)); me = myself 0; a = spawnOn 0 (receiver me); '
                   '_ = send a 7; print (receiveFrom me a).\n')
        check('dynamic-message-fallback', dynamic, '32\n99\n', False)
        (tmp/'helper-module.fpr').write_text(helper+'local n = bump (Cell n).\n'
            'moduleGo n x = if n <= 0 then x else moduleGo (n - 1) (bump (Cell x)).\n')
        check('separate-module', 'unsafe base.\nM = use "./helper-module".\n'
              'main = print (M.local 7) >> print (M.bump (M.Cell 9)).\n', '39\n41\n', False)
        check('module-owned-loop', 'unsafe base.\nM = use "./helper-module".\n'
              'main = print (M.moduleGo 1000 0).\n', '32000\n')
        check('partial-application', helper+'apply f x = f x.\n'
              'main = print (bump (Cell 0)) >> print (apply bump (Cell 9)).\n', '32\n41\n', False)

        maxint = 4611686018427387903
        ordered = ('unsafe base.\nPair = Type (Pair Int Int).\n'
                   'consumeProduct before p after = case p of Pair x y -> '+chain('x', 'before + y31 + y + after')+'.\n')
        cases = {
            'effects': (ordered+'main = print (consumeProduct (print "before" >> 1) '
                        '(Pair (print "left" >> 2) (print "right" >> 3)) (print "after" >> 4)).\n',
                        'before\nleft\nright\nafter\n42\n', None),
            'unused-strict': (ordered+'main = print (consumeProduct 0 (Pair 0 (print "field" >> (1 / 0))) (print "after" >> 0)).\n',
                              'field\n', 'division by zero'),
            'maximum': (helper+f'main = print (bump (Cell (print "field" >> {maxint}))).\n', 'field\n', 'overflow'),
            'minimum': ('unsafe base.\n'+CELL+'down c = case c of Cell x -> '+chain('x', f'y31 + (0 - {maxint} - 1)')+'.\n'
                        'main = print (down (Cell (print "field" >> (0 - 33)))).\n', 'field\n', 'overflow'),
            'bounds': (helper+f'main = print (bump (Cell ({maxint} - 32))) >> '
                       f'print (bump (Cell (0 - {maxint} - 1))).\n', f'{maxint}\n{-maxint-1+32}\n', None),
        }
        for name, (source, expected, reason) in cases.items():
            outcomes = []
            for label, switches in [('default', {}), ('boxed', {'FPR_NO_FIELD_WORKERS': '1'}),
                                    ('tuple-off', {'FPR_NO_TUPLE_SCALARS': '1'}), ('no-inline', {'FPR_NO_INLINE': '1'})]:
                p = execute(build(name+'-'+label, source, switches))
                assert p.stdout == expected, (name, label, p)
                assert (p.returncode != 0 and reason in p.stderr) if reason else (p.returncode == 0 and not p.stderr), (name, label, p)
                outcomes.append((p.returncode, p.stdout, p.stderr))
            assert len(set(outcomes)) == 1, (name, outcomes)
            rows.append(dict(case=name, modes=4, returncode=outcomes[0][0], stdout=outcomes[0][1], stderr=outcomes[0][2]))
            print(name+': exact four-mode effect/trap differential PASS', flush=True)

        if args.benchmark:
            assert args.count > 0 and args.samples > 0
            builds = {}
            for label, explicit, switches in [('boxed', False, {'FPR_NO_FIELD_WORKERS':'1'}),
                                               ('worker', False, {}), ('explicit', True, {})]:
                src = loop(args.count, explicit)
                p = execute(build('probe-'+label, src, switches, probe=True))
                assert p.returncode == 0 and p.stdout == str(args.count*32)+'\n', p
                cost = json.loads(re.search(r'\[fpr cost\] (\{.*\})', p.stderr)[1])
                built = build('bench-'+label, src, switches)
                warm = execute(built)
                assert warm.returncode == 0 and warm.stdout == p.stdout and not warm.stderr, warm
                builds[label] = built
                timing.append(dict(form=label, cost=cost, samples_seconds=[]))
            by_name = {r['form']: r for r in timing}
            for sample in range(args.samples):
                for label in list(builds)[::1 if sample % 2 == 0 else -1]:
                    start = time.perf_counter()
                    p = execute(builds[label])
                    elapsed = time.perf_counter()-start
                    assert p.returncode == 0 and p.stdout == str(args.count*32)+'\n' and not p.stderr, p
                    by_name[label]['samples_seconds'].append(elapsed)
            for row in timing:
                row['median_seconds'] = statistics.median(row['samples_seconds'])
                print(f"{row['form']}: {row['cost']['alloc_requests']} allocations; median {row['median_seconds']:.6f}s", flush=True)
        if args.record:
            args.record.write_text(json.dumps(dict(compiler_sha256=hashlib.sha256(compiler.read_bytes()).hexdigest(),
                test_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), old=args.old,
                cases=rows, benchmark_count=args.count if args.benchmark else None, timings=timing), indent=2)+'\n')


if __name__ == '__main__':
    main()
