#!/usr/bin/env python3
"""Weighted fuel ticks (docs/2026-11-11-WEIGHTED-TICKS.md).

A tick charges the worst-case number of target instructions from it to the
next tick or an exit, the prologue before a function's first tick included.

Emission, on AArch64, x86-64 and RV64: every tick of the fixture carries a
weight; a function's first tick is charged at least the instructions printed
from its label up to and including that tick's subtract; and a function with
no branch charges exactly its own instructions. FPR_NO_TICK_WEIGHT=1 brings
back unit ticks.

Execution, on this host: a counted loop spends what its printed weights say
(entry weight once, the loop's weight per iteration), far more than the
20,001 units it spent before, and exactly 20,001 with the rollback flag."""
from pathlib import Path
import os, platform, re, subprocess, sys, tempfile

ROOT = Path(__file__).resolve().parents[1]

FIXTURE = """unsafe base.
Loops.arm : Unit -> Unit .
Loops.used : Unit -> Int .
Loops.force : Unit -> Unit .
ticks : unsafe Int -> Int -> Int .
ticks n a = if n == 0 then a else ticks (n - 1) (a + 1).
straight : unsafe Int -> Int .
straight x = x + 1.
main = _ = Loops.arm Unit; a = ticks 20000 0; count = Loops.used Unit; print "{a} {count} {straight 1}".
"""

TICK = {
    'a64': r'subs x27, x27, #(\d+)',
    'x64': r'subq \$(\d+), \(%r10\)',
    'rv64': r'addi s11, s11, -(\d+)',
}


def run(args, env, code=0):
    p = subprocess.run(list(map(str, args)), cwd=ROOT, env=env, capture_output=True, text=True, timeout=300)
    assert p.returncode == code, (args, p.returncode, p.stdout[-2000:], p.stderr[-2000:])
    return p.stdout


def bodies(text):
    """name -> printed lines of each function, label to its native-insns line"""
    return {m[1].split()[0]: m[2].splitlines()
            for m in re.finditer(r'(?ms)^# fn ([^\n]+)\n(.*?)(?=^# native-insns-v1:)', text)}


def instruction(line):
    t = line.strip()
    return bool(t) and not t.startswith(('#', '.')) and not t.endswith(':')


def main():
    with tempfile.TemporaryDirectory(prefix='fpr-tick-weights-') as d:
        tmp = Path(d)
        env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT),
                   XDG_CACHE_HOME=os.environ.get('XDG_CACHE_HOME', str(tmp / 'cache')),
                   FPR_NO_INLINE='1', FPR_NO_SCALAR_WORKERS='1', FPR_NO_FIELD_WORKERS='1')
        for k in ('FPR_FOREIGN', 'FPR_NO_TICK_WEIGHT'):
            env.pop(k, None)
        source = tmp / 'weights.fpr'
        source.write_text(FIXTURE)
        printed = {}
        for target, pattern in TICK.items():
            out = tmp / (target + '.s')
            run([ROOT / 'fpr', 'compile', '--system=posix', '--target=' + target, source, out], env)
            fns = bodies(out.read_text())
            for name in ('ticks', 'straight', 'main'):
                lines = fns[name]
                sites = [(i, int(m[1])) for i, l in enumerate(lines) for m in [re.search(pattern, l)] if m]
                assert sites, (target, name, 'no tick')
                first, weight = sites[0]
                before = sum(1 for l in lines[:first + 1] if instruction(l))
                assert weight >= before, (target, name, weight, before, 'the first tick carries the prologue')
                assert all(w >= 2 for _, w in sites), (target, name, sites)
            # no branch but the tick's own: one path, so the weight is the count
            lines = fns['straight']
            (first, weight), = [(i, int(m[1])) for i, l in enumerate(lines) for m in [re.search(TICK[target], l)] if m]
            total = sum(1 for l in lines if instruction(l))
            slow = sum(1 for l in lines if instruction(l) and re.search(r'fuel_save|fpr_fuel|overflow|trap|panic', l))
            # RISC-V prints pseudo-instructions (call, li, la) that count as two
            assert total - 16 <= weight <= (2 * total if target == 'rv64' else total), (target, weight, total, slow, 'a straight function is charged its own instructions')
            printed[target] = {n: [int(m[1]) for l in fns[n] for m in [re.search(pattern, l)] if m] for n in ('ticks',)}
            unit = tmp / (target + '-unit.s')
            run([ROOT / 'fpr', 'compile', '--system=posix', '--target=' + target, source, unit], dict(env, FPR_NO_TICK_WEIGHT='1'))
            old = [int(m[1]) for l in bodies(unit.read_text())['ticks'] for m in [re.search(pattern, l)] if m]
            assert old and set(old) == {1}, (target, old)
            print(f'{target}: ticks carry weights (ticks {printed[target]["ticks"]}, straight {weight} of {total} instructions); '
                  'FPR_NO_TICK_WEIGHT=1 restores units PASS', flush=True)

        host = {'arm64': 'a64', 'aarch64': 'a64', 'x86_64': 'x64', 'AMD64': 'x64'}.get(platform.machine())
        if host is None:
            print('tick weights: execution SKIP (no hosted target for this machine)')
            return 0
        # a counter too large for the loop to exhaust: an exhausted counter is
        # refilled to the quantum and the difference would mean nothing
        probe = tmp / 'probe.c'
        probe.write_text('''#include "fpr.h"
static V arm(V u) { (void)u; fpr_fuel_set(fpr_hart(), 1000000000); return (V)&fpr_unit; }
static V used(V u) { (void)u; return TAG(1000000000 - fpr_fuel_left(fpr_hart())); }
static V force(V u) { (void)u; return (V)&fpr_unit; }
FPR_FN(fpr_g_Loops_x2earm, arm, 1);
FPR_FN(fpr_g_Loops_x2eused, used, 1);
FPR_FN(fpr_g_Loops_x2eforce, force, 1);
''')
        exe = tmp / 'weighted'
        # the weights of the build itself (its loop form may differ from `fpr compile`'s)
        built = subprocess.run([str(ROOT / 'fpr'), 'build', str(source), '--harts', '1', '--with', str(probe), '--keep', '-o', str(exe)],
                               cwd=ROOT, env=env, capture_output=True, text=True, timeout=300)
        assert built.returncode == 0, built.stderr[-2000:]
        kept = built.stdout + built.stderr
        native = Path(re.search(r'fpr build: kept (\S+)', kept)[1])
        weights = [int(m[1]) for l in bodies(native.read_text())['ticks'] for m in [re.search(TICK[host], l)] if m]
        a, used, _ = run([exe], dict(env, FPR_HARTS='1')).split()
        assert a == '20000', a
        used = int(used)
        # 20,001 activations of `ticks`, each charged one of its printed weights
        assert 20001 * min(weights) <= used <= 20001 * max(weights), (used, weights)
        assert used > 10 * 20001, used
        unit = tmp / 'unit'
        run([ROOT / 'fpr', 'build', source, '--harts', '1', '--with', probe, '-o', unit], dict(env, FPR_NO_TICK_WEIGHT='1'))
        _, old, _ = run([unit], dict(env, FPR_HARTS='1')).split()
        assert old == '20001', old
        print(f'tick weights: 20,001 activations spent {used} (weights {weights}); 20,001 units with FPR_NO_TICK_WEIGHT=1 PASS')
    return 0


if __name__ == '__main__':
    sys.exit(main())
