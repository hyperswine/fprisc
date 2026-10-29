#!/usr/bin/env python3
"""macOS x86-64 (Mach-O) target: emission, assembly and real-runtime execution.

`--target=x64mac` (fprc) and `fpr build --target=macos-x86_64` select the
typed x64 backend with Mach-O syntax: underscored C symbols, `L` private
labels, `__DATA,__const` data and Darwin TLV descriptors for the hart and the
argument seven/eight cells (docs/2026-10-24-X64-MACOS.md).

Emission and assembly need only a clang that targets x86-64. Execution needs
an x86-64 Mac or Rosetta. On Apple Silicon each program is also built for
the native AArch64 target, which is the oracle: same stdout and exit status.
On an Intel Mac the native build IS this target, so the program's own
assertions and exit status are the check, as in the rest of the Base suite.
"""
import argparse
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FPR = ROOT / 'fpr'

# Programs chosen for what they put through the TLV cells, each with
# deterministic output on any hart count: actor scheduling and hart migration
# (actors, mailbox, confine), arity 7, 8 and 9+ (widearity), stack-segment
# growth followed by a hart re-read (deep), the sized-frame reservation stage
# (bigframe), floats (float) and boxed 64-bit integers (i64).
PROGRAMS = ['actors', 'mailbox', 'confine', 'widearity', 'deep', 'bigframe', 'float', 'i64']

PROBE = '''unsafe program.
w10 a b c d e f g h i j = a + b * 2 + c * 3 + d * 4 + e * 5 + f * 6 + g * 7 + h * 8 + i * 9 + j * 10.
loop n acc = case n == 0 of True -> acc | False -> loop (n - 1) (acc + w10 n 1 2 3 4 5 6 7 8 9).
main = print "probe: {loop 1000 0}".
'''


def sh(args, env, cwd=ROOT, timeout=600, check=True):
    p = subprocess.run(list(map(str, args)), cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)
    if check and p.returncode != 0:
        raise SystemExit(f'FAIL: {" ".join(map(str, args))} exited {p.returncode}\n{p.stdout[-3000:]}\n{p.stderr[-3000:]}')
    return p


def x86_runner():
    if platform.system() != 'Darwin':
        return None
    if platform.machine() == 'x86_64':
        return 'native x86-64'
    if subprocess.run(['arch', '-x86_64', '/usr/bin/true'], capture_output=True).returncode == 0:
        return 'Rosetta x86-64'
    return None


def emission(tmp, env):
    src = tmp / 'probe.fpr'
    src.write_text(PROBE)
    out = tmp / 'emit' / 'probe.s'
    out.parent.mkdir()
    strict = dict(env, FPR_TYPED_IR_STRICT='all')
    sh([FPR, 'compile', '--system=posix', '--target=x64mac', f'--prelude={ROOT}/core/prelude.fpr', src, out], strict)
    units = [Path(u) for u in (out.parent / 'probe.s.units').read_text().split()]
    assert units and all('x64macr' in u.name for u in units), ('the Mach-O units need their own cache identity', units)
    texts = {p: p.read_text() for p in [out, *units]}
    for path, text in texts.items():
        assert '@tpoff' not in text and '%fs:' not in text, (path, 'ELF TLS in Mach-O output')
        assert '.section .rodata' not in text, (path, 'an ELF section name')
        assert not re.search(r'^\.Ltir_', text, re.M), (path, 'a .L label: Mach-O private labels are L')
        assert '_fpr_posix_hart@TLVP(%rip)' in text, (path, 'no TLV descriptor read of the hart')
    root = texts[out]
    assert re.search(r'^_fpr_fn_w10:', root, re.M) and re.search(r'^_fpr_fn_loop:', root, re.M), 'underscored function symbols'
    assert '_fpr_x64_a6@TLVP(%rip)' in root and '_fpr_x64_a7@TLVP(%rip)' in root, 'arguments seven and eight through their TLV cells'
    assert 'call _fpr_fuel_exhausted' in root, 'runtime calls take the underscore'
    for path in texts:
        sh(['clang', '-arch', 'x86_64', '-c', path, '-o', path.with_suffix('.o')], env)
    native = sum(1 for t in texts.values() for _ in re.finditer(r'^# fn ', t, re.M))
    print(f'x64mac emission: {native} typed functions in {len(texts)} files, TLV cells, Mach-O symbols and sections; assembled as x86-64 Mach-O: PASS')


def execution(tmp, env, runner):
    oracle = platform.machine() != 'x86_64'
    rows = []
    for name in PROGRAMS + ['probe']:
        prog = tmp / 'probe.fpr' if name == 'probe' else ROOT / 'tests' / f'{name}.fpr'
        exe = tmp / f'{name}-x64'
        sh([FPR, 'build', '--target=macos-x86_64', prog, '-o', exe], env)
        kind = sh(['file', exe], env).stdout
        assert 'Mach-O 64-bit executable x86_64' in kind, kind
        got = sh([exe], env, cwd=tmp, timeout=120, check=False)
        if oracle:
            ref_exe = tmp / f'{name}-a64'
            sh([FPR, 'build', prog, '-o', ref_exe], env)
            ref = sh([ref_exe], env, cwd=tmp, timeout=120, check=False)
            assert (got.returncode, got.stdout) == (ref.returncode, ref.stdout), \
                (name, 'differs from the AArch64 oracle', got.returncode, ref.returncode, got.stdout[-2000:], ref.stdout[-2000:], got.stderr[-2000:])
        else:
            assert got.returncode == 0, (name, got.returncode, got.stdout[-2000:], got.stderr[-2000:])
        if name == 'probe':
            assert got.stdout.strip() == 'probe: ' + str(sum(n + 1 * 2 + 2 * 3 + 3 * 4 + 4 * 5 + 5 * 6 + 6 * 7 + 7 * 8 + 8 * 9 + 9 * 10 for n in range(1, 1001))), got.stdout
        rows.append(f'{name} exit {got.returncode}')
    how = 'same stdout and status as the AArch64 build' if oracle else 'exit status and self-checks'
    print(f'x64mac execution ({runner}, real runtime and Darwin TLS, default harts): {", ".join(rows)}; {how}: PASS')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--require-execution', action='store_true', help='fail instead of skipping when x86-64 execution is unavailable')
    a = ap.parse_args()
    if platform.system() != 'Darwin' or shutil.which('clang') is None:
        print('x64mac: SKIP (needs macOS and clang)')
        return 0
    env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT))
    for k in ('FPR_FOREIGN', 'FPR_TYPED_IR', 'FPR_TYPED_IR_BACKEND', 'FPR_TYPED_IR_STRICT'):
        env.pop(k, None)
    with tempfile.TemporaryDirectory(prefix='fpr-x64mac-') as d:
        tmp = Path(d)
        env['XDG_CACHE_HOME'] = os.environ.get('XDG_CACHE_HOME', str(tmp / 'cache'))
        emission(tmp, env)
        runner = x86_runner()
        if runner is None:
            print('x64mac execution: SKIP (needs an x86-64 Mac or Rosetta)')
            return 1 if a.require_execution else 0
        execution(tmp, env, runner)
    return 0


if __name__ == '__main__':
    sys.exit(main())
