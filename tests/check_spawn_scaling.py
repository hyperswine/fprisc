#!/usr/bin/env python3
"""Spawning and reaping short-lived actors stays linear in their number
(docs/2026-11-11-ACTOR-DEATH-COSTS.md).

Three things used to make it quadratic or worse, each proportional to every
actor ever spawned:

  * a new actor's watcher count was never initialised, so on recycled memory
    every death walked the whole actor ledger;
  * a death with a real watcher (receiveFromRes) walked it by design;
  * a spawn walked the channel-block limbo list under its lock, past every
    block reaped since the harts were last all awake.

Each workload runs at n and at 8n (a third case checks that what dead
workers held is usable again on a small heap). Linear work is 8 times the time; the
check allows 24 times plus a second of fixed cost, and the old code took
between 60 and several hundred times."""
from pathlib import Path
import os, subprocess, sys, tempfile, time

ROOT = Path(__file__).resolve().parents[1]

WATCH = """unsafe base.
worker : unsafe Int -> Int -> Unit .
worker k self = _ = sumTo k 0; Unit.
sumTo : unsafe Int -> Int -> Int .
sumTo n acc = if n == 0 then acc else sumTo (n - 1) (acc + 1).
run : unsafe Int -> Int -> Int -> Int .
run me n acc = if n == 0 then acc else
  w = spawn (worker 50);
  r = receiveFromRes me w;
  run me (n - 1) (acc + (case r of Ok _ -> 0 | Err _ -> 1)).
main = me = myself 0; print (run me COUNT 0).
"""

REPLY = """unsafe base.
worker : unsafe Int -> Int -> Int -> Unit .
worker parent k self = _ = send parent (sumTo k 0); Unit.
sumTo : unsafe Int -> Int -> Int .
sumTo n acc = if n == 0 then acc else sumTo (n - 1) (acc + 1).
run : unsafe Int -> Int -> Int -> Int .
run me n acc = if n == 0 then acc else
  w = spawn (worker me 50);
  r = receiveFrom me w;
  run me (n - 1) (acc + r).
boss : unsafe Int -> Int -> Int -> Unit .
boss parent n self = _ = send parent (run self n 0); Unit.
main =
  me = myself 0;
  b1 = spawn (boss me COUNT); b2 = spawn (boss me COUNT); b3 = spawn (boss me COUNT); b4 = spawn (boss me COUNT);
  print (receiveFrom me b1 + receiveFrom me b2 + receiveFrom me b3 + receiveFrom me b4).
"""


# After four spawners have churned 800 workers on a 16 MiB heap, the main
# actor asks for a 300,000-cell list (7.2 MiB of cells).  It fits only if
# what the dead workers held came back: their channel blocks out of limbo,
# and the blocks the harts cache released when the buddy runs short
# (docs/2026-11-11-HART-BLOCK-CACHE.md).  Before, it was "heap exhausted".
SMALL_HEAP = """unsafe base.
worker : unsafe Int -> Int -> Int -> Unit .
worker parent k self = _ = send parent (lenOf (build k Nil) 0); Unit.
build : unsafe Int -> List Int -> List Int .
build n acc = if n == 0 then acc else build (n - 1) (n :: acc).
lenOf : unsafe List Int -> Int -> Int .
lenOf xs acc = case xs of _ :: r -> lenOf r (acc + 1) | _ -> acc.
run : unsafe Int -> Int -> Int -> Int .
run me n acc = if n == 0 then acc else
  w = spawn (worker me 20000);
  r = receiveFrom me w;
  run me (n - 1) (acc + r).
boss : unsafe Int -> Int -> Int -> Unit .
boss parent n self = _ = send parent (run self n 0); Unit.
main =
  me = myself 0;
  b1 = spawn (boss me 200); b2 = spawn (boss me 200); b3 = spawn (boss me 200); b4 = spawn (boss me 200);
  r = receiveFrom me b1 + receiveFrom me b2 + receiveFrom me b3 + receiveFrom me b4;
  print "{r} {lenOf (build 300000 Nil) 0}".
"""


def main():
    with tempfile.TemporaryDirectory(prefix='fpr-spawn-scaling-') as d:
        tmp = Path(d)
        env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT),
                   XDG_CACHE_HOME=os.environ.get('XDG_CACHE_HOME', str(tmp / 'cache')))
        env.pop('FPR_FOREIGN', None)
        for name, source, small, answer in (('watched workers', WATCH, 5000, lambda n: n),
                                            ('four concurrent spawners', REPLY, 2500, lambda n: 4 * n * 50)):
            times = {}
            for n in (small, 8 * small):
                src = tmp / f'p{n}.fpr'
                src.write_text(source.replace('COUNT', str(n)))
                exe = tmp / f'p{n}'
                p = subprocess.run([str(ROOT / 'fpr'), 'build', str(src), '--harts', '4', '-o', str(exe)],
                                   cwd=ROOT, env=env, capture_output=True, text=True, timeout=300)
                assert p.returncode == 0, p.stderr[-2000:]
                best = None
                for _ in range(3):
                    start = time.perf_counter()
                    r = subprocess.run([str(exe)], env=env, capture_output=True, text=True, timeout=600)
                    took = time.perf_counter() - start
                    assert r.returncode == 0 and r.stdout.strip() == str(answer(n)), (name, n, r.returncode, r.stdout[-200:], r.stderr[-500:])
                    best = took if best is None else min(best, took)
                times[n] = best
            a, b = times[small], times[8 * small]
            assert b <= 24 * a + 1.0, (name, times, 'eight times the actors took more than 24 times as long')
            print(f'{name}: {small} in {a:.3f} s, {8 * small} in {b:.3f} s ({b / a:.1f}x for 8x) PASS', flush=True)
        src = tmp / 'small.fpr'
        src.write_text(SMALL_HEAP)
        exe = tmp / 'small'
        p = subprocess.run([str(ROOT / 'fpr'), 'build', str(src), '--harts', '4', '-o', str(exe)],
                           cwd=ROOT, env=env, capture_output=True, text=True, timeout=300)
        assert p.returncode == 0, p.stderr[-2000:]
        for _ in range(3):
            r = subprocess.run([str(exe)], env=dict(env, FPR_HEAP_MB='16'), capture_output=True, text=True, timeout=120)
            assert r.returncode == 0 and r.stdout.strip() == '16000000 300000', (r.returncode, r.stdout[-300:], r.stderr[-500:])
        print('16 MiB heap: 800 dead workers leave room for a 300,000-cell list PASS', flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
