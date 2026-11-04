#!/usr/bin/env python3
"""Abstraction equivalence: one computation, four spellings, default build.

Each family writes the same computation as a direct pipeline, a let-bound
pipeline, a helper-wrapped pipeline and an explicit loop
(docs/2026-11-03-DEFAULT-BUILD-GATES.md). For every spelling it records:

  output         stdout of the default build (GATED: all four must agree
                 with each other and with the expected text);
  allocation     allocator requests from an FPR_COST_PROBE build
                 (FPR_COST_REPORT) at ALLOC_N elements (GATED only where the
                 expectation is firm, see EXPECT; other spellings are
                 reported);
  .text size     the __text section of the default executable (reported);
  compile cost   the compiler's own allocation (`fpr compile +RTS -t`, as
                 tests/check_compile_budget.py) for a cold compile (fresh
                 cache, std units included) and a warm one (same cache), and
                 `fpr build` wall time cold and warm (reported);
  runtime        paired samples of the uninstrumented default executable at
                 TIME_N elements, interleaved across the four spellings in a
                 rotating order, median reported (not gated).

Compiler allocation is deterministic for one binary; the rest is reported
because runners differ. --record PATH writes every raw sample with the
revision, target and flags (bench/2026-11-03-default-build-gates.json).
--samples (default 5) sets the timing sample count; --quick skips timing.
"""
import argparse, ast, hashlib, json, os, platform, re, statistics, subprocess, sys, tempfile, time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FPR = ROOT / 'fpr'
ALLOC_N = 1000
TIME_N = 1_000_000
SPELLINGS = ('direct', 'let', 'helper', 'loop')
HEAD = 'List = use "std/list".\n'


def families(n):
    h = n // 2
    return {
        # filter -> map -> sum: B1 fusion of a three-stage pipeline
        'sum-map-filter': (f'{sum(3 * x for x in range(1, h + 1))}\n', {
            'direct': HEAD + f'main = print (List.sum (List.map (fn x -> x * 3) (List.filter (fn x -> x <= {h}) (List.range 1 {n})))).\n',
            'let': HEAD + f'main =\n  xs = List.range 1 {n};\n  ys = List.filter (fn x -> x <= {h}) xs;\n'
                          f'  zs = List.map (fn x -> x * 3) ys;\n  print (List.sum zs).\n',
            'helper': HEAD + f'small : List Int -> List Int .\nsmall xs = List.filter (fn x -> x <= {h}) xs.\n'
                             'triple : List Int -> List Int .\ntriple xs = List.map (fn x -> x * 3) xs.\n'
                             f'main = print (List.sum (triple (small (List.range 1 {n})))).\n',
            'loop': f'go : unsafe Int -> Int -> Int -> Int .\n'
                    f'go i n acc = if i > n then acc else go (i + 1) n (if i <= {h} then acc + i * 3 else acc).\n'
                    f'main = print (go 1 {n} 0).\n',
        }),
        # count of a filter: length consumer
        'count-filter': (f'{n - h}\n', {
            'direct': HEAD + f'main = print (List.length (List.filter (fn x -> x > {h}) (List.range 1 {n}))).\n',
            'let': HEAD + f'main =\n  xs = List.range 1 {n};\n  big = List.filter (fn x -> x > {h}) xs;\n  print (List.length big).\n',
            'helper': HEAD + f'big : List Int -> List Int .\nbig xs = List.filter (fn x -> x > {h}) xs.\n'
                             f'main = print (List.length (big (List.range 1 {n}))).\n',
            'loop': f'go : unsafe Int -> Int -> Int -> Int .\n'
                    f'go i n c = if i > n then c else go (i + 1) n (if i > {h} then c + 1 else c).\n'
                    f'main = print (go 1 {n} 0).\n',
        }),
        # sum and count together: tuple accumulator (A2) vs pair-returning loop
        'sum-count-pair': (f'{sum(range(1, h + 1))} {h}\n', {
            'direct': HEAD + f'main = case List.fold (fn p x -> case p of (s, c) -> (s + x, c + 1)) (0, 0) '
                             f'(List.filter (fn x -> x <= {h}) (List.range 1 {n})) of (s, c) -> print "{{s}} {{c}}".\n',
            'let': HEAD + f'main =\n  xs = List.filter (fn x -> x <= {h}) (List.range 1 {n});\n'
                          '  p = List.fold (fn p x -> case p of (s, c) -> (s + x, c + 1)) (0, 0) xs;\n'
                          '  case p of (s, c) -> print "{s} {c}".\n',
            'helper': HEAD + 'step : (Int, Int) -> Int -> (Int, Int) .\nstep p x = case p of (s, c) -> (s + x, c + 1).\n'
                             f'stats : Int -> (Int, Int) .\nstats n = List.fold step (0, 0) (List.filter (fn x -> x <= {h}) (List.range 1 n)).\n'
                             f'main = case stats {n} of (s, c) -> print "{{s}} {{c}}".\n',
            'loop': 'go : unsafe Int -> Int -> Int -> Int -> (Int, Int) .\n'
                    f'go i n s c = if i > n then (s, c) else if i <= {h} then go (i + 1) n (s + i) (c + 1) else go (i + 1) n s c.\n'
                    f'main = case go 1 {n} 0 0 of (s, c) -> print "{{s}} {{c}}".\n',
        }),
        # a materialized result used twice (typed TRMC; fusion cannot remove it)
        'materialize': (f'({sum(2 * x for x in range(1, h + 1))}, {h})\n', {
            'direct': HEAD + f'main = print ((fn ys -> (List.sum ys, List.length ys)) (List.map (fn x -> x * 2) (List.filter (fn x -> x <= {h}) (List.range 1 {n})))).\n',
            'let': HEAD + f'main =\n  ys = List.map (fn x -> x * 2) (List.filter (fn x -> x <= {h}) (List.range 1 {n}));\n'
                          '  print (List.sum ys, List.length ys).\n',
            'helper': HEAD + f'doubled : Int -> List Int .\ndoubled n = List.map (fn x -> x * 2) (List.filter (fn x -> x <= {h}) (List.range 1 n)).\n'
                             f'main =\n  ys = doubled {n};\n  print (List.sum ys, List.length ys).\n',
            'loop': HEAD + 'go : unsafe Int -> Int -> List Int -> List Int .\n'
                           f'go i n acc = if i > n then List.reverse acc else go (i + 1) n (if i <= {h} then i * 2 :: acc else acc).\n'
                           f'main =\n  ys = go 1 {n} Nil;\n  print (List.sum ys, List.length ys).\n',
        }),
    }


