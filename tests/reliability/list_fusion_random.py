#!/usr/bin/env python3
"""Random differential test of checked List fusion (docs/2026-11-01-LIST-FUSION.md).

Generates random List pipelines (range/literal sources, map/filter stages,
sum/product/length/fold consumers or a printed List, direct or let-bound,
optionally behind a sibling binding) whose callbacks may trap: division by
zero, Int overflow, or an explicit `error`. Range ends include minInt/maxInt.
Each program is built natively twice, with fusion on and with
FPR_NO_LIST_FUSE=1, and the two runs must agree on exit status, stdout and
stderr (so on WHICH error is reported, not only that one is). The one
allowed difference is Core.FusionPolicy's documented relaxation: both runs
trap with Int overflow at a different element (same stdout); it is reported
as RELAXED, and LFR_STRICT=1 makes it fail too.

LFR_N programs (default 12, 120 with RELIABILITY_FULL=1), each holding
LFR_K pipelines (default 6; a trap ends the program, so later pipelines only
run when earlier ones return). LFR_SEED fixed (default 20261102). Divergent
programs are kept under $LFR_OUT (default build/list-fusion-random)."""
import os, random, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
FULL = os.environ.get('RELIABILITY_FULL') == '1'
N = int(os.environ.get('LFR_N', '120' if FULL else '12'))
K = int(os.environ.get('LFR_K', '6'))
SEED = int(os.environ.get('LFR_SEED', '20261102'))
JOBS = int(os.environ.get('LFR_JOBS', str(min(8, os.cpu_count() or 2))))
STRICT = os.environ.get('LFR_STRICT') == '1'
OUT = Path(os.environ.get('LFR_OUT', ROOT / 'build/list-fusion-random'))
MAXI = 4611686018427387903
MINI = '(0 - 4611686018427387903 - 1)'

def lit(v):
    return str(v) if v >= 0 else f'(0 - {-v})'

def source(r):
    k = r.random()
    if k < .55:
        a = r.randint(-6, 6); b = a + r.randint(-2, 12)
        return f'List.range {lit(a)} {lit(b)}'
    if k < .7:
        b = MAXI - r.randint(0, 3); a = b - r.randint(0, 4)
        return f'List.range {a} {b}'
    if k < .82:
        # short ranges only: a long range from minInt would make the unfused
        # program exhaust memory long before it traps
        n = r.randint(0, 4)
        return f'List.range {MINI} ({MINI} + {n})' if r.random() < .7 else f'List.range ({MINI} + {n + 1}) {MINI}'
    return '[' + ', '.join(lit(r.randint(-4, 9)) for _ in range(r.randint(0, 6))) + ']'

def fn(r):
    c = r.randint(-3, 5); big = r.choice([MAXI, 3037000500, 2305843009213693952])
    return r.choice([f'fn x -> x + {lit(c)}', f'fn x -> x - {lit(c)}', f'fn x -> x * {lit(c)}',
                     f'fn x -> x * {big}', f'fn x -> x + {MAXI}', f'fn x -> 100 / x',
                     f'fn x -> x / (x - {lit(c)})', f'fn x -> if x == {lit(c)} then error "boom {c}" else x',
                     'fn x -> x', f'fn x -> x * x * x * {big}'])

def pred(r):
    c = r.randint(-3, 5); big = r.choice([MAXI, 2305843009213693952])
    return r.choice([f'fn x -> x > {lit(c)}', f'fn x -> x != {lit(c)}', f'fn x -> 10 / (x - {lit(c)}) > 0',
                     f'fn x -> x * {big} > 0', f'fn x -> (if x == {lit(c)} then error "pred {c}" else x) > 0',
                     f'fn x -> x + {MAXI} > 0'])

def pipeline(r):
    e = source(r)
    for _ in range(r.randint(0, 3)):
        e = f'List.map ({fn(r)}) ({e})' if r.random() < .55 else f'List.filter ({pred(r)}) ({e})'
    return e

