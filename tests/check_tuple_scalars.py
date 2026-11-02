#!/usr/bin/env python3
"""Scalar replacement of loop-carried tuples and records (FPR_NO_TUPLE_SCALARS=1 rolls back)."""
from pathlib import Path
import json, os, re, subprocess, tempfile

ROOT = Path(__file__).resolve().parents[1]

STEP = '''step : (Int, Int) -> (Int, Int) .
step p = case p of (a, b) -> (b, (a + b) % 1000003).
loop : unsafe Int -> (Int, Int) -> Int .
'''

# name -> (source, requests with FPR_NO_TUPLE_SCALARS=1, requests with default)
PROGRAMS = {
    'tuple-step': (
        STEP + 'loop i p = if i == 0 then (case p of (a, _) -> a) else loop (i - 1) (step p).\nmain = print "{loop 1000 (0, 1)}".\n',
        1002,
        1,
    ),
    'let-bound-step': (
        STEP + 'loop i p = if i == 0 then (case p of (a, _) -> a) else next = step p; loop (i - 1) next.\nmain = print "{loop 1000 (0, 1)}".\n',
        1002,
        1,
    ),
    'conditional-forward': (
        STEP + 'loop i p = if i == 0 then (case p of (a, _) -> a) else loop (i - 1) (if i % 2 == 0 then step p else p).\nmain = print "{loop 1000 (0, 1)}".\n',
        502,
        1,
    ),
    'record-step': ('''Row = {a: Int, b: Int}.
step : Row -> Row .
step r = {a = r.b, b = (r.a + r.b) % 1000003}.
loop : unsafe Int -> Row -> Int .
loop i r = if i == 0 then r.a else loop (i - 1) (step r).
main = print "{loop 1000 {a = 0, b = 1}}".
''', 1002, 1),
    'two-tuples': ('''step : (Int, Int) -> (Int, Int) .
step p = case p of (a, b) -> (b, (a + b) % 1000003).
loop2 : unsafe Int -> (Int, Int) -> (Int, Int) -> Int .
loop2 i p q =
  if i == 0 then
    (case p of (a, _) -> case q of (c, _) -> a + c)
  else
    loop2 (i - 1) (step p) (step q).
main = print "{loop2 500 (0, 1) (1, 2)}".
''', 1003, 1),
    'escape-whole': ('''idPair : (Int, Int) -> (Int, Int) .
idPair p = p.
loop : unsafe Int -> (Int, Int) -> (Int, Int) .
loop i p = if i == 0 then idPair p else loop (i - 1) (case p of (a, b) -> (b, a + 1)).
main = case loop 100 (0, 1) of (a, b) -> print "{a} {b}".
''', None, None),
}


def run(args, env, timeout=180):
    return subprocess.run(list(map(str, args)), cwd=ROOT, env=env, text=True,
                          capture_output=True, timeout=timeout)


def main():
    with tempfile.TemporaryDirectory(prefix='fpr-tuple-scalars-') as directory:
        tmp = Path(directory)
        base = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
        base.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), FPR_HARTS='1',
                    XDG_CACHE_HOME=str(tmp / 'cache'))

        def build(name, text, disabled):
            path = tmp / (name + '.fpr')
            path.write_text(text)
            env = dict(base, FPR_COST_PROBE='1', FPR_NO_LOOP_REGIONS='1',
                       FPR_NO_CALL_REGIONS='1', FPR_NO_REUSE='1')
            if disabled:
                env['FPR_NO_TUPLE_SCALARS'] = '1'
            exe = tmp / f'{name}-{int(disabled)}'
            made = run([ROOT / 'fpr', 'build', path, '--harts', '1', '-o', exe], env)
            assert made.returncode == 0, (name, made.stdout[-2000:], made.stderr[-6000:])
            return exe, env

        for name, (text, off, on) in PROGRAMS.items():
            seen = {}
            for disabled in (True, False):
                exe, env = build(name, text, disabled)
                observed = run([exe], dict(env, FPR_COST_REPORT='1'), timeout=60)
                match = re.search(r'\[fpr cost\] (\{.*\})', observed.stderr)
                assert match, (name, disabled, observed.stderr)
                ledger = json.loads(match.group(1))
                stderr = observed.stderr.replace(match.group(0), '')
                seen[disabled] = (observed.returncode, observed.stdout, stderr, ledger['alloc_requests'])
            assert seen[True][:3] == seen[False][:3], (name, seen)
            wanted = (off, on)
            if wanted != (None, None):
                assert (seen[True][3], seen[False][3]) == wanted, (name, seen, wanted)
            print(f'Tuple scalar replacement: {name} {seen[True][3]} -> {seen[False][3]} requests PASS', flush=True)

        # Gate on the proposal benchmark itself: tests/bench/unbox/tuple_loop.fpr
        # drops its 20,000,000 tuple allocations to 0 (2 startup string allocations).
        bench_exe = tmp / 'tuple_loop_bench'
        bench_env = dict(base, FPR_COST_PROBE='1')
        made = run([ROOT / 'fpr', 'build', ROOT / 'tests/bench/unbox/tuple_loop.fpr', '--harts', '1', '-o', bench_exe], bench_env)
        assert made.returncode == 0, made.stderr[-4000:]
        observed = run([bench_exe], dict(bench_env, FPR_COST_REPORT='1'), timeout=60)
        assert observed.returncode == 0 and observed.stdout == 'tuple_loop 506612\n', (observed.stdout, observed.stderr)
        match = re.search(r'\[fpr cost\] (\{.*\})', observed.stderr)
        assert match, observed.stderr
        ledger = json.loads(match.group(1))
        assert ledger['alloc_requests'] <= 2, ledger
        print(f'Tuple scalar replacement: tests/bench/unbox/tuple_loop.fpr {ledger["alloc_requests"]} requests PASS', flush=True)

        # Rollback: FPR_NO_TUPLE_SCALARS=1 alters the emitted assembly and omits
        # the field/scalar worker for constructor-tree tuple loops.
        source = tmp / 'tuple-step.fpr'
        outputs = {}
        for disabled in (True, False):
            env = dict(base)
            if disabled:
                env['FPR_NO_TUPLE_SCALARS'] = '1'
            assembly = tmp / f'tuple-step-{int(disabled)}.s'
            made = run([ROOT / 'fpr', 'compile', '--system=posix', '--target=rv64', source, assembly], env)
            assert made.returncode == 0, made.stderr[-4000:]
            outputs[disabled] = assembly.read_text()
        assert outputs[True] != outputs[False]
        assert '_x24worker_x2escalar_x2e_x24worker_x2efields_x2eloop' in outputs[False]
        assert '_x24worker_x2escalar_x2e_x24worker_x2efields_x2eloop' not in outputs[True]
        print('Tuple scalar replacement rollback PASS', flush=True)


if __name__ == '__main__':
    main()
