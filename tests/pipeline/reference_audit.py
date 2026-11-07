#!/usr/bin/env python3
"""P0 audit of the C and GHC reference programs
(docs/2026-11-08-PIPELINE-REFERENCE-AUDIT.md).

The performance records compare FP-RISC against tests/bench/c/*.c (tools/bench.py,
`cc -O2`) and tests/bench/unbox/ref.c + ref.hs (tests/bench/unbox/measure.py,
`gcc -O2`, `ghc -O2`).  Before any of those ratios becomes an acceptance target
this checks, for every reference:

  same answer   the reference prints the same number as the FP-RISC program
                (a reference that computes something else is not a reference)
  vectorized    C built as the harness builds it, and again with the loop and
                SLP vectorizers off; a clearly faster default build means the
                ratio compares FP-RISC's scalar loop against SIMD
  checked       C built with -ftrapv, so signed overflow traps as FP-RISC's Int
                does; the ratio against this build is the checked comparison
  optimized out a reference whose work time is near zero measured nothing
  fused / boxed GHC's heap allocation: no per-element allocation means GHC
                fused the list away, so it is a fused-loop reference, not a
                list reference

Every executable runs interleaved RUNS times (default 5); medians are wall time
minus the median of an empty run of the same kind (process startup).

  tests/pipeline/reference_audit.py            print the table
  tests/pipeline/reference_audit.py --record   also write bench/pipeline-reference-audit.json
"""
import argparse, json, os, platform, re, shutil, statistics, subprocess, sys, tempfile, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UNBOX = ROOT / 'tests/bench/unbox'
BENCH = ROOT / 'tests/bench'
OUT = ROOT / 'bench/pipeline-reference-audit.json'

# name: FP-RISC source, [(C source, args)], GHC mode or None, elements per run
# (for the GHC per-element allocation test; None when it is not a list workload)
CASES = {
    'fib':             (BENCH / 'fib.fpr',               [('c/fib.c', [])], None, None),
    'byteloop':        (BENCH / 'byteloop.fpr',          [('c/byteloop.c', [])], None, None),
    'sha':             (BENCH / 'sha.fpr',               [('c/sha.c', [])], None, None),
    'list_sum':        (UNBOX / 'list_sum.fpr',          [('ref.c', ['cons_sum', '1000000', '20']),
                                                          ('ref.c', ['arr_sum', '1000000', '20'])], 'sum', 20_000_000),
    'list_map':        (UNBOX / 'list_map.fpr',          [('ref.c', ['cons_map', '1000000', '20'])], 'map', 20_000_000),
    'list_filter':     (UNBOX / 'list_filter.fpr',       [('ref.c', ['cons_filter', '1000000', '20'])], 'filter', 20_000_000),
    'list_fold':       (UNBOX / 'list_fold.fpr',         [('ref.c', ['cons_fold', '1000000', '20'])], 'fold', 20_000_000),
    'list_length_rev': (UNBOX / 'list_length_rev.fpr',   [('ref.c', ['cons_rev', '1000000', '20'])], 'rev', 20_000_000),
    'option_loop':     (UNBOX / 'option_loop.fpr',       [('ref.c', ['option', '20000000', '1'])], 'option', 20_000_000),
    'tuple_loop':      (UNBOX / 'tuple_loop.fpr',        [('ref.c', ['tuple', '20000000', '1'])], 'tuple', 20_000_000),
    'tree_sum':        (UNBOX / 'tree_sum.fpr',          [('ref.c', ['tree', '20', '10'])], 'tree', 10 * (2 ** 20 - 1)),
    'string_scan':     (UNBOX / 'string_scan.fpr',       [('ref.c', ['scan', '1048576', '20'])], None, None),
}
C_VARIANTS = {
    'O2': ['-O2'],                                              # what tools/bench.py and measure.py build
    'scalar': ['-O2', '-fno-vectorize', '-fno-slp-vectorize'],  # vectorizers off
    'checked': ['-O2', '-ftrapv'],                              # signed overflow traps, as FP-RISC Int
}
EMPTY_C = 'int main(void){return 0;}\n'


