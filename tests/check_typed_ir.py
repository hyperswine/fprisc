#!/usr/bin/env python3
"""The typed IR of M1 (docs/2026-10-20-TYPED-IR-M1.md): its verifier and
lowering checks (tests/TypedIR.hs), then the real pipeline: the scalar
fixture compiled for each 64-bit target with FPR_TYPED_IR reports which
functions lower and why others decline, the dumps are the same on every target
and between runs, and the reference evaluator's answers and traps equal
the legacy binary's for the same calls. Tick counts use structural
expectations, not measured native counters. The emitted
assembly is byte-identical with the report on and off: the report
changes nothing."""
import os, re, shutil, subprocess, sys, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
ENV = {**os.environ, 'FPR_HOME': str(ROOT), 'FPR_PATH': str(ROOT)}
ENV.pop('FPR_FOREIGN', None)
ENV.pop('FPR_TYPED_IR', None)
ENV['FPR_TYPED_IR_BACKEND'] = 'legacy' # the differential's reference is the legacy generator
# cabal exec needs libarchive's pkg-config metadata as the Makefile supplies it
for keg in ('/opt/homebrew/opt/libarchive/lib/pkgconfig', '/usr/local/opt/libarchive/lib/pkgconfig'):
    if Path(keg).is_dir():
        ENV['PKG_CONFIG_PATH'] = keg + ':' + ENV.get('PKG_CONFIG_PATH', '')
        break

def run(args, env=ENV, expected=0, timeout=600):
    p = subprocess.run([str(a) for a in args], cwd=ROOT, env=env, capture_output=True, text=True, timeout=timeout)
    assert p.returncode == expected, (args, p.returncode, p.stdout[-3000:], p.stderr[-3000:])
    return p.stdout + p.stderr

run(['make', 'fpr'])
ghc = ['cabal', 'exec', '--', 'runghc'] if shutil.which('cabal') else ['runghc']
print(run([*ghc, '-w', '-icompiler', 'tests/TypedIR.hs']), end='', flush=True)

FIXTURE = 'tests/typed_ir/scalar.fpr'
CALLS = [('fib', [20]), ('sum', [1000, 0]), ('addovf', [4611686018427387903, 1]), ('divz', [7, 0]),
         ('divz', [7, 2]), ('even', [11]), ('clamp', [50, 0, 10]), ('clamp', [-5, 0, 10]), ('clamp', [5, 0, 10]),
         ('boolResult', [3, 1]), ('boolResult', [3, 0])]