def consumer(r, xs):
    return r.choice([f'List.sum ({xs})', f'List.product ({xs})', f'List.length ({xs})',
                     f'List.fold (fn z x -> z + x) {lit(r.randint(-2, 2))} ({xs})',
                     f'List.fold (fn z x -> z * 2 + x) 0 ({xs})', f'List.fold (fn z x -> z) 7 ({xs})', xs])

def program(r):
    defs = []; calls = []
    for i in range(K):
        p = pipeline(r); body = consumer(r, 'ys' if r.random() < .4 else p)
        if 'ys' in body.split('(')[-1] or body.endswith('ys') or '(ys)' in body:
            sib = r.choice(['', f'  z = n * {MAXI};\n', '  z = n + 1;\n', '  z = 10 / (n - n);\n', '  z = n;\n'])
            use = 'z' if sib else 'n'
            res = body if body.startswith('List.') and not body.endswith(')') else body
            ret = f'"{{{use}}} {{{res}}}"' if sib else f'"{{{res}}}"'
            defs.append(f'p{i} n =\n  ys = {p};\n{sib}  {ret}.\n')
        else:
            defs.append(f'p{i} n = "{{{body}}}".\n')
        calls.append(f'print (p{i} {r.choice([0, 1, 2, MAXI])})')
    main = 'main =\n  ' + ';\n  '.join(f'_ = {c}' for c in calls) + ';\n  print "done".\n'
    return 'List = use "std/list".\n' + ''.join(defs) + main

def run(args, env, timeout=300):
    return subprocess.run(list(map(str, args)), env=env, text=True, capture_output=True, timeout=timeout)

def main():
    rng = random.Random(SEED)
    progs = [program(rng) for _ in range(N)]
    with tempfile.TemporaryDirectory(prefix='fpr-lfr-') as d:
        tmp = Path(d)
        base = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
        base.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), FPR_HARTS='1')
        def one(i):
            src = tmp / f'p{i}.fpr'; src.write_text(progs[i]); seen = []
            for off in (False, True):
                env = dict(base, XDG_CACHE_HOME=str(tmp / ('c-off' if off else 'c-on')))
                if off: env['FPR_NO_LIST_FUSE'] = '1'
                exe = tmp / f'p{i}.{int(off)}'
                b = run([ROOT / 'fpr', 'build', src, '--harts', '1', '-o', exe], env)
                if b.returncode: return i, 'BUILDFAIL', b.stderr[-1500:]
                try: x = run([exe], env, 60)
                except subprocess.TimeoutExpired: return i, 'TIMEOUT', ''
                seen.append((x.returncode, x.stdout, x.stderr))
            if seen[0] == seen[1]: return i, 'OK', ''
            info = f'fused={seen[0]!r}\nunfused={seen[1]!r}'
            # Core.FusionPolicy's documented relaxation: Int overflow may trap at
            # a different element. Both runs must still trap with an overflow
            # and print the same stdout up to the trap.
            if (not STRICT and seen[0][0] == seen[1][0] != 0 and seen[0][1] == seen[1][1]
                    and all('Int overflow' in x[2] for x in seen)):
                return i, 'RELAXED', info
            return i, 'DIVERGE', info
        with ThreadPoolExecutor(JOBS) as ex:
            res = list(ex.map(one, range(N)))
    relaxed = [x for x in res if x[1] == 'RELAXED']
    for i, st, info in relaxed: print(f'RELAXED p{i} (overflow at a different element; allowed)')
    bad = [x for x in res if x[1] not in ('OK', 'RELAXED')]
    if bad:
        OUT.mkdir(parents=True, exist_ok=True)
    for i, st, info in bad:
        (OUT / f'p{i}.fpr').write_text(progs[i])
        print(f'{st} p{i} (kept {OUT / f"p{i}.fpr"})\n{info}\n')
    print(f'list fusion random differential: seed {SEED}, {N} programs x {K} pipelines, {len(relaxed)} relaxed-overflow, {len(bad)} not OK')
    sys.exit(1 if bad else 0)

if __name__ == '__main__':
    main()
