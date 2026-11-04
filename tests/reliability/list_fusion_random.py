#!/usr/bin/env python3
"""Random differential test of the default build's zero-overhead passes.

Started as the checked List fusion test (docs/2026-11-01-LIST-FUSION.md); on
2026-11-03 it was extended to check the passes together, the way the default
build runs them (docs/2026-11-03-DEFAULT-BUILD-GATES.md).

Each generated program holds LFR_K independent cases. A case is one of:
  plain    a List pipeline (range/literal source, map/filter stages,
           sum/product/length/fold or a printed List), direct or let-bound,
           optionally behind a sibling binding that can itself trap;
  print    the same with printing callbacks (`print x >> body`), so the
           order and number of callback calls is visible on stdout;
  capture  callbacks that capture a let-bound value whose evaluation can
           print or trap, and a producer used only through a closure capture;
  cond     a let-bound producer used only under an if arm, a case arm, the
           right of `and`, after a refutable pattern, or right of `|>?`;
  trmc     materialized map/filter/append/take outputs (typed TRMC);
  tuple    a loop-carried tuple or record whose next state runs a pipeline
           (tuple scalars, tick batching);
  pair     a pair-returning recursion or accumulator (pair returns);
  tick     a self-looping accumulator around a pipeline (tick batching);
  known    an Option-returning helper or a tuple scrutinised in a loop
           (case of known constructor), with trapping fields.
  helper   map/filter wrappers with captures, effects and shared results.
  fold     tuple accumulators with captures, conditional forwarding and traps.
Callbacks may trap: division by zero, Int overflow, `error`, a failed
refutable pattern. Range ends include minInt/maxInt.

`main` selects one case from its argument, so every case runs in its own
process and an early trap cannot hide a later case. Each program is built
with the default options, with every pass in PASSES disabled together, and
(for the first LFR_SINGLE programs) with each pass disabled alone. Every
variant must agree with the default build on exit status, stdout and stderr
(so on WHICH error is reported, not only that one is). The one allowed
difference is Core.FusionPolicy's documented relaxation: both runs trap with
Int overflow at a different element with the same stdout, and the variant
turns List fusion off (no other pass has a relaxation); it is reported as
RELAXED, and LFR_STRICT=1 makes it fail too.

LFR_N programs (default 8, 96 with RELIABILITY_FULL=1) of LFR_K cases
(default 10), LFR_SINGLE programs (default 2, 24 full) also per pass.
LFR_SEED fixed (default 20261103). Divergent programs are kept under
$LFR_OUT (default build/list-fusion-random) with the case and variant."""
import hashlib, os, random, subprocess, sys, tempfile, time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
FULL = os.environ.get('RELIABILITY_FULL') == '1'
N = int(os.environ.get('LFR_N', '96' if FULL else '8'))
K = int(os.environ.get('LFR_K', '10'))
SINGLE = int(os.environ.get('LFR_SINGLE', '24' if FULL else '2'))
SEED = int(os.environ.get('LFR_SEED', '20261103'))
JOBS = int(os.environ.get('LFR_JOBS', str(min(8, os.cpu_count() or 2))))
STRICT = os.environ.get('LFR_STRICT') == '1'
OUT = Path(os.environ.get('LFR_OUT', ROOT / 'build/list-fusion-random'))
MAXI = 4611686018427387903
MINI = '(0 - 4611686018427387903 - 1)'
# compiler/Compiler/Options.hs: FPR_NO_<NAME> disables one pass.
PASSES = ['FPR_NO_LIST_FUSE', 'FPR_NO_CASE_KNOWN', 'FPR_NO_TUPLE_SCALARS',
          'FPR_NO_TICK_BATCH', 'FPR_NO_TRMC', 'FPR_NO_PAIR_RETURNS']
VARIANTS = {'default': (), 'all-off': tuple(PASSES)}
VARIANTS.update({p[len('FPR_NO_'):].lower() + '-off': (p,) for p in PASSES})
KINDS = ['plain', 'print', 'capture', 'cond', 'trmc', 'tuple', 'pair', 'tick', 'known', 'helper', 'fold']


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


