#!/usr/bin/env python3
"""Regress soft-float vector map/filter/fold, mixed records and F32 kernels.

Build cold/warm RV64IM and IMC images without F/D, retaining integer vector
specialization. Execute the same fixture natively with float kernels enabled
and disabled. This does not access the FPGA or UART.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, default=ROOT)
    args = parser.parse_args()
    source_root = args.source_root.resolve()
    out = ROOT / 'build/tangnano20k-softfloat-vectors'
    out.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix='run-', dir=out))
    fixture = out / 'program.fpr'
    fixture.write_text((ROOT / 'tests/base/veckinds.fpr').read_text())
    environment = {**os.environ, 'FPR_SOFTFLOAT_ROOT': os.environ.get(
        'FPR_SOFTFLOAT_ROOT', str(ROOT / 'build/tangnano20k-softfloat'))}

    def run(command, env):
        p = subprocess.run([str(x) for x in command], cwd=source_root,
                           env=env, capture_output=True, text=True, timeout=180)
        assert p.returncode == 0, p.stdout + p.stderr
        return p.stdout

    for compressed in (False, True):
        target = out / ('imc' if compressed else 'im')
        env = {**environment, 'FPR_RVC': str(int(compressed))}
        for pass_number in range(2):
            log = run([source_root / 'machine/tangnano20k/build.sh', fixture, target], env)
            if pass_number == 0:
                assert 'software-float mode' in log, 'missing float-kernel fallback diagnostic'
            assembly = '\n'.join(p.read_text() for p in target.rglob('*.s'))
            assert '# ---- Vec specializations' in assembly, 'integer kernels were disabled too'
            assert 'fmv.d.x' not in assembly and 'fmv.w.x' not in assembly, 'native float clone leaked'
            if pass_number == 0:
                image = (target / 'base.bin').read_bytes()
            else:
                assert image == (target / 'base.bin').read_bytes(), 'warm-cache image changed'
        print(f'PASS: RV64IM{"C" if compressed else ""} soft-float vectors, cold/warm ISA and integer specialization', flush=True)
    expected = 'kinds: floats=11.5 mixed=12 pipeline=4,38 f32=8\n'
    for disabled in (False, True):
        env = {**environment, 'FPR_NO_F64_INLINE': str(int(disabled))}
        binary = out / f'native-{int(disabled)}'
        run([source_root / 'fpr', 'build', fixture, '-o', binary], env)
        assert run([binary], env) == expected
    print('PASS: native floating kernels and generic C callbacks return identical mixed-kind results', flush=True)


if __name__ == '__main__':
    main()