# Firm default-build allocation expectations at ALLOC_N (exact request counts).
# A spelling not listed is reported, not gated. Recorded 2026-11-03.
#  - fused direct/let-bound pipelines and the scalar loops allocate nothing
#    (the same gates as tests/check_list_fusion.py);
#  - sum-count-pair's loop: 4 requests for "{s} {c}" plus the one final pair;
#  - materialize: map after filter over a range is the producer composition
#    tests/check_list_fusion.py pins at 1501; the loop conses 500 then reverses.
# Known gaps, reported and not gated (docs/2026-11-03-DEFAULT-BUILD-GATES.md):
# Helper-wrapped scalar pipelines now share the zero-allocation gate.
# Tuple folds now share the scalar loop's boundary-only allocation gate.
EXPECT = {
    ('sum-map-filter', 'helper'): 0, ('sum-map-filter', 'direct'): 0, ('sum-map-filter', 'let'): 0, ('sum-map-filter', 'loop'): 0,
    ('count-filter', 'helper'): 0, ('count-filter', 'direct'): 0, ('count-filter', 'let'): 0, ('count-filter', 'loop'): 0,
    ('sum-count-pair', 'direct'): 5, ('sum-count-pair', 'let'): 5,
    ('sum-count-pair', 'helper'): 5, ('sum-count-pair', 'loop'): 5,
    ('materialize', 'direct'): 1501, ('materialize', 'let'): 1501, ('materialize', 'loop'): 1001,
}


def run(args, env, timeout=300):
    return subprocess.run(list(map(str, args)), cwd=ROOT, env=env, text=True, capture_output=True, timeout=timeout)


def text_size(exe):
    out = subprocess.run(['otool', '-l', str(exe)], capture_output=True, text=True).stdout if sys.platform == 'darwin' else ''
    if out:
        m = re.search(r'sectname __text\n\s+segname __TEXT\n\s+addr \S+\n\s+size (0x[0-9a-f]+)', out)
        return int(m.group(1), 16) if m else None
    out = subprocess.run(['size', '-A', str(exe)], capture_output=True, text=True).stdout
    m = re.search(r'^\.text\s+(\d+)', out, re.M)
    return int(m.group(1)) if m else None


def build(src, exe, env):
    """`fpr build` wall time (it compiles in child processes, so no RTS stats)."""
    start = time.perf_counter()
    p = run([FPR, 'build', src, '--harts', '1', '-o', exe], env)
    wall = time.perf_counter() - start
    assert p.returncode == 0, (src.name, p.stdout[-2000:], p.stderr[-4000:])
    return round(wall, 3)