def run(cmd, env=None, timeout=900, check=True):
    p = subprocess.run([str(c) for c in cmd], cwd=ROOT, env=env, text=True, capture_output=True, timeout=timeout)
    if check and p.returncode != 0:
        sys.exit(f'failed: {" ".join(map(str, cmd))}\n{p.stdout[-2000:]}{p.stderr[-2000:]}')
    return p


def answer(text):
    """The value a program printed: its last hex digest or integer."""
    hexes = re.findall(r'\b[0-9a-f]{64}\b', text)
    if hexes:
        return hexes[-1]
    nums = re.findall(r'-?\d+', text)
    return nums[-1] if nums else None


def tool_version(cmd):
    try:
        return run(cmd, check=False).stdout.splitlines()[0].strip()
    except Exception:
        return None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--runs', type=int, default=5)
    ap.add_argument('--record', action='store_true', help=f'write {OUT.relative_to(ROOT)}')
    ap.add_argument('names', nargs='*')
    a = ap.parse_args()
    cases = {k: v for k, v in CASES.items() if not a.names or k in a.names}
    cc = os.environ.get('CC', 'cc')
    ghc = shutil.which('ghc') or next((str(p) for p in [Path.home() / '.ghcup/bin/ghc'] if p.exists()), None)

    with tempfile.TemporaryDirectory(prefix='fpr-refaudit-') as d:
        tmp = Path(d)
        env = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
        env.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), FPR_HARTS='1', XDG_CACHE_HOME=str(tmp / 'cache'))
        jobs, rows = {}, {}

        (tmp / 'empty.c').write_text(EMPTY_C)
        run([cc, '-O2', '-o', tmp / 'empty_c', tmp / 'empty.c'])
        jobs['empty:c'] = [tmp / 'empty_c']
        (tmp / 'empty.fpr').write_text('main = print "empty".\n')
        run([ROOT / 'fpr', 'build', tmp / 'empty.fpr', '--harts', '1', '-o', tmp / 'empty_fpr'], env)
        jobs['empty:fpr'] = [tmp / 'empty_fpr']

        built = {}
        for src in sorted({s for v in cases.values() for s, _ in v[1]}):
            path = (BENCH / src) if src.startswith('c/') else (UNBOX / src)
            for variant, flags in C_VARIANTS.items():
                exe = tmp / f'{Path(src).stem}.{variant}'
                run([cc, *flags, '-o', exe, path])
                built[(src, variant)] = exe
        if ghc:
            run([ghc, '-O2', '-rtsopts', UNBOX / 'ref.hs', '-outputdir', tmp / 'hs', '-o', tmp / 'ref_hs'])
            (tmp / 'empty.hs').write_text('main :: IO ()\nmain = return ()\n')
            run([ghc, '-O2', '-rtsopts', tmp / 'empty.hs', '-outputdir', tmp / 'hse', '-o', tmp / 'empty_hs'])
            jobs['empty:hs'] = [tmp / 'empty_hs']

        for name, (src, crefs, hs, elements) in cases.items():
            exe = tmp / f'{name}.fpr.exe'
            run([ROOT / 'fpr', 'build', src, '--harts', '1', '-o', exe], env)
            jobs[f'{name}:fpr'] = [exe]
            want = answer(run([exe], env).stdout)
            row = {'fpr_source': str(src.relative_to(ROOT)), 'answer': want, 'c': {}, 'problems': []}
            for csrc, args in crefs:
                label = args[0] if args else Path(csrc).stem
                row['c'][label] = {'source': f'tests/bench/{csrc}' if csrc.startswith('c/') else f'tests/bench/unbox/{csrc}',
                                   'args': args}
                for variant in C_VARIANTS:
                    p = run([built[(csrc, variant)], *args], check=False)
                    got = answer(p.stdout)
                    row['c'][label].setdefault('answers', {})[variant] = got
                    if p.returncode != 0:
                        row['problems'].append(f'C {label} {variant} exited {p.returncode}')
                    elif got != want:
                        row['problems'].append(f'C {label} {variant} printed {got}, FP-RISC {want}')
                    jobs[f'{name}:c:{label}:{variant}'] = [built[(csrc, variant)], *args]
            if hs and ghc:
                p = run([tmp / 'ref_hs', hs, '+RTS', '-s', '-RTS'], check=False)
                got = answer(p.stdout)
                alloc = re.search(r'([\d,]+) bytes allocated in the heap', p.stderr)
                alloc = int(alloc.group(1).replace(',', '')) if alloc else None
                row['ghc'] = {'mode': hs, 'answer': got, 'alloc_bytes': alloc,
                              'alloc_bytes_per_element': round(alloc / elements, 2) if alloc and elements else None}
                if got != want:
                    row['problems'].append(f'GHC {hs} printed {got}, FP-RISC {want}')
                jobs[f'{name}:hs'] = [tmp / 'ref_hs', hs]
            rows[name] = row

        samples = {k: [] for k in jobs}
        for _ in range(a.runs):
            for k, cmd in jobs.items():
                t0 = time.perf_counter()
                run(cmd, env, check=False)
                samples[k].append(time.perf_counter() - t0)
        med = {k: statistics.median(v) for k, v in samples.items()}

        def work(key, kind):
            return max(med[key] - med[f'empty:{kind}'], 0.0)

        for name, row in rows.items():
            fw = work(f'{name}:fpr', 'fpr')
            row['fpr_work_ms'] = round(fw * 1000, 2)
            for label, c in row['c'].items():
                t = {v: work(f'{name}:c:{label}:{v}', 'c') for v in C_VARIANTS}
                c['work_ms'] = {v: round(x * 1000, 2) for v, x in t.items()}
                c['fpr_over_c'] = {v: (round(fw / x, 2) if x > 0.0005 else None) for v, x in t.items()}
                c['vectorized'] = t['O2'] < 0.8 * t['scalar']
                c['checked_cost'] = round(t['checked'] / t['O2'], 2) if t['O2'] > 0.0005 else None
                c['optimized_out'] = t['O2'] < 0.0005
            if 'ghc' in row and f'{name}:hs' in med:
                g = row['ghc']
                g['work_ms'] = round(work(f'{name}:hs', 'hs') * 1000, 2)
                g['fpr_over_ghc'] = round(fw / (g['work_ms'] / 1000), 2) if g['work_ms'] > 0.5 else None
                per = g['alloc_bytes_per_element']
                g['fused'] = per is not None and per < 1.0

    result = {
        'schema': 1,
        'host': f'{platform.system()}-{platform.machine()}-{platform.node().split(".")[0]}',
        'recorded_at': time.strftime('%Y-%m-%dT%H:%M:%S%z'),
        'git_commit': run(['git', 'rev-parse', 'HEAD']).stdout.strip(),
        'runs': a.runs,
        'cc': tool_version([cc, '--version']),
        'ghc': tool_version([ghc, '--version']) if ghc else None,
        'empty_ms': {k.split(':')[1]: round(v * 1000, 2) for k, v in med.items() if k.startswith('empty:')},
        'cases': rows,
    }

    print(f'{"case":16} {"ref":12} {"fpr ms":>8} {"C O2":>8} {"scalar":>8} {"checked":>8} '
          f'{"fpr/C":>6} {"fpr/Cchk":>8}  flags')
    bad = 0
    for name, row in rows.items():
        for label, c in row['c'].items():
            w, r = c['work_ms'], c['fpr_over_c']
            flags = [f for f, on in [('SIMD', c['vectorized']), ('OPTIMIZED-OUT', c['optimized_out'])] if on]
            print(f'{name:16} {label:12} {row["fpr_work_ms"]:8.1f} {w["O2"]:8.1f} {w["scalar"]:8.1f} '
                  f'{w["checked"]:8.1f} {str(r["O2"]):>6} {str(r["checked"]):>8}  {" ".join(flags)}')
        if 'ghc' in row:
            g = row['ghc']
            print(f'{"":16} {"ghc " + g["mode"]:12} {"":8} {g["work_ms"]:8.1f} {"":8} {"":8} '
                  f'{str(g["fpr_over_ghc"]):>6} {"":8}  {"FUSED" if g["fused"] else ""} '
                  f'{g["alloc_bytes_per_element"]} B/elem')
        for p in row['problems']:
            bad += 1
            print(f'  PROBLEM: {p}')
    if a.record:
        OUT.write_text(json.dumps(result, indent=1, sort_keys=True) + '\n')
        print(f'recorded to {OUT.relative_to(ROOT)}')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
