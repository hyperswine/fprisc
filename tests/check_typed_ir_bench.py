#!/usr/bin/env python3
"""Every function the typed IR lowers in the bench corpus, run natively
(docs/2026-10-21-TYPED-IR-COVERAGE.md): each tests/bench/<name>.fpr with a
.expected output is built on this host with FPR_TYPED_IR_BACKEND=mixed into
a fresh private cache, so every unit it needs (the root, the prelude, the
std units) goes through the typed-IR backend function by function, and the
program's stdout must equal its .expected, byte for byte.  The report
counts the functions that went native per program.  Nothing is timed and
no performance claim is made; a program whose build fails or whose output
differs fails the check."""
import os, re, subprocess, sys, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
BENCH = ROOT / 'tests' / 'bench'
ENV = {**os.environ, 'FPR_HOME': str(ROOT), 'FPR_PATH': str(ROOT), 'FPR_TYPED_IR_BACKEND': 'mixed'}
for k in ('FPR_FOREIGN', 'FPR_TYPED_IR', 'FPR_TYPED_IR_STRICT'):
    ENV.pop(k, None)

def main():
    subprocess.run(['make', 'fpr'], cwd=ROOT, check=True, capture_output=True)
    names = sys.argv[1:] or sorted(p.stem for p in BENCH.glob('*.fpr') if (BENCH / f'{p.stem}.expected').exists())
    failures = []
    total_native = total_fns = 0
    for n in names:
        with tempfile.TemporaryDirectory(prefix=f'fpr-tir-bench-{n}-') as d:
            env = {**ENV, 'XDG_CACHE_HOME': str(Path(d) / 'cache')}
            exe = Path(d) / n
            b = subprocess.run([str(ROOT / 'fpr'), 'build', str(BENCH / f'{n}.fpr'), '-o', str(exe), '-v'],
                               cwd=ROOT, env=env, capture_output=True, text=True, timeout=900)
            if b.returncode != 0:
                failures.append(n); print(f'{n}: BUILD FAILED\n{(b.stdout + b.stderr)[-2000:]}'); continue
            native = fns = 0
            for m in re.finditer(r'typed-ir-backend: native (\d+)/(\d+) functions', b.stdout + b.stderr):
                native += int(m.group(1)); fns += int(m.group(2))
            p = subprocess.run([str(exe)], capture_output=True, text=True, timeout=600)
            want = (BENCH / f'{n}.expected').read_text()
            if p.returncode != 0 or p.stdout != want:
                failures.append(n)
                print(f'{n}: OUTPUT DIFFERS (exit {p.returncode})\n  got  {(p.stdout + p.stderr)[-500:]!r}\n  want {want!r}')
                continue
            total_native += native; total_fns += fns
            print(f'{n}: {native}/{fns} functions native (per-function mode), output equals .expected')
    if failures:
        print(f'typed-ir bench differential: FAIL ({", ".join(failures)})')
        return 1
    print(f'typed-ir bench differential: {len(names)} programs, {total_native}/{total_fns} functions native, every output equal to .expected: PASS')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
