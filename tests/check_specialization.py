#!/usr/bin/env python3
"""Differential semantics, direct recursive calls, PAP allocation, and cache modes."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FPR = ROOT / 'fpr'
EXPECTED = ('map: [2, 3, 4, 5]\ncapture: [11, 12, 13, 14]\npipeline: 12\nsort: [1, 2, 3, 4]\nshadow: 903\n'
            'alias shadow: 40\nmutual: 40\ncapture-effect\nargument-effect\neffects: 12\ndynamic: 12\n')


def run(args, env, timeout=120, code=0):
    p = subprocess.run(list(map(str, args)), cwd=ROOT, env=env, text=True,
                       capture_output=True, timeout=timeout)
    assert p.returncode == code, (args, p.returncode, p.stdout, p.stderr)
    return p


def main():
    with tempfile.TemporaryDirectory(prefix='fpr-specialization-') as tmp:
        tmp = Path(tmp)
        env = {**os.environ, 'XDG_CACHE_HOME': str(tmp / 'cache'),
               'SOL_CACHE_DIR': str(tmp / 'sol-cache'), 'SOL_JIT': '0', 'SOL_GPU': '0'}
        run(['make', 'fpr'], env, timeout=300)
        print(run(['cabal', 'exec', '--', 'runghc', '-w', '-icompiler',
                   'tests/Specialization.hs'], env).stdout, end='')
        for setting, no_inline in (('0', '0'), ('1', '0'), ('0', '0'), ('0', '1'), ('1', '1')):
            mode = {**env, 'FPR_NO_SPEC': setting, 'FPR_NO_INLINE': no_inline}
            exe = tmp / 'native'
            source = ROOT / 'tests/base/specialization.fpr'
            run([FPR, 'build', source, '-o', exe], mode)
            native = run([exe], mode)
            sol = run([FPR, 'sol', source], mode)
            assert native.stdout == sol.stdout == EXPECTED, (setting, native.stdout, sol.stdout)
            assert not native.stderr and not sol.stderr, (native.stderr, sol.stderr)
            allocation = run([FPR, 'run', ROOT / 'tests/base/specialization_alloc.fpr'], mode).stdout
            assert allocation == f'total 507500; callback bytes {64000 if setting == "1" else 0}\n', allocation
            # Preserve strict effects and panics in the callback argument,
            # before a later argument is evaluated.
            panic = tmp / 'panic.fpr'
            panic.write_text('unsafe base.\nadd k x = k + x.\napply f x = f x.\n'
                             'later = _ = print "WRONG"; 3.\n'
                             'main = print (apply (add (error "capture panic")) later).\n')
            p = run([FPR, 'run', panic], mode, code=1)
            assert 'capture panic' in p.stdout + p.stderr and 'PANIC' in p.stdout + p.stderr and 'WRONG' not in p.stdout, (p.stdout, p.stderr)
            p = run([FPR, 'sol', panic], mode, code=1)
            assert 'capture panic' in p.stdout + p.stderr and 'WRONG' not in p.stdout, (p.stdout, p.stderr)
        # Inspect native IR for every supported backend. The witness's clones
        # must contain only direct calls (generic original exports remain).
        for target in ('rv64', 'rv32', 'a64', 'x64'):
            out = tmp / f'{target}.s'
            p = run([FPR, 'compile', f'--target={target}',
                     'tests/base/specialization_alloc.fpr', out], {**env, 'FPRC_APPLY': '1', 'FPR_NO_SPEC': '0'})
            assert 'known-partial=0' in p.stderr, p.stderr
            asm = out.read_text()
            assert '.mono' in asm or '_2emono' in asm, target
        print('Specialization: native/Sol differential + warm mode caches, effects/panics, '
              '64,000 -> 0 callback bytes, RV64/RV32/A64/x64 emission: PASS')


if __name__ == '__main__':
    main()