class Gen:
    """One program's generator; `vs` are the Int names a callback may capture."""
    def __init__(self, r):
        self.r = r; self.tags = 0; self.row = False

    def tag(self):
        self.tags += 1
        return f't{self.tags}'

    def fbody(self, vs):
        r = self.r; c = r.randint(-3, 5); big = r.choice([MAXI, 3037000500, 2305843009213693952]); v = r.choice(vs)
        return r.choice([f'x + {lit(c)}', f'x - {lit(c)}', f'x * {lit(c)}', f'x * {big}', f'x + {MAXI}',
                         '100 / x', f'x / (x - {lit(c)})', f'if x == {lit(c)} then error "boom {c}" else x',
                         'x', f'x * x * x * {big}', f'x + {v}', f'x * {v}', f'x / ({v} - {lit(c)})'])

    def pbody(self, vs):
        r = self.r; c = r.randint(-3, 5); big = r.choice([MAXI, 2305843009213693952]); v = r.choice(vs)
        return r.choice([f'x > {lit(c)}', f'x != {lit(c)}', f'10 / (x - {lit(c)}) > 0', f'x * {big} > 0',
                         f'(if x == {lit(c)} then error "pred {c}" else x) > 0', f'x + {MAXI} > 0',
                         f'x > {v}', f'x % ({v} - {lit(c)}) == 0'])

    def lam(self, body, printing):
        # the tag makes the calling stage visible; `print x >> e` runs e after printing
        return f'fn x -> print "{self.tag()} {{x}}" >> ({body})' if printing else f'fn x -> {body}'

    def pipeline(self, vs, printing=0.0, stages=(0, 3)):
        r = self.r; e = source(r)
        for _ in range(r.randint(*stages)):
            p = r.random() < printing
            e = (f'List.map ({self.lam(self.fbody(vs), p)}) ({e})' if r.random() < .55
                 else f'List.filter ({self.lam(self.pbody(vs), p)}) ({e})')
        return e

    def int_consumer(self, xs):
        r = self.r
        return r.choice([f'List.sum ({xs})', f'List.product ({xs})', f'List.length ({xs})',
                         f'List.fold (fn z x -> z + x) {lit(r.randint(-2, 2))} ({xs})',
                         f'List.fold (fn z x -> z * 2 + x) 0 ({xs})', f'List.fold (fn z x -> z) 7 ({xs})'])

    def consumer(self, xs):
        return xs if self.r.random() < .2 else self.int_consumer(xs)

    def sibling(self):
        return self.r.choice(['', f'z = n * {MAXI}', 'z = n + 1', 'z = 10 / (n - n)', 'z = n',
                              'z = print "sib {n}" >> (n + 1)'])

    # Each case returns (definitions, body of cI n); main prints cI's value.
    def plain(self, i, printing=0.0):
        r = self.r; p = self.pipeline(['n'], printing)
        if r.random() < .45:
            sib = self.sibling(); body = self.consumer('ys')
            if sib:
                return '', f'ys = {p};\n  {sib};\n  ({body}, z)'
            return '', f'ys = {p};\n  {body}'
        return '', self.consumer(p)

    def capture(self, i):
        r = self.r
        k = r.choice(['n * 3', '100 / (n - 1)', f'n + {MAXI}', 'List.sum (List.range 1 (n % 50))',
                      'print "cap {n}" >> (n + 1)', f'n * {MAXI}', '2'])
        if r.random() < .25:
            # used only through a closure capture (review t2)
            p = self.pipeline(['n', 'k'], .2)
            return '', f'k = {k};\n  ys = {p};\n  List.map (fn j -> j + {self.int_consumer("ys")}) [1, 2]'
        p = self.pipeline(['k', 'n'], .3, (1, 3))
        if r.random() < .5:
            return '', f'k = {k};\n  ys = {p};\n  {self.consumer("ys")}'
        return '', f'k = {k};\n  {self.consumer(p)}'

    def helper(self, i):
        r = self.r
        f = self.lam(self.fbody(['n']), r.random() < .3)
        p = self.lam(self.pbody(['n']), r.random() < .3)
        defs = (f'hm{i} n xs = List.map ({f}) xs.\n'
                f'hp{i} n xs = List.filter ({p}) xs.\n')
        pipeline = f'hm{i} n (hp{i} n ({source(r)}))'
        if r.random() < .3:
            return defs, f'ys = {pipeline};\n  List.sum ys + List.length ys'
        return defs, self.int_consumer(pipeline)

    def fold(self, i):
        r = self.r
        field = f's + ({self.fbody(["n"])})'
        if r.random() < .3:
            field = f'print "{self.tag()} {{x}}" >> ({field})'
        step = f'case p of (s, c) -> ({field}, c + 1)'
        if r.random() < .5:
            step = f'if x > n then p else ({step})'
        xs = self.pipeline(['n'], .15, (0, 1))
        return '', (f'case List.fold (fn p x -> {step}) (n, 0) ({xs}) '
                    'of (s, c) -> s + c')

    def cond(self, i):
        r = self.r; p = self.pipeline(['n'], .25); use = self.int_consumer('ys')
        c = r.choice(['n > 1', 'n == 0', 'n < 2'])
        shape = r.choice(['if', 'case', 'and', 'refutable', 'pipe'])
        head = f'ys = {p};\n  '
        if shape == 'if':
            return '', head + f'if {c} then {use} else 0'
        if shape == 'case':
            return '', head + f'case {c} of True -> {use} | False -> 0'
        if shape == 'and':
            return '', head + f'{c} and {use} > 0'
        if shape == 'refutable':
            return '', (f'o = (if {c} then O.Some n else O.None);\n  ' + head +
                        f'O.Some v = o;\n  v + {use}')
        return '', (f'q = (if {c} then Ok n else Err "no");\n  ' + head +
                    f'res = q |>? (fn v -> Ok (v + {use}));\n  case res of Ok v -> v | Err e -> 0 - 1')

    def trmc(self, i):
        r = self.r; a = self.pipeline(['n'], .2, (1, 3)); b = self.pipeline(['n'], .2)
        return '', r.choice([a, f'List.append ({a}) ({b})', f'List.length (List.append ({a}) ({b}))',
                             f'List.take 3 ({a})', f'List.head ({a})'])

    def step_arith(self):
        # trap-capable arithmetic but no call: tuple scalars admit these steps
        return self.r.choice(['a + b * i', '(a + b) % 1000003', 'a + 100 / (i - 2)', f'a * {MAXI} + b',
                              'a - b + n', 'b * n + i'])

    def tuple(self, i):
        r = self.r; e = self.int_consumer(self.pipeline(['i', 'n'], .2))
        start = r.randint(1, 4)
        # the pipeline runs either in the next state (tuple scalars decline)
        # or in the exit, with an arithmetic next state (tuple scalars fire)
        inner = r.random() < .5
        nxt = e if inner else self.step_arith()
        done = '' if inner else f' + {e}'
        if r.random() < .35:
            self.row = True
            step = f'{{a = r.b, b = {nxt.replace("a", "r.a").replace("b", "r.b") if not inner else "r.a + " + e}}}'
            if r.random() < .4: step = f'(if i % 2 == 0 then {step} else r)'
            return (f'l{i} : unsafe Int -> Int -> Row -> Int .\n'
                    f'l{i} n i r = if i == 0 then r.a - r.b{done} else l{i} n (i - 1) {step}.\n',
                    f'l{i} n {start} {{a = 0, b = 1}}')
        step = f'(case p of (a, b) -> (b, {"a + " + e if inner else nxt}))'
        if r.random() < .3: step = f'(if i % 2 == 0 then {step} else p)'
        elif r.random() < .3: step = f'next = {step[1:-1]}; l{i} n (i - 1) next'
        call = step if step.startswith('next') else f'l{i} n (i - 1) {step}'
        return (f'l{i} : unsafe Int -> Int -> (Int, Int) -> Int .\n'
                f'l{i} n i p = if i == 0 then (case p of (a, b) -> a - b{done}) else {call}.\n',
                f'l{i} n {start} (0, 1)')

    def known(self, i):
        # case of a known constructor: an Option-returning helper (or a tuple)
        # scrutinised in a loop; the scrutinee's fields can trap
        r = self.r; e = self.int_consumer(self.pipeline(['i', 'n'], .2)); c = r.randint(-2, 4)
        some = self.fbody(['x', 'n'])
        h = (f'h{i} : Int -> Int -> O.Option Int .\n'
             f'h{i} n x = if x > {lit(c)} then O.Some ({some}) else O.None.\n')
        arm = r.choice(['O.Some y -> acc + y | O.None -> acc + 1', 'O.Some _ -> acc + 1 | O.None -> acc',
                        'O.None -> acc + 1 | _ -> acc + 7'])
        scrut = r.choice([f'h{i} n (i + {e})', f'h{i} n i'])
        body = f'case {scrut} of {arm}'
        if r.random() < .3:
            body = f'case (i + 1, {e}) of (a, b) -> acc + a * 10 + b'
        exit_ = f'acc + {e}' if r.random() < .3 else 'acc'
        return (h + f'l{i} : unsafe Int -> Int -> Int -> Int .\n'
                f'l{i} n i acc = if i == 0 then {exit_} else l{i} n (i - 1) ({body}).\n',
                f'l{i} n {r.randint(1, 5)} 0')

    def pair(self, i):
        r = self.r; e = self.int_consumer(self.pipeline(['i', 'n'], .2)); start = r.randint(1, 4)
        if r.random() < .5:
            d = (f'l{i} : unsafe Int -> Int -> (Int, Int) .\n'
                 f'l{i} n i = if i == 0 then (0, 0) else (case l{i} n (i - 1) of (s, c) -> (s + {e}, c + 1)).\n')
            return d, f'case l{i} n {start} of (s, c) -> s - c'
        d = (f'l{i} : unsafe Int -> Int -> Int -> Int -> (Int, Int) .\n'
             f'l{i} n i s c = if i == 0 then (s, c) else l{i} n (i - 1) (s + {e}) (c + 1).\n')
        return d, f'case l{i} n {start} 0 0 of (s, c) -> s * 2 + c'

    def tick(self, i):
        e = self.int_consumer(self.pipeline(['i', 'n'], .15)); start = self.r.randint(1, 5)
        return (f'l{i} : unsafe Int -> Int -> Int -> Int .\n'
                f'l{i} n i acc = if i == 0 then acc else l{i} n (i - 1) (acc + {e}).\n',
                f'l{i} n {start} 0')

    def case(self, i, kind):
        if kind == 'print':
            return self.plain(i, .6)
        return getattr(self, kind)(i)


