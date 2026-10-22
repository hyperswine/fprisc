#!/usr/bin/env python3
"""Typed-IR lowering coverage over tests/bench (docs/2026-10-21-TYPED-IR-COVERAGE.md).

Each tests/bench/<name>.fpr is built with FPR_TYPED_IR=1 into a fresh,
private build cache, so every unit the program needs (the root, the prelude,
the std units) is compiled in this invocation and reports its lowering.
The report is summed per program: functions lowered, functions emitted, and
the fallback reasons with the names they mention removed, most frequent
first.  Nothing is executed and no performance is measured.

  tools/typed_ir_coverage.py              every program with a .expected file
  tools/typed_ir_coverage.py fib sha      named programs
  tools/typed_ir_coverage.py --json out   also write the raw counts
"""
import argparse, collections, json, os, re, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BENCH = ROOT / 'tests' / 'bench'

# a reason with its names and numbers removed, so the same form counts once
def shape(reason):
    r = re.sub(r'`[^`]*`', '`_`', reason)
    r = re.sub(r'\b\d+\b', 'N', r)
    return r

def measure(name, keep_cache=None):
    with tempfile.TemporaryDirectory(prefix='fpr-tir-cov-') as d:
        env = {**os.environ, 'FPR_HOME': str(ROOT), 'FPR_PATH': str(ROOT), 'FPR_TYPED_IR': '1',
               'XDG_CACHE_HOME': keep_cache or str(Path(d) / 'cache')}
        for k in ('FPR_FOREIGN', 'FPR_TYPED_IR_BACKEND', 'FPR_TYPED_IR_STRICT'):
            env.pop(k, None)
        env['FPR_TYPED_IR_BACKEND'] = 'legacy' # the report is over the legacy emission, as before the default changed
        p = subprocess.run([str(ROOT / 'fpr'), 'build', str(BENCH / f'{name}.fpr'), '-o', str(Path(d) / name), '-v'],
                           cwd=ROOT, env=env, capture_output=True, text=True, timeout=900)
        if p.returncode != 0:
            return None, (p.stdout + p.stderr)[-2000:]
    lowered = emitted = 0
    reasons = collections.Counter()
    examples = {}
    for line in (p.stdout + p.stderr).splitlines():
        m = re.match(r'typed-ir: coverage (\d+)/(\d+) functions', line)
        if m:
            lowered += int(m.group(1)); emitted += int(m.group(2))
            continue
        m = re.match(r'typed-ir: (\S+) fallback: (.*)', line)
        if m:
            s = shape(m.group(2))
            reasons[s] += 1
            examples.setdefault(s, m.group(1))
    return {'lowered': lowered, 'emitted': emitted, 'reasons': reasons, 'examples': examples}, None

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('names', nargs='*')
    ap.add_argument('--json', help='write the raw counts here')
    ap.add_argument('--top', type=int, default=8, help='reasons shown per program')
    a = ap.parse_args()
    subprocess.run(['make', 'fpr'], cwd=ROOT, check=True, capture_output=True)
    names = a.names or sorted(p.stem for p in BENCH.glob('*.fpr') if (BENCH / f'{p.stem}.expected').exists())
    out = {}
    total = collections.Counter()
    for n in names:
        r, err = measure(n)
        if r is None:
            print(f'{n}: build failed\n{err}', file=sys.stderr)
            continue
        out[n] = {'lowered': r['lowered'], 'emitted': r['emitted'], 'reasons': dict(r['reasons'])}
        total.update(r['reasons'])
        top = ', '.join(f'{c} {s}' for s, c in r['reasons'].most_common(a.top))
        print(f'{n}: {r["lowered"]}/{r["emitted"]} functions lowered; {top}')
    print('all programs, reasons summed:')
    for s, c in total.most_common():
        print(f'  {c:5d} {s}')
    if a.json:
        Path(a.json).write_text(json.dumps(out, indent=1, sort_keys=True))

if __name__ == '__main__':
    main()
