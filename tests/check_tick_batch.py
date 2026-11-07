#!/usr/bin/env python3
"""Batched fuel ticks in self-looping functions (FPR_NO_TICK_BATCH=1 rolls back).

A function that calls itself keeps one entry tick per iteration; the entry
ticks of callees inlined into its body are dropped after lowering
(Codegen.Placement, since 2026-11-07; before that Core.Opt.Ticks on erased
Core, with the scalar workers applying the same rule). Checks: identical output
with batching on and off on the unbox benchmarks; the fused list_sum scalar
worker and the non-worker fused list_filter loop emit one tick on RV64 batched
and more unbatched; and a child spinning in a batched worker is still
preempted (1 and 4 harts), so the parent receives its message and kills it."""
import os, re, subprocess, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]

def run(args, env, timeout=240):
    p = subprocess.run(list(map(str, args)), cwd=ROOT, env=env, text=True, capture_output=True, timeout=timeout)
    return p

FAIR = '''unsafe base.
List = use "std/list".
go : unsafe Int -> Int -> Int .
go r acc = if r == 0 then acc else go (r - 1) (acc + List.sum (List.range 1 1000) - 500500).
hog parent self = _ = send parent 1; go 4000000000000000000 0.
main = me = myself 0; child = spawn (hog me); msg = receiveFrom me child; saved = keep msg; _ = kill child; print saved.
'''

def main():
    with tempfile.TemporaryDirectory(prefix='fpr-tick-batch-') as d:
        tmp = Path(d)
        base = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
        base.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), FPR_HARTS='1')
        def env(batched):
            e = dict(base, XDG_CACHE_HOME=str(tmp / ('c-on' if batched else 'c-off')))
            if not batched: e['FPR_NO_TICK_BATCH'] = '1'
            return e
        for name in ['list_sum', 'list_map', 'list_filter', 'list_fold', 'list_length_rev', 'option_loop', 'loop_sum', 'tuple_loop', 'tree_sum', 'string_scan']:
            seen = []
            for batched in (True, False):
                exe = tmp / f'{name}.{batched}'
                b = run([ROOT / 'fpr', 'build', ROOT / 'tests/bench/unbox' / (name + '.fpr'), '--harts', '1', '-o', exe], env(batched))
                assert b.returncode == 0, b.stderr[-3000:]
                r = run([exe], env(batched))
                seen.append((r.returncode, r.stdout, r.stderr))
            assert seen[0] == seen[1] and seen[0][0] == 0, (name, seen)
        print('Tick batching: unbox benchmarks identical on and off PASS', flush=True)

        ticks = {}
        for batched in (True, False):
            out = tmp / f'sum-{batched}.s'
            c = run([ROOT / 'fpr', 'compile', '--system=posix', '--target=rv64', ROOT / 'tests/bench/unbox/list_sum.fpr', out], env(batched))
            assert c.returncode == 0, c.stderr[-3000:]
            text = out.read_text() + ''.join(Path(p).read_text() for p in Path(str(out) + '.units').read_text().split())
            m = re.search(r'^fpr_fn__x24worker_x2escalar_x2e_x24typed_x2emono_x2ego_x2e1:\n(.*?)# native-insns-v1', text, re.S | re.M)
            assert m, 'fused list_sum scalar worker not found'
            ticks[batched] = m.group(1).count('call fpr_fuel_save_local')
        # Unbatched, each inlined callee keeps a tick (2 on the loop path, 3 in
        # the worker since foldRange's final step inlines its own callback).
        assert ticks[True] == 1 and ticks[False] >= 2, ticks
        print(f'Tick batching: fused list_sum worker has 1 tick on RV64 ({ticks[False]} unbatched) PASS', flush=True)

        filt = {}
        for batched in (True, False):
            out = tmp / f'filter-{batched}.s'
            c = run([ROOT / 'fpr', 'compile', '--system=posix', '--target=rv64', ROOT / 'tests/bench/unbox/list_filter.fpr', out], env(batched))
            assert c.returncode == 0, c.stderr[-3000:]
            text = out.read_text() + ''.join(Path(p).read_text() for p in Path(str(out) + '.units').read_text().split())
            m = re.search(r'^fpr_fn__x24typed_x2emono_x2ego_x2e1:\n(.*?)# native-insns-v1', text, re.S | re.M)
            assert m, 'fused list_filter loop not found'
            filt[batched] = m.group(1).count('call fpr_fuel_save_local')
        assert filt[True] == 1 and filt[False] >= 2, filt
        print(f'Tick batching: non-worker fused list_filter loop has 1 tick on RV64 ({filt[False]} unbatched) PASS', flush=True)

        src = tmp / 'fair.fpr'; src.write_text(FAIR)
        for harts in ('1', '4'):
            e = dict(env(True), FPR_HARTS=harts)
            exe = tmp / f'fair{harts}'
            b = run([ROOT / 'fpr', 'build', src, '--harts', harts, '-o', exe], e)
            assert b.returncode == 0, b.stderr[-3000:]
            r = run([exe], e, timeout=60)
            assert r.returncode == 0 and r.stdout == '1\n', (harts, r.returncode, r.stdout, r.stderr[-2000:])
        print('Tick batching: a spinning batched worker is still preempted (1/4 harts) PASS', flush=True)

if __name__ == '__main__':
    main()