def program(r):
    """Return (source, [case kind]); `main N` runs case N with two arguments."""
    g = Gen(r); defs = []; arms = []; kinds = []
    for i in range(K):
        kind = r.choice(KINDS); kinds.append(kind)
        helpers, body = g.case(i, kind)
        # a case calling an unsafe (unmeasured) loop must say so; all return Int
        sig = f'c{i} : unsafe Int -> Int .\n' if helpers and kind != 'helper' else ''
        defs.append(helpers + sig + f'c{i} n =\n  {body}.\n')
        a, b = r.sample([0, 1, 2, 3, MAXI], 2)
        arms.append(f'["{i}"] -> _ = print (c{i} {a}); print (c{i} {b})')
    head = 'List = use "std/list".\nO = use "std/option".\n'
    if g.row: head += 'Row = {a: Int, b: Int}.\n'
    main = 'main = case Sys.args Unit of\n    ' + '\n  | '.join(arms) + '\n  | _ -> print "cases".\n'
    return head + ''.join(defs) + main, kinds


def run(args, env, timeout=300):
    return subprocess.run(list(map(str, args)), env=env, text=True, capture_output=True, timeout=timeout)


def code_digest(exe):
    """Hash of the code section only: the executable may also embed option text."""
    if sys.platform == 'darwin':
        code = subprocess.run(['otool', '-s', '__TEXT', '__text', str(exe)], capture_output=True).stdout
        code = code.split(b'\n', 1)[-1]  # drop the line naming the file
    else:
        out = Path(str(exe) + '.text')
        subprocess.run(['objcopy', '-O', 'binary', '--only-section=.text', str(exe), str(out)], capture_output=True)
        code = out.read_bytes() if out.exists() else exe.read_bytes()
    return hashlib.sha256(code).hexdigest()