def compile_cost(src, out, env, stats):
    """The compiler's own allocation, as tests/check_compile_budget.py measures it."""
    start = time.perf_counter()
    p = run([FPR, 'compile', '--system=posix', src, out, '+RTS', f'-t{stats}', '--machine-readable', '-RTS'], env)
    wall = time.perf_counter() - start
    assert p.returncode == 0, (src.name, p.stdout[-2000:], p.stderr[-4000:])
    rts = dict(ast.literal_eval(Path(stats).read_text().split('\n', 1)[1]))
    return {'compiler_allocated_bytes': int(rts['bytes allocated']), 'max_bytes_used': int(rts['max_bytes_used']),
            'compile_wall_seconds': round(wall, 3)}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--record', type=Path)
    ap.add_argument('--samples', type=int, default=5)
    ap.add_argument('--quick', action='store_true')
    args = ap.parse_args()
    started = time.time()
    revision = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    dirty = bool(subprocess.run(['git', 'status', '--porcelain'], cwd=ROOT, capture_output=True, text=True).stdout.strip())
    digest = hashlib.sha256(FPR.read_bytes()).hexdigest()
    failures = []
    rows = {}
    with tempfile.TemporaryDirectory(prefix='fpr-abstraction-') as d:
        tmp = Path(d)
        base = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
        base.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), FPR_HARTS='1')
        base.pop('GHCRTS', None)
        alloc_fams = families(ALLOC_N)
        time_fams = families(TIME_N)
        tasks = []
        for fam, (_, spells) in alloc_fams.items():
            for sp in SPELLINGS:
                rows[(fam, sp)] = {'family': fam, 'spelling': sp}
                tasks.append((fam, sp))

        def prepare(task):
            fam, sp = task
            row = rows[task]; tag = f'{fam}-{sp}'
            # allocation probe (instrumented build, ALLOC_N)
            src = tmp / f'{tag}-alloc.fpr'; src.write_text(alloc_fams[fam][1][sp])
            env = dict(base, XDG_CACHE_HOME=str(tmp / f'cache-probe-{tag}'), FPR_COST_PROBE='1')
            exe = tmp / f'{tag}-probe'
            build(src, exe, env)
            r = run([exe], dict(env, FPR_COST_REPORT='1'), 120)
            m = re.search(r'\[fpr cost\] (\{.*\})', r.stderr)
            row['alloc_stdout'] = r.stdout; row['alloc_rc'] = r.returncode
            row['ledger'] = json.loads(m.group(1)) if m else None
            # default build at TIME_N: cold (fresh cache), then warm (same cache)
            src = tmp / f'{tag}.fpr'; src.write_text(time_fams[fam][1][sp])
            row['source'] = time_fams[fam][1][sp]
            env = dict(base, XDG_CACHE_HOME=str(tmp / f'cache-{tag}'))
            exe = tmp / tag
            # compile cost: cold (fresh cache, std units included), then warm
            # (`fpr compile` caches units in <output dir>/units: one directory per program)
            cdir = tmp / f'cc-{tag}'; cdir.mkdir()
            cenv = dict(env, XDG_CACHE_HOME=str(cdir / 'cache'))
            row['compile_cold'] = compile_cost(src, cdir / f'{tag}.s', cenv, tmp / f'{tag}-cold.rts')
            row['compile_warm'] = compile_cost(src, cdir / f'{tag}.s', cenv, tmp / f'{tag}-warm.rts')
            row['build_cold_seconds'] = build(src, exe, env)
            row['build_warm_seconds'] = build(src, exe, env)
            row['text_bytes'] = text_size(exe); row['executable_bytes'] = exe.stat().st_size
            r = run([exe], env, 120)
            row['stdout'] = r.stdout; row['rc'] = r.returncode; row['stderr'] = r.stderr
            row['_exe'] = str(exe); row['_env'] = env
            return task

        with ThreadPoolExecutor(int(os.environ.get('ABSEQ_JOBS', '4'))) as ex:
            list(ex.map(prepare, tasks))

        # Gates: identical output and firm allocation expectations.
        for fam, (expected_alloc_out, _) in alloc_fams.items():
            expected_time_out = time_fams[fam][0]
            for sp in SPELLINGS:
                row = rows[(fam, sp)]
                if (row['alloc_rc'], row['alloc_stdout']) != (0, expected_alloc_out) or row['ledger'] is None:
                    failures.append(f'{fam}/{sp}: probe build printed {row["alloc_stdout"]!r} (exit {row["alloc_rc"]}), want {expected_alloc_out!r}')
                if (row['rc'], row['stdout'], row['stderr']) != (0, expected_time_out, ''):
                    failures.append(f'{fam}/{sp}: default build printed {row["stdout"]!r} (exit {row["rc"]}, stderr {row["stderr"][-300:]!r}), want {expected_time_out!r}')
                want = EXPECT.get((fam, sp))
                got = row['ledger'] and row['ledger']['alloc_requests']
                row['alloc_expected'] = want
                if want is not None and got != want:
                    failures.append(f'{fam}/{sp}: {got} allocation requests at {ALLOC_N}, expected {want}')

        # Paired runtime samples: every round runs each spelling of a family
        # once, in an order rotated each round; one warmup run first.
        if not args.quick:
            for fam in alloc_fams:
                for sp in SPELLINGS: rows[(fam, sp)]['seconds'] = []
                for rnd in range(args.samples + 1):
                    order = SPELLINGS[rnd % 4:] + SPELLINGS[:rnd % 4]
                    for sp in order:
                        row = rows[(fam, sp)]
                        t = time.perf_counter()
                        r = subprocess.run([row['_exe']], env=row['_env'], capture_output=True, text=True, timeout=120)
                        dt = time.perf_counter() - t
                        assert r.returncode == 0 and r.stdout == time_fams[fam][0], (fam, sp, r)
                        if rnd: row['seconds'].append(round(dt, 6))
                for sp in SPELLINGS:
                    row = rows[(fam, sp)]; row['median_seconds'] = statistics.median(row['seconds'])
                for sp in SPELLINGS:
                    rows[(fam, sp)]['median_vs_loop'] = round(rows[(fam, sp)]['median_seconds'] / rows[(fam, 'loop')]['median_seconds'], 3)
    assert hashlib.sha256(FPR.read_bytes()).hexdigest() == digest, 'compiler changed during measurement'

    # Report
    print(f'{"family":16} {"spelling":8} {"alloc@" + str(ALLOC_N):>10} {"gate":>6} {"vs loop":>8} {".text":>8} '
          f'{"cc-cold MB":>10} {"cc-warm MB":>10} {"build-cold s":>12} {"build-warm s":>12} {"median ms":>9}')
    for (fam, sp), row in rows.items():
        req = row['ledger']['alloc_requests'] if row['ledger'] else None
        gate = '-' if row.get('alloc_expected') is None else ('ok' if req == row['alloc_expected'] else 'FAIL')
        med = f'{row["median_seconds"] * 1000:9.2f}' if 'median_seconds' in row else '        -'
        loop = rows[(fam, 'loop')]['ledger']
        row['alloc_minus_loop'] = gap = req - loop['alloc_requests'] if req is not None and loop else None
        print(f'{fam:16} {sp:8} {str(req):>10} {gate:>6} {("+" + str(gap)) if gap else "0":>8} {str(row["text_bytes"]):>8} '
              f'{row["compile_cold"]["compiler_allocated_bytes"] / 1e6:10.1f} {row["compile_warm"]["compiler_allocated_bytes"] / 1e6:10.1f} '
              f'{row["build_cold_seconds"]:12.2f} {row["build_warm_seconds"]:12.2f} {med}', flush=True)
    for row in rows.values():
        row.pop('_exe', None); row.pop('_env', None)
    if args.record:
        out = {'revision': revision, 'dirty': dirty, 'compiler_sha256': digest,
               'host': platform.platform(), 'machine': platform.machine(),
               'target': 'hosted ' + platform.machine() + ' ' + sys.platform + ' (fpr build default target)',
               'flags': {'default': 'no FPR_* variables except FPR_HARTS=1',
                         'allocation probe': 'FPR_COST_PROBE=1 build, FPR_COST_REPORT=1 run'},
               'alloc_elements': ALLOC_N, 'time_elements': TIME_N, 'samples': None if args.quick else args.samples,
               'measurement': 'wall time per process including startup; rounds run every spelling of a family once '
                              'in a rotated order; one warmup round discarded. Compile cold = fresh XDG cache; '
                              'warm = identical rebuild in the same cache. Compiler allocation is GHC +RTS -t.',
               'results': list(rows.values())}
        args.record.parent.mkdir(parents=True, exist_ok=True)
        args.record.write_text(json.dumps(out, indent=1) + '\n')
        print(f'recorded {args.record}')
    if failures:
        print('abstraction equivalence FAILED:\n  ' + '\n  '.join(failures))
        sys.exit(1)
    print(f'abstraction equivalence: {len(alloc_fams)} families x {len(SPELLINGS)} spellings, output identical, '
          f'{len(EXPECT)} allocation gates PASS ({time.time() - started:.0f} s)')


if __name__ == '__main__':
    main()
