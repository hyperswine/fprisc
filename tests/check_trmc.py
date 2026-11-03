#!/usr/bin/env python3
"""B2 TRMC (Tail Recursion Modulo Cons): differential behavior, allocations, multi-target codegen, and rollback."""
from pathlib import Path
import json, os, re, subprocess, tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(args, env, timeout=180):
    return subprocess.run(list(map(str, args)), cwd=ROOT, env=env, text=True,
                          capture_output=True, timeout=timeout)


def main():
    with tempfile.TemporaryDirectory(prefix='fpr-trmc-') as directory:
        tmp = Path(directory)
        base = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
        base.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), FPR_HARTS='1',
                    XDG_CACHE_HOME=str(tmp / 'cache'))

        def source(name, text):
            path = tmp / (name + '.fpr')
            path.write_text(text)
            return path

        def build(path, name, disabled=False, probe=False, extra_env=None):
            env = dict(base)
            if disabled:
                env['FPR_NO_TRMC'] = '1'
            if probe:
                env.update(FPR_COST_PROBE='1', FPR_NO_LOOP_REGIONS='1',
                           FPR_NO_CALL_REGIONS='1', FPR_NO_LIST_FUSE='1')
            if extra_env:
                env.update(extra_env)
            exe = tmp / name
            made = run([ROOT / 'fpr', 'build', path, '--harts', '1', '-o', exe], env)
            assert made.returncode == 0, (name, made.stdout[-2000:], made.stderr[-6000:])
            return exe, env, made.stdout + made.stderr

        def execute(exe, env, report=False):
            return run([exe], dict(env, FPR_COST_REPORT='1') if report else env, timeout=60)

        # 1. Differential equivalence across std/list and custom accumulator-reverse
        # functions (including empty inputs, singleton inputs, duplicate elements,
        # non-Nil initial accumulators, merge/sortWith, append/concat, and traps).
        diff_prog = source('differential', '''List = use "std/list".
O = use "std/option".
Ord = use "std/order".

customMapGo : (Int -> Int) -> (xs : List Int | measure xs) -> List Int -> List Int .
customMapGo f xs acc = case xs of
    Nil -> List.reverse acc
  | x :: r -> customMapGo f r (f x :: acc).

 parsePos : Int -> O.Option Int .
parsePos x = case x > 0 of True -> O.Some (x * 10) | False -> O.None.

main =
  xs = [3, -1, 4, 1, -5, 9, 2, 6, 5, 3];
  empty = [];
  single = [42];
  dups = [5, 5, 5, 5];
  m1 = List.map (fn x -> x + 1) xs;
  mEmpty = List.map (fn x -> x + 1) empty;
  mSingle = List.map (fn x -> x + 1) single;
  mDups = List.map (fn x -> x + 0) dups;
  f1 = List.filter (fn x -> x > 2) xs;
  fNone = List.filter (fn x -> x > 100) xs;
  im = List.indexed xs;
  fm = List.filterMap parsePos xs;
  tk = List.take 4 xs;
  tk0 = List.take 0 xs;
  tw = List.takeWhile (fn x -> x > -3) xs;
  zw = List.zipWith (fn a b -> a + b) xs (List.reverse xs);
  ap1 = List.append [1, 2, 3] [4, 5];
  apEmptyL = List.append empty [4, 5];
  apEmptyR = List.append [1, 2] empty;
  cc = List.concat [[1, 2], [], [3], [4, 5]];
  sorted = List.sortWith Ord.int xs;
  nonNilAcc = customMapGo (fn x -> x * 2) [1, 2, 3] [99, 88];
  print (m1, mEmpty, mSingle, mDups, f1, fNone, im, fm, tk, tk0, tw, zw, ap1, apEmptyL, apEmptyR, cc, sorted, nonNilAcc).
''')
        expected_out = (
            '([4, 0, 5, 2, -4, 10, 3, 7, 6, 4], [], [43], [5, 5, 5, 5], '
            '[3, 4, 9, 6, 5, 3], [], '
            '[(0, 3), (1, -1), (2, 4), (3, 1), (4, -5), (5, 9), (6, 2), (7, 6), (8, 5), (9, 3)], '
            '[30, 40, 10, 90, 20, 60, 50, 30], '
            '[3, -1, 4, 1], [], [3, -1, 4, 1], '
            '[6, 4, 10, 3, 4, 4, 3, 10, 4, 6], '
            '[1, 2, 3, 4, 5], [4, 5], [1, 2], [1, 2, 3, 4, 5], '
            '[-5, -1, 1, 2, 3, 3, 4, 5, 6, 9], '
            '[88, 99, 2, 4, 6])\n'
        )
        for disabled in (False, True):
            exe, env, _ = build(diff_prog, f'diff-{disabled}', disabled=disabled)
            obs = execute(exe, env)
            assert obs.returncode == 0 and obs.stdout == expected_out and not obs.stderr, (
                disabled, obs.returncode, obs.stdout, obs.stderr)
        print('TRMC differential equivalence: map, filter, indexed, filterMap, take, takeWhile, zipWith, append, concat, sortWith, and non-Nil accumulator PASS', flush=True)

        # 2. Trap preservation: an element callback that overflows or divides by
        # zero traps on the exact same element in both TRMC and rollback modes.
        trap_prog = source('trap', '''List = use "std/list".
main =
  xs = List.map (fn x -> 100 / x) [5, 2, 0, 1];
  print xs.
''')
        trap_seen = []
        for disabled in (False, True):
            exe, env, _ = build(trap_prog, f'trap-{disabled}', disabled=disabled)
            obs = execute(exe, env)
            assert obs.returncode != 0 and 'division by zero' in (obs.stdout + obs.stderr), (
                disabled, obs.returncode, obs.stdout, obs.stderr)
            trap_seen.append((obs.returncode, obs.stdout, obs.stderr))
        assert trap_seen[0] == trap_seen[1], trap_seen
        print('TRMC trap preservation: callback trap order and diagnostic match rollback PASS', flush=True)

        # 3. Allocation reduction ratchets (with list fusion off so the list
        # allocations themselves are measured): TRMC cuts each reverse pass out,
        # saving 1 Cons cell per output element. The `FPR_NO_SPEC` pair isolates
        # the transform: the typed specializer inlines the pre-TRMC body of a
        # called loop into its caller, so on the default profile a callback-
        # carrying List.map/filter keeps its inlined reverse pass (see B2's
        # record, "Placement"); `append` is not inlined and always improves.
        alloc_cases = {
            'map-1000': (
                'main = print (List.length (List.map (fn x -> x + 1) (List.range 1 1000))).\n',
                '1000\n', 2000, 3000),
            'filter-1000': (
                'main = print (List.length (List.filter (fn x -> x <= 500) (List.range 1 1000))).\n',
                '500\n', 1500, 2000),
            'append-1000': (
                'main =\n  xs = List.range 1 1000;\n  ys = List.range 1 500;\n  print (List.length (List.append xs ys)).\n',
                '1500\n', 2500, 3500),
        }
        for name, (body, wanted_out, trmc_allocs, no_trmc_allocs) in alloc_cases.items():
            path = source(name, 'List = use "std/list".\n' + body)
            counts = {}
            for disabled, extra in ((False, {}), (True, {}),
                                    (False, {'FPR_NO_SPEC': '1'}), (True, {'FPR_NO_SPEC': '1'})):
                tag = f'{name}-{disabled}-{"nospec" if extra else "spec"}'
                exe, env, _ = build(path, tag, disabled=disabled, probe=True, extra_env=extra)
                obs = execute(exe, env, report=True)
                assert obs.returncode == 0 and obs.stdout == wanted_out, (
                    name, tag, obs.stdout, obs.stderr)
                match = re.search(r'\[fpr cost\] (\{.*\})', obs.stderr)
                assert match, (name, tag, obs.stderr)
                counts[(disabled, bool(extra))] = json.loads(match.group(1))['alloc_requests']
            # rollback is the unchanged baseline in both configurations
            assert counts[(True, False)] == no_trmc_allocs and counts[(True, True)] == no_trmc_allocs, (
                name, counts, no_trmc_allocs)
            # no configuration may regress against the rollback
            for key, value in counts.items():
                assert value <= no_trmc_allocs, (name, key, counts)
            # the transform itself must save the reverse pass
            assert counts[(False, True)] == trmc_allocs, (name, 'no-specialization', counts, trmc_allocs)
            print(f'TRMC allocation: {name} trmc={counts[(False, False)]} no_trmc={counts[(True, False)]} '
                  f'(no-specialization trmc={counts[(False, True)]}) PASS', flush=True)

        # 4. Multi-target assembly emission (AArch64, x86-64, RV64): verify
        # `$worker.trmc.` and `OSetField` lower cleanly on all 64-bit targets.
        for target in ('a64mac', 'x64', 'rv64'):
            asm = tmp / f'trmc-{target}.s'
            res = run([ROOT / 'fpr', 'compile', '--system=posix', f'--target={target}', diff_prog, asm], base)
            assert res.returncode == 0 and asm.exists(), (target, res.stdout, res.stderr)
        print('TRMC multi-target native compilation (a64mac, x64, rv64) PASS', flush=True)


if __name__ == '__main__':
    main()