def compare(ref, got, variant):
    if ref == got: return 'OK'
    # Core.FusionPolicy's documented relaxation: Int overflow may trap at a
    # different element. Both runs must still trap with an overflow and print
    # the same stdout up to the trap. Only List fusion has this relaxation, so
    # it applies only to variants that turn List fusion off.
    if (not STRICT and 'FPR_NO_LIST_FUSE' in VARIANTS[variant] and ref[0] == got[0] != 0 and ref[1] == got[1]
            and all('Int overflow' in x[2] for x in (ref, got))):
        return 'RELAXED'
    return 'DIVERGE'


def main():
    started = time.time()
    rng = random.Random(SEED)
    progs = [program(rng) for _ in range(N)]
    jobs = [(i, v) for i in range(N) for v in VARIANTS if v in ('default', 'all-off') or i < SINGLE]
    with tempfile.TemporaryDirectory(prefix='fpr-lfr-') as d:
        tmp = Path(d)
        base = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
        base.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), FPR_HARTS='1')
        for i, (text, _) in enumerate(progs): (tmp / f'p{i}.fpr').write_text(text)

        digests = {}

        def one(job):
            i, variant = job
            env = dict(base, XDG_CACHE_HOME=str(tmp / f'c-{variant}'))
            env.update({flag: '1' for flag in VARIANTS[variant]})
            exe = tmp / f'p{i}.{variant}'
            b = run([ROOT / 'fpr', 'build', tmp / f'p{i}.fpr', '--harts', '1', '-o', exe], env)
            if b.returncode: return job, 'BUILDFAIL', b.stderr[-1500:]
            digests[job] = code_digest(exe)
            seen = []
            for k in range(K):
                try: x = run([exe, k], env, 60); seen.append((x.returncode, x.stdout, x.stderr))
                except subprocess.TimeoutExpired: seen.append(('TIMEOUT', '', ''))
            return job, 'RAN', seen

        with ThreadPoolExecutor(JOBS) as ex:
            got = {job: (st, data) for job, st, data in ex.map(one, jobs)}
    bad = []; relaxed = []; outcomes = Counter(); compared = 0
    for (i, variant), (st, data) in sorted(got.items()):
        if st == 'BUILDFAIL':
            bad.append((i, None, variant, 'BUILDFAIL', data)); continue
        ref_state, ref = got[(i, 'default')]
        if variant == 'default' or ref_state != 'RAN': continue
        for k in range(K):
            compared += 1
            verdict = 'TIMEOUT' if 'TIMEOUT' in (ref[k][0], data[k][0]) else compare(ref[k], data[k], variant)
            info = f'default={ref[k]!r}\n{variant}={data[k]!r}'
            if verdict == 'RELAXED': relaxed.append((i, k, variant))
            elif verdict != 'OK': bad.append((i, k, variant, verdict, info))
    for i, (text, kinds) in enumerate(progs):
        state, ref = got[(i, 'default')]
        if state != 'RAN': continue
        for k, kind in enumerate(kinds):
            rc = ref[k][0]
            outcomes[(kind, 'returns' if rc == 0 else 'traps' if rc != 'TIMEOUT' else 'timeout')] += 1
    for i, k, variant in relaxed:
        print(f'RELAXED p{i} case {k} {variant} (overflow at a different element; allowed)')
    if bad:
        OUT.mkdir(parents=True, exist_ok=True)
    for i, k, variant, st, info in bad:
        (OUT / f'p{i}.fpr').write_text(progs[i][0])
        where = f'case {k} ({progs[i][1][k]}) ' if k is not None else ''
        print(f'{st} p{i} {where}{variant} (kept {OUT / f"p{i}.fpr"}; run with argument {k})\n{info}\n')
    # Evidence that a variant changed code at all: its executable differs from
    # the default build's (a remark that a rewrite fired is not proof).
    changed = Counter(); built = Counter()
    for (i, variant), h in digests.items():
        if variant != 'default' and (i, 'default') in digests:
            built[variant] += 1; changed[variant] += h != digests[(i, 'default')]
    print('code sections differing from default: ' + ', '.join(f'{v} {changed[v]}/{built[v]}' for v in VARIANTS if v in built))
    mix = ', '.join(f'{kind} {outcomes[(kind, "returns")]}/{outcomes[(kind, "traps")]}' for kind in KINDS)
    print(f'case mix (returns/traps in the default build): {mix}')
    print(f'default-build differential: seed {SEED}, {N} programs x {K} cases, variants all-off + '
          f'{len(PASSES)} single-pass on {min(SINGLE, N)} programs; {compared} comparisons, '
          f'{len(relaxed)} relaxed-overflow, {len(bad)} not OK ({time.time() - started:.0f} s)')
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
