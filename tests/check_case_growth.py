#!/usr/bin/env python3
"""Case fallthrough must share code, preserve lexical scope and remain tail callable."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FPR = ROOT / 'fpr'
ENV = {k: v for k, v in os.environ.items() if not k.startswith('SOL_')}
ENV.update(SOL_JIT='0', SOL_GPU='0')


def run(args, *, env=None, timeout=60):
    p = subprocess.run([str(a) for a in args], cwd=ROOT, env=env,
                       capture_output=True, text=True, timeout=timeout)
    assert p.returncode == 0, (args, p.returncode, p.stdout, p.stderr)
    return p


def main():
    run(['make', 'fpr'], timeout=300)
    # Cabal supplies the exact compiler dependencies (not the global GHC DB).
    growth = run(['cabal', 'exec', '--', 'runghc', '-w', '-icompiler',
                  'tests/CaseGrowth.hs'], timeout=120)
    print(growth.stdout, end='')
    source = ROOT / 'tests/cases/fallback_scope.fpr'
    expected = (ROOT / 'tests/cases/fallback_scope.expected').read_text()
    sol = run([FPR, 'sol', source], env=ENV)
    assert sol.stdout == expected and sol.stderr == '', (sol.stdout, sol.stderr)
    with tempfile.TemporaryDirectory(prefix='fpr-case-growth-') as tmp:
        work = Path(tmp)
        binary = work / 'native'
        run([FPR, 'build', source, '-o', binary])
        native = run([binary])
        assert native.stdout == expected and native.stderr == '', (native.stdout, native.stderr)
        # Linear resource capture is profile-specific; every branch consumes v.
        linear = work / 'linear.sol'
        linear.write_text('release p v = case p of (1, 1) -> Vec.free v | _ -> Vec.free v.\n'
                          '> _ = release (1, 1) (Vec.new Unit);\n'
                          '  _ = release (1, 2) (Vec.new Unit); print "linear: OK".\n')
        p = run([FPR, 'sol', linear], env=ENV)
        assert p.stdout == 'linear: OK\n' and not p.stderr, (p.stdout, p.stderr)
        # Bytecode emitted through the real Sol driver stays bounded too.
        sizes = []
        for n in (4, 8, 16, 32):
            arms = ' | '.join(f'({i}, {i}) -> {i}' for i in range(n))
            script = work / f'case-{n}.sol'
            script.write_text(f'pick p = case p of {arms} | _ -> -1.\n'
                              f'> print "{{pick ({n-1}, {n-1})}}".\n')
            p = run([FPR, 'sol', '--asm', script], env=ENV)
            assert not p.stderr, p.stderr
            sizes.append(len(p.stdout))
            assert len(p.stdout) < 200_000, (n, len(p.stdout))
            p = run([FPR, 'sol', script], env=ENV)
            assert p.stdout == f'{n-1}\n' and not p.stderr, (p.stdout, p.stderr)
        assert all(b <= 2 * a for a, b in zip(sizes, sizes[1:])), sizes
        print('Bytecode bytes (4/8/16/32 arms): ' + ', '.join(map(str, sizes)))
    print('Case fallthrough: Sol + native values/effects, lexical captures, linear ownership, 20000 tail iterations: PASS')


if __name__ == '__main__':
    main()
