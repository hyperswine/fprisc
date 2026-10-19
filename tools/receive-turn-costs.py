#!/usr/bin/env python3
"""The fixed cost of a receive turn (docs/2026-10-19-RECEIVE-TURN-ARENA.md).

Three request/reply pairs, each a recognised receive loop on both sides
(tests/bench/pingpong.fpr is the `small` shape), run as one pair per hart:

  small   the ponger's state is its own handle (an Int): the turn allocates
          nothing and the state copy is nothing
  record  the state is (count, the last eight requests): a few cells
          allocated per turn, a few copied
  big     the state is a 1,000-cell list reversed every turn: a thousand
          cells allocated per turn, a thousand copied

The pinger's own state (me, p, k, acc) is a tuple, so it too copies per turn.
Every pair is built twice, with and without FPR_COST_PROBE: the ledger (turns,
buddy blocks taken and returned, message slabs, allocation bytes) comes from
the instrumented build, the time from the plain one (the best of --runs).  A one-hart process pays
about 250 ms at exit whatever it ran (the hart loop's idle poll): the per-turn
number to read on one hart is cpu_ns_per_turn, the wall clock is for four.
Writes JSON to stdout; nothing here updates a baseline."""
import argparse, json, os, resource, subprocess, tempfile, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
HEADER = '''Cost.begin : Unit -> Unit .
Cost.report : Unit -> String .
'''
COMMON = '''
ping : unsafe Int -> Int -> Int -> Int -> Int .
ping me p k acc = if k == 0 then acc else
  _ = send p (me, k);
  r = receiveFrom me p;
  ping me p (k - 1) (acc + r).
collect : unsafe Int -> List Int -> Int -> Int .
collect me ds acc = case ds of
  Nil -> acc
  | d :: rest -> r = receiveFrom me d; collect me rest (acc + r).
spawnAll : unsafe Int -> Int -> Int -> Int -> List Int -> List Int .
spawnAll boss h harts n acc = if h == harts then acc else
  d = spawnOn h (driver boss h n);
  spawnAll boss (h + 1) harts n (d :: acc).
'''
SHAPES = {
 'small': '''
ponger : unsafe Int -> a .
ponger self = m = receive self; (who, n) = m; _ = drop m; _ = send who (n + 1); ponger self.
driver : unsafe Int -> Int -> Int -> Int -> Unit .
driver boss h n self = p = spawnOn h ponger; total = ping self p n 0; _ = kill p; _ = send boss total; Unit.
''',
 'record': '''
lastN : unsafe Int -> List Int -> List Int .
lastN k xs = if k == 0 then Nil else case xs of Nil -> Nil | x :: rest -> x :: lastN (k - 1) rest.
ponger : unsafe (Int, List Int) -> Int -> a .
ponger st self = m = receive self; (who, n) = m; _ = drop m; (c, recent) = st;
  _ = send who (n + c); ponger (c + 1, lastN 8 (n :: recent)) self.
driver : unsafe Int -> Int -> Int -> Int -> Unit .
driver boss h n self = p = spawnOn h (ponger (0, Nil)); total = ping self p n 0; _ = kill p; _ = send boss total; Unit.
''',
 'big': '''
mkList : unsafe Int -> List Int -> List Int .
mkList k acc = if k == 0 then acc else mkList (k - 1) (k :: acc).
revOnto : unsafe List Int -> List Int -> List Int .
revOnto xs acc = case xs of Nil -> acc | x :: rest -> revOnto rest (x :: acc).
headOr : List Int -> Int .
headOr xs = case xs of Nil -> 0 | x :: _ -> x.
ponger : unsafe List Int -> Int -> a .
ponger xs self = m = receive self; (who, n) = m; _ = drop m; ys = revOnto xs Nil;
  _ = send who (n + headOr ys); ponger ys self.
driver : unsafe Int -> Int -> Int -> Int -> Unit .
driver boss h n self = p = spawnOn h (ponger (mkList 1000 Nil)); total = ping self p n 0; _ = kill p; _ = send boss total; Unit.
''',
}
def expected(shape, n, pairs):
    if shape == 'small': one = sum(k + 1 for k in range(n, 0, -1))
    elif shape == 'record': one = sum(k + (n - k) for k in range(n, 0, -1))
    else: one = sum(k + (1000 if i % 2 == 0 else 1) for i, k in enumerate(range(n, 0, -1)))
    return one * pairs
