#!/usr/bin/env python3
"""Every A64 context switch keeps d8..d15, QOS apps included.

The reduction of QOS tests/qsysfail.fpr check 12 at 4 harts
(docs/2026-11-06-QOSAPP-A64-FP-CONTEXT.md): tests/ctx_a64_fp.c parks one
context 1000 times and resumes it on the next of 4 threads each time.

  - machine/unix/ctx_a64.S as hosted posix builds assemble it, and as QOS
    apps do (-DFPR_POSIX -DFPR_QOSAPP), must keep every register;
  - the old integer-only sequence (FPR_CTX_A64_BENCH_INTEGER) must lose
    them, so the harness is not vacuous;
  - runtime/fpr.h must give QOS A64 apps a 24-word context and their own
    native ABI numbers.
"""
import platform
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VARIANTS = (('hosted', [], 0), ('qosapp', ['-DFPR_POSIX', '-DFPR_QOSAPP'], 0),
            ('integer-only', ['-DFPR_CTX_A64_BENCH_INTEGER'], 1))


def defines(flags):
    p = subprocess.run(['clang', '-dM', '-E', '-x', 'c', '-DFPR_NHARTS=4', *flags,
                        '-include', str(ROOT / 'runtime/fpr.h'), '-'],
                       input='', capture_output=True, text=True, timeout=60, check=True)
    return {m[1]: int(m[2]) for m in re.finditer(r'^#define (FPR_CTX_WORDS|FPR_NATIVE_ABI) (\d+)u?$', p.stdout, re.M)}


def main():
    if platform.machine() not in ('arm64', 'aarch64'):
        print('check_ctx_a64_fp: skipped (needs native AArch64)')
        return
    hosted = defines(['-DFPR_POSIX'])
    qos = defines(['-DFPR_POSIX', '-DFPR_QOSAPP'])
    legacy_qos = defines(['-DFPR_POSIX', '-DFPR_QOSAPP', '-DFPR_LEGACY_CELLS'])
    assert hosted['FPR_CTX_WORDS'] == 24 and qos['FPR_CTX_WORDS'] == 24, (hosted, qos)
    assert qos['FPR_NATIVE_ABI'] == 16 and legacy_qos['FPR_NATIVE_ABI'] == 15, (qos, legacy_qos)  # x27 is the fuel counter
    failures = []
    with tempfile.TemporaryDirectory(prefix='fpr-ctx-a64-fp-') as d:
        for name, flags, lose in VARIANTS:
            exe = Path(d) / name
            # -ffixed-x27 with -ffixed-x28, as every C file that switches is
            # built: the switch saves neither (x27 is the fuel counter)
            subprocess.run(['clang', '-O2', '-ffixed-x27', '-ffixed-x28', '-pthread', *flags,
                            str(ROOT / 'tests/ctx_a64_fp.c'), str(ROOT / 'tests/ctx_a64_fp.S'),
                            str(ROOT / 'machine/unix/ctx_a64.S'), '-o', str(exe)], check=True, timeout=120)
            for run in range(3):
                p = subprocess.run([str(exe)], capture_output=True, text=True, timeout=60)
                line = p.stdout.strip()
                print(f'check_ctx_a64_fp: {name} run {run + 1}: {line}')
                if lose and (p.returncode == 0 or not line.startswith('lost:')):
                    failures.append(f'{name}: the integer-only switch kept d8..d15, so the check is vacuous')
                if not lose and (p.returncode != 0 or not line.startswith('ok:')):
                    failures.append(f'{name}: {line or p.stderr.strip()}')
    if failures:
        print('\n'.join(failures))
        sys.exit(1)
    print('check_ctx_a64_fp: all variants passed')


if __name__ == '__main__':
    main()
