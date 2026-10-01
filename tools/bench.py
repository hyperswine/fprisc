#!/usr/bin/env python3
"""The native performance ratchet (docs/2026-09-30-SUGGESTIONS.md, section 1.7).

Each tests/bench/<name>.fpr is built once with `fpr build` and its executable
is run --runs times; the FASTEST run is the score (a desktop's background load
only ever adds time, and it moved medians by 50% on a 2-thread benchmark),
and the median is reported beside it.  A run's stdout must
equal tests/bench/<name>.expected (a code-generation change that speeds a
benchmark up by computing something else is a failure, not a win).

  tools/bench.py                 compare against bench/baseline.json
                                 (exit 1 when any benchmark is > --slack slower)
  tools/bench.py --record        write the medians as the new baseline
  tools/bench.py --bless         rewrite the .expected outputs
  tools/bench.py fib sha         only these benchmarks

The baseline is per machine: it records the host it was measured on, and a
comparison on a different host only reports."""
import argparse, json, os, platform, statistics, subprocess, sys, tempfile, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BENCH = ROOT / 'tests' / 'bench'
BASE = ROOT / 'bench' / 'baseline.json'

def host():
    return f'{platform.system()}-{platform.machine()}-{platform.node().split(".")[0]}'

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('names', nargs='*')
    ap.add_argument('--runs', type=int, default=7)
    ap.add_argument('--slack', type=float, default=0.10)
    ap.add_argument('--record', action='store_true')
    ap.add_argument('--bless', action='store_true')
    a = ap.parse_args()
    subprocess.run(['make', 'fpr'], cwd=ROOT, check=True, capture_output=True)
    names = a.names or sorted(p.stem for p in BENCH.glob('*.fpr'))
    base = json.loads(BASE.read_text()) if BASE.exists() else {}
    same_host = base.get('host') == host()
    results, bad = {}, []
    with tempfile.TemporaryDirectory(prefix='fpr-bench-') as t:
        for n in names:
            exe = Path(t) / n
            b = subprocess.run([str(ROOT / 'fpr'), 'build', str(BENCH / f'{n}.fpr'), '-o', str(exe)],
                               capture_output=True, text=True)
            if b.returncode != 0:
                print(f'{n}: BUILD FAILED\n{b.stdout}{b.stderr}'); bad.append(n); continue
            times, out = [], None
            for _ in range(a.runs):
                t0 = time.perf_counter()
                p = subprocess.run([str(exe)], capture_output=True, text=True, timeout=600)
                times.append(time.perf_counter() - t0)
                if p.returncode != 0:
                    print(f'{n}: exit {p.returncode}\n{p.stdout}{p.stderr}'); bad.append(n); break
                out = p.stdout
            else:
                want = BENCH / f'{n}.expected'
                if a.bless or not want.exists():
                    want.write_text(out)
                elif out != want.read_text():
                    print(f'{n}: OUTPUT CHANGED\n  got  {out!r}\n  want {want.read_text()!r}'); bad.append(n); continue
                med = statistics.median(times)
                best = min(times)
                results[n] = round(best, 4)
                old = base.get('times', {}).get(n)
                note = ''
                if old:
                    ratio = best / old
                    note = f'  x{1 / ratio:.2f} vs baseline' if ratio < 1 else f'  {ratio:.2f}x baseline'
                    if same_host and ratio > 1 + a.slack and not a.record:
                        note += '  <-- SLOWER'; bad.append(n)
                print(f'{n:10} {best * 1000:9.1f} ms  (median {med * 1000:.1f}){note}')
    if a.record:
        BASE.parent.mkdir(exist_ok=True)
        merged = base.get('times', {}) if same_host else {}
        merged.update(results)
        BASE.write_text(json.dumps({'host': host(), 'times': merged}, indent=2, sort_keys=True) + '\n')
        print(f'recorded {BASE.relative_to(ROOT)} for {host()}')
    elif base and not same_host:
        print(f'(baseline is from {base.get("host")}; this is {host()}: reported, not enforced)')
    if bad:
        print('FAILED: ' + ', '.join(bad)); sys.exit(1)

main()