def run(args, env, timeout=600):
    p = subprocess.run([str(x) for x in args], cwd=ROOT, env=env, capture_output=True, text=True, timeout=timeout)
    assert p.returncode == 0, f'{args}: {p.returncode}\n{p.stdout}{p.stderr}'
    return p.stdout
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--runs', type=int, default=3)
    ap.add_argument('--harts', type=int, nargs='+', default=[1, 4])
    ap.add_argument('--shapes', nargs='+', default=list(SHAPES), choices=list(SHAPES))
    ap.add_argument('--turns', type=int, nargs=3, default=[500000, 200000, 20000], metavar=('SMALL', 'RECORD', 'BIG'),
                    help='request/reply rounds per pair, one per shape')
    a = ap.parse_args()
    assert a.runs > 0 and all(1 <= h <= 8 for h in a.harts)
    base = {**os.environ, 'FPR_HOME': str(ROOT), 'FPR_PATH': str(ROOT)}; base.pop('FPR_FOREIGN', None)
    run(['make', 'fpr'], base)
    rounds = dict(zip(SHAPES, a.turns))
    results = []
    with tempfile.TemporaryDirectory(prefix='fpr-turns-') as d:
        tmp = Path(d)
        for shape in a.shapes:
            for harts in a.harts:
                n = rounds[shape]
                src = tmp / f'{shape}.fpr'
                src.write_text(HEADER + SHAPES[shape] + COMMON + f'''
main = me = myself 0; _ = Cost.begin Unit; ds = spawnAll me 0 {harts} {n} Nil;
  total = collect me ds 0; stats = Cost.report Unit; _ = print "check: {{total}}"; print stats.
''')
                want = f'check: {expected(shape, n, harts)}'
                times, ledger, cpu = [], None, None
                for probe in (False, True):
                    exe = tmp / f'{shape}-{harts}-{int(probe)}'
                    env = {**base, 'FPR_HARTS': str(harts), 'FPR_COST_PROBE': '1' if probe else '0'}
                    run(['./fpr', 'build', src, '--harts', str(max(a.harts)), '--with', ROOT / 'tests/bench/costprobe.c', '-o', exe], env)
                    for _ in range(a.runs):
                        before = resource.getrusage(resource.RUSAGE_CHILDREN)
                        start = time.perf_counter(); out = run([exe], env); wall = time.perf_counter() - start
                        after = resource.getrusage(resource.RUSAGE_CHILDREN)
                        lines = out.splitlines(); assert len(lines) == 2 and lines[0] == want, out
                        got = json.loads(lines[1])
                        if probe: ledger = got
                        else:
                            assert not any(got.values()), got
                            times.append(wall)
                            cpu = cpu or []; cpu.append((after.ru_utime - before.ru_utime) + (after.ru_stime - before.ru_stime))
                turns = ledger['turns']; best = min(times)
                per = lambda k: round(ledger[k] / turns, 4)
                results.append({'shape': shape, 'harts': harts, 'pairs': harts, 'rounds_per_pair': n, 'turns': turns,
                                'best_ms': round(best * 1000, 1), 'cpu_ms': round(min(cpu) * 1000, 1),
                                'turns_per_second': round(turns / best), 'cpu_ns_per_turn': round(min(cpu) * 1e9 / turns, 1),
                                'per_turn': {'buddy_allocs': per('buddy_allocs'), 'buddy_frees': per('buddy_frees'),
                                             'message_slabs': per('message_slabs'), 'alloc_requests': per('alloc_requests'),
                                             'alloc_bytes': per('alloc_bytes'), 'copy_bytes': per('copy_bytes')},
                                'ledger': ledger})
                print(json.dumps(results[-1]), file=__import__('sys').stderr, flush=True)
    print(json.dumps({'results': results}, indent=1))
if __name__ == '__main__': main()