mode = 'dump ' + ' '.join('eval:' + fn + ''.join(':' + str(a) for a in args) for fn, args in CALLS)
with tempfile.TemporaryDirectory(prefix='fpr-typed-ir-') as d:
    tmp = Path(d)
    # the legacy answers
    exe = tmp / 'scalar'
    run(['./fpr', 'build', FIXTURE, '-o', exe])
    legacy = {}
    for fn, args in CALLS:
        p = subprocess.run([str(exe), fn, *map(str, args)], capture_output=True, text=True, timeout=60)
        out = p.stdout + p.stderr
        if p.returncode == 0:
            legacy[(fn, tuple(args))] = ('value', out.strip())
        else:
            m = re.search(r'PANIC \[actor 0\]: (.*) \*\*\*', out)
            assert m, (fn, args, out)
            legacy[(fn, tuple(args))] = ('trap', m.group(1))
    # Independent Bool truth-table oracle: equality contributes 10,
    # inequality 1. Exercise optimization/cache transitions, not just
    # agreement between two implementations sharing a worker transform.
    for disabled in ('1', '0', '1', '0'):
        run(['./fpr', 'build', FIXTURE, '-o', exe], {**ENV, 'FPR_NO_SCALAR_WORKERS': disabled})
        for n in (0, 1, 7):
            for flag in (-1, 0, 1):
                got = run([exe, 'boolResult', n, flag]).strip()
                assert got == ('10' if flag > 0 else '1'), (disabled, n, flag, got)
    dumps = {}
    for target in ('a64', 'x64', 'rv64'):
        asm_off, asm_on = tmp / f'{target}-off.s', tmp / f'{target}-on.s'
        run(['./fpr', f'--target={target}', f'--prelude={ROOT}/core/prelude.fpr', FIXTURE, asm_off])
        notes = run(['./fpr', f'--target={target}', f'--prelude={ROOT}/core/prelude.fpr', FIXTURE, asm_on], {**ENV, 'FPR_TYPED_IR': mode})
        assert asm_off.read_bytes() == asm_on.read_bytes(), f'{target}: the report changed the emitted assembly'
        lines = [l for l in notes.splitlines() if l.startswith('typed-ir: ')]
        assert lines, notes[-2000:]
        lowered = {m.group(1) for l in lines for m in [re.match(r'typed-ir: (\S+) lowered', l)] if m}
        fallbacks = {m.group(1): m.group(2) for l in lines for m in [re.match(r'typed-ir: (\S+) fallback: (.*)', l)] if m}
        for fn in ('fib', 'sum', 'addovf', 'divz', 'even', 'odd', 'clamp', 'boolEq', 'boolNe', 'boolResult'):
            assert fn in lowered, (target, fn, fallbacks.get(fn), lines[:3])
        assert '$worker.scalar.fib' in lowered and '$worker.scalar.sum' in lowered, (target, sorted(lowered))
        # Aggregate/string coverage now admits the argument parsing and print root.
        assert 'main' in lowered, (target, fallbacks.get('main'))
        coverage = next(l for l in lines if l.startswith('typed-ir: coverage'))
        dumps[target] = '\n'.join(l for l in lines if l.startswith('typed-ir: | '))
        assert dumps[target], target
        for fn, args in CALLS:
            prefix = f'typed-ir: eval {fn}' + ''.join(' ' + str(a) for a in args)
            line = next(l for l in lines if l.startswith(prefix + ' '))
            kind, want = legacy[(fn, tuple(args))]
            if kind == 'value':
                m = re.match(re.escape(prefix) + r' = (-?\d+) \((\d+) safepoints, (\d+) calls\)$', line)
                assert m and m.group(1) == want, (target, line, want)
            else:
                m = re.match(re.escape(prefix) + r' trap: (.*) \(\d+ safepoints, \d+ calls\)$', line)
                assert m and m.group(1) == want, (target, line, want)
        # the public function is the worker's wrapper (one activation), then
        # the recursion ticks once per activation and the loop once per turn
        fib_line = next(l for l in lines if l.startswith('typed-ir: eval fib 20 '))
        assert '(21892 safepoints, 21892 calls)' in fib_line, fib_line
        sum_line = next(l for l in lines if l.startswith('typed-ir: eval sum 1000 0 '))
        assert '(1002 safepoints, 2 calls)' in sum_line, sum_line
        # the simplification shared sum's repeated untag of n; every eval
        # line above was computed on the simplified program and checked
        # against the lowered one by the report itself
        assert any(re.match(r'typed-ir: sum lowered \(\d+ blocks, \d+ instructions, \d+ removed by simplification\)', l) for l in lines), [l for l in lines if ' sum lowered' in l]
        print(f'{target}: {coverage[10:]}; main lowers with aggregate/string coverage; {len(CALLS)} evaluations equal the legacy binary')
    assert dumps['a64'] == dumps['x64'] == dumps['rv64'], 'the dump differs between targets'
    again = run(['./fpr', '--target=a64', f'--prelude={ROOT}/core/prelude.fpr', FIXTURE, tmp / 'again.s'], {**ENV, 'FPR_TYPED_IR': 'dump'})
    assert '\n'.join(l for l in again.splitlines() if l.startswith('typed-ir: | ')) == dumps['a64'], 'the dump differs between runs'
    # rv32 says it is out of M1's scope rather than lowering with the wrong Int range
    note32 = run(['./fpr', '--target=rv32', f'--prelude={ROOT}/core/prelude.fpr', FIXTURE, tmp / 'rv32.s'], {**ENV, 'FPR_TYPED_IR': '1'})
    assert 'typed-ir: not available on rv32' in note32, note32[-500:]
print('Typed IR M1: a64/x64/rv64 portable lowering, deterministic dumps, native value/trap parity, structural tick counts, independent Bool oracle and worker cache transitions, report leaves emission unchanged: PASS')
