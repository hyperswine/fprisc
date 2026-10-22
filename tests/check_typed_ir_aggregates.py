#!/usr/bin/env python3
"""Strict native aggregate/string coverage against independent results."""
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ENV = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
ENV.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), FPR_NO_INLINE='1',
           FPR_NO_FIELD_WORKERS='1', FPR_NO_SCALAR_WORKERS='1', FPR_NO_REUSE='1')
NAMES = 'aggPair,aggSumPair,aggNested,aggSumNested,aggRecord,aggReadRecord,aggLiteral,aggByteAt,aggLengthOf,aggKeep'


def run(cmd, env):
    return subprocess.run(list(map(str, cmd)), cwd=ROOT, env=env,
                          capture_output=True, text=True, timeout=600)


def main():
    p = run(['make', 'fpr'], ENV)
    assert p.returncode == 0, p.stderr[-3000:]
    with tempfile.TemporaryDirectory(prefix='fpr-aggregates-') as d:
        root = Path(d)
        modes = ('typed', 'entry')
        for mode in modes:
            env = dict(ENV, XDG_CACHE_HOME=str(root / mode))
            env.update(FPR_TYPED_IR_BACKEND='mixed', FPR_TYPED_IR_STRICT=NAMES)
            if mode == 'entry':
                env.update(FPR_TYPED_IR_SHALLOW_STACK='1', FPR_TYPED_IR_FORWARD_PARAMS='1')
            exe = root / ('app-' + mode)
            built = run([ROOT / 'fpr', 'build', 'tests/typed_ir/aggregates.fpr', '-o', exe, '-v'], env)
            assert built.returncode == 0, built.stdout[-1500:] + built.stderr[-4000:]
            notes = built.stdout + built.stderr
            for name in NAMES.split(','):
                assert re.search(r'typed-ir-backend: ' + name + r' native ', notes), (name, notes[-4000:])
            for harts in ('1', '4'):
                for n in (-17, 0, 123):
                    p = run([exe, 'value', n], dict(env, FPR_HARTS=harts))
                    want = f'{4*n+6} {n+3} {4004000+2*n+1} 4 196 128 195 191\n'
                    assert p.returncode == 0 and p.stdout == want, (mode, n, p.returncode, p.stdout, p.stderr, want)
                for index in (-1, 4):
                    p = run([exe, 'bad', index], dict(env, FPR_HARTS=harts))
                    msg = f'charAt: index out of range ({index}, length 4)'
                    assert p.returncode == 1 and msg in p.stdout + p.stderr, (mode, index, p.stdout, p.stderr)
            print(f'{mode}: nested constructors, records, live references across 2000 allocations/calls, byte strings, range traps, one/four harts PASS', flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
