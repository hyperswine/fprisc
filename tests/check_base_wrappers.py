#!/usr/bin/env python3
"""One-field Base workers: allocation removal, boxed boundaries and strictness."""
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
CELL = 'unsafe base.\nCell a = Type (Cell a).\n'


def loop(count, explicit=False):
    if explicit:
        return ('unsafe base.\ngo n x = if n <= 0 then x else go (n - 1) (x + 1).\n'
                f'main = print (go {count} 0).\n')
    return (CELL + 'go n cell = case cell of Cell x -> if n <= 0 then x else go (n - 1) (Cell (x + 1)).\n'
            f'main = print (go {count} (Cell 0)).\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--record', type=Path)
    parser.add_argument('--benchmark', action='store_true')
    parser.add_argument('--count', type=int, default=5_000_000)
    parser.add_argument('--samples', type=int, default=13)
    args = parser.parse_args()
    assert args.count > 0 and args.samples > 0
    rows, benchmarks = [], []
    with tempfile.TemporaryDirectory(prefix='fpr-base-wrappers-') as directory:
        tmp = Path(directory)
        base = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
        base.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=str(tmp/'cache'))

        def build(name, source, on, isolated=False, probe=False):
            env = dict(base)
            if not on:
                env['FPR_NO_FIELD_WORKERS'] = '1'
            if isolated:
                env.update(FPR_NO_LOOP_REGIONS='1', FPR_NO_CALL_REGIONS='1')
            if probe:
                env.update(FPR_COST_PROBE='1', FPR_COST_REPORT='1')
            path = tmp/(name+'.fpr')
            path.write_text(source)
            exe = tmp/name
            result = subprocess.run([ROOT/'fpr', 'build', path, '--harts', '4', '-o', exe],
                                    cwd=ROOT, env=env, text=True, capture_output=True, timeout=180)
            assert result.returncode == 0, (name, result.stdout[-2000:], result.stderr[-5000:])
            return exe, env

        def execute(exe, env, harts=1):
            return subprocess.run([exe], env=dict(env, FPR_HARTS=str(harts)), text=True,
                                  capture_output=True, timeout=60)

        def ledger(result):
            return json.loads(re.search(r'\[fpr cost\] (\{.*\})', result.stderr)[1])

        # Isolated constructor counts; timing below uses default region settings.
        for explicit in (False, True):
            costs = []
            for on in (False, True):
                exe, env = build(f'count-{explicit}-{on}', loop(1000, explicit), on, True, True)
                for harts in (1, 4):
                    p = execute(exe, env, harts)
                    assert p.returncode == 0 and p.stdout == '1000\n', p
                    cost = ledger(p)['alloc_requests']
                    assert cost == (1001 if not explicit and not on else 0), (explicit, on, harts, cost)
                    rows.append(dict(case='explicit' if explicit else 'wrapper', on=on, harts=harts,
                                     allocations=cost, stdout=p.stdout))
                    if harts == 1:
                        costs.append(cost)
            print(('Explicit' if explicit else 'Wrapper')+f': {costs} allocations, 1/4 harts PASS', flush=True)

        fixtures = {
            'returned': (CELL + 'go n c = case c of Cell x -> if n <= 0 then c else go (n - 1) (Cell (x + 1)).\n'
                         'main = print (case go 1000 (Cell 0) of Cell x -> x).\n', '1000\n'),
            'string': (CELL + 'go n c = case c of Cell x -> if n <= 0 then x else go (n - 1) (Cell x).\n'
                       'main = print (go 1000 (Cell "kept")).\n', 'kept\n'),
            'heap-list': (CELL + 'go n c = case c of Cell x -> if n <= 0 then x else go (n - 1) (Cell x).\n'
                          'main = print (go 1000 (Cell [7, 8])).\n', '[7, 8]\n'),
            'nested': (CELL + 'go n c = case c of Cell inner -> case inner of Cell x -> if n <= 0 then x else go (n - 1) (Cell (Cell (x + 1))).\n'
                       'main = print (go 1000 (Cell (Cell 0))).\n', '1000\n'),
            'record': ('unsafe base.\ngo n c = if n <= 0 then c.value else go (n - 1) {value = c.value + 1}.\n'
                       'main = print (go 1000 {value = 0}).\n', '1000\n'),
            'boolean': (CELL + 'go n c = case c of Cell x -> if n <= 0 then x else go (n - 1) (Cell (if x then False else True)).\n'
                        'main = print (go 1000 (Cell True)).\n', 'True\n'),
            'float': (CELL + 'go : unsafe Int -> Cell F64 -> F64.\ngo n c = case c of Cell x -> if n <= 0 then x else go (n - 1) (Cell (x + 1.0)).\n'
                      'main = print (go 1000 (Cell 1.5)).\n', '1001.5\n'),
            'other-variant': ('unsafe base.\nChoice = Type (Cell Int | Other Int).\n'
                              'go n c = case c of Cell x -> if n <= 0 then x else go (n - 1) (Cell (x + 1)) | Other x -> x + 100.\n'
                              'main = print (go 1000 (Other 9)).\n', '109\n'),
        }
        for name, (source, expected) in fixtures.items():
            costs = []
            for on in (False, True):
                exe, env = build(name+str(on), source, on, True, True)
                for harts in (1, 4):
                    p = execute(exe, env, harts)
                    assert p.returncode == 0 and p.stdout == expected, (name, on, harts, p)
                    cost = ledger(p)['alloc_requests']
                    rows.append(dict(case=name, on=on, harts=harts, allocations=cost, stdout=p.stdout))
                    if harts == 1:
                        costs.append(cost)
            if name != 'other-variant':
                assert costs[0]-costs[1] >= 1000, (name, costs)
            if name == 'nested':
                assert costs == [2002, 0], costs
            # The cost-isolation switches must not hide a region-lifetime bug.
            for on in (False, True):
                exe, env = build(name+'-regions-'+str(on), source, on)
                for harts in (1, 4):
                    p = execute(exe, env, harts)
                    assert p.returncode == 0 and p.stdout == expected and not p.stderr, (name, on, harts, p)
                    rows.append(dict(case=name, on=on, harts=harts, regions='default', stdout=p.stdout))
            print(f'{name}: {costs} allocations, boundary/value checks PASS', flush=True)

        maxint = 4611686018427387903
        limits = (CELL + 'up n c = case c of Cell x -> if n <= 0 then x else up (n - 1) (Cell (x + 1)).\n'
                  'down n c = case c of Cell x -> if n <= 0 then x else down (n - 1) (Cell (x - 1)).\n'
                  f'main = print (up 2 (Cell ({maxint} - 2))) >> print (down 2 (Cell (0 - {maxint} + 1))).\n')
        for on in (False, True):
            exe, env = build('limits'+str(on), limits, on)
            p = execute(exe, env)
            assert p.returncode == 0 and p.stdout == f'{maxint}\n{-maxint-1}\n' and not p.stderr, p
            rows.append(dict(case='integer-limits', on=on, stdout=p.stdout))
        faults = [('maximum', str(maxint), 'x + 1', 'overflow'),
                  ('minimum', f'(0 - {maxint} - 1)', 'x - 1', 'overflow'),
                  ('division', '0', '1 / x', 'division by zero')]
        for name, initial, update, reason in faults:
            source = (CELL + f'go n c = case c of Cell x -> if n <= 0 then x else go (print "counter" >> (n - 1)) (Cell (print "field" >> ({update}))).\n'
                      f'main = print (go 1 (Cell (print "seed" >> {initial}))).\n')
            outcomes = []
            for on in (False, True):
                exe, env = build(name+str(on), source, on)
                p = execute(exe, env)
                assert p.returncode != 0 and reason in p.stderr and p.stdout == 'seed\ncounter\nfield\n', (name, p)
                outcomes.append((p.returncode, p.stdout, p.stderr))
            assert outcomes[0] == outcomes[1], (name, outcomes)
            rows.append(dict(case=name, identical_outcomes=True, stdout=outcomes[0][1], stderr=outcomes[0][2]))
            print(name+': exact ordered effect/failure differential PASS', flush=True)

        # A seed is evaluated even when the zero-iteration arm never reads it.
        unused = (CELL + 'go n c = if n <= 0 then 0 else case c of Cell x -> go (n - 1) (Cell (x + 1)).\n'
                  'main = print (go 0 (Cell (print "seed" >> (1 / 0)))).\n')
        outcomes = []
        for on in (False, True):
            exe, env = build('unused-seed'+str(on), unused, on)
            p = execute(exe, env)
            assert p.returncode != 0 and p.stdout == 'seed\n' and 'division by zero' in p.stderr, p
            outcomes.append((p.returncode, p.stdout, p.stderr))
        assert outcomes[0] == outcomes[1], outcomes
        rows.append(dict(case='unused-seed', identical_outcomes=True, stdout=outcomes[0][1], stderr=outcomes[0][2]))

        (tmp/'wrapper-module.fpr').write_text(loop(1).split('main =')[0])
        client = 'unsafe base.\nMod = use "./wrapper-module".\nmain = print (Mod.go 1000 (Mod.Cell 0)).\n'
        for on in (False, True):
            exe, env = build('module'+str(on), client, on)
            for harts in (1, 4):
                p = execute(exe, env, harts)
                assert p.returncode == 0 and p.stdout == '1000\n' and not p.stderr, p
                rows.append(dict(case='module', on=on, harts=harts, stdout=p.stdout))
        print('Unused strict seed and separate-module tagged entry PASS', flush=True)

        # Normal region placement and fuel remain active in both cost and timing
        # builds. Instrumented allocation measurements never supply timings.
        if args.benchmark:
            builds = {}
            for label, explicit, on in [('boxed', False, False), ('worker', False, True), ('explicit', True, True)]:
                source = loop(args.count, explicit)
                probe, env = build('probe-'+label, source, on, probe=True)
                p = execute(probe, env)
                assert p.returncode == 0 and p.stdout == str(args.count)+'\n', (label, p)
                cost = ledger(p)
                exe, plain = build('bench-'+label, source, on)
                warm = execute(exe, plain)
                assert warm.returncode == 0 and warm.stdout == p.stdout and not warm.stderr, (label, warm)
                builds[label] = exe, plain
                benchmarks.append(dict(form=label, ledger=cost, samples_seconds=[]))
            by_name = {r['form']: r for r in benchmarks}
            for sample in range(args.samples):
                order = list(builds) if sample % 2 == 0 else list(reversed(builds))
                for label in order:
                    exe, env = builds[label]
                    start = time.perf_counter()
                    p = execute(exe, env)
                    elapsed = time.perf_counter()-start
                    assert p.returncode == 0 and p.stdout == str(args.count)+'\n' and not p.stderr, p
                    by_name[label]['samples_seconds'].append(elapsed)
            for row in benchmarks:
                row['median_seconds'] = statistics.median(row['samples_seconds'])
                print(row['form']+': '+str(row['ledger']['alloc_requests'])+' allocations; median '+str(row['median_seconds']), flush=True)
        if args.record:
            args.record.write_text(json.dumps(dict(compiler_sha256=hashlib.sha256((ROOT/'fpr').read_bytes()).hexdigest(),
                                                  test_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                                                  cases=rows, benchmark_count=args.count if args.benchmark else None,
                                                  benchmarks=benchmarks), indent=2)+'\n')


if __name__ == '__main__':
    main()
