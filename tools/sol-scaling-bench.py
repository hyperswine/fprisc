#!/usr/bin/env python3
"""Sol compile-phase scaling on synthetic inputs (not a CI check: wall clock).

  tools/sol-scaling-bench.py [./fpr] [family,...]

Families: wide (N one-line functions), chain (N functions calling the
previous), seq (N `> print i.` lines), case (one N-arm case). Prints each
SOL_TIMINGS phase at N = 200..3200 with the log-log exponent of the last
doubling; ~1 is linear, ~2 quadratic. Fresh cache per run.
"""
import math, os, re, subprocess, sys, tempfile
NS = [200, 400, 800, 1600, 3200]
GEN = {
  'wide': lambda n: "".join(f"f{i} x = x + {i}.\n" for i in range(n)) + "> print (f0 1).\n",
  'chain': lambda n: "f0 x = x + 1.\n" + "".join(f"f{i} x = f{i-1} (x + 1).\n" for i in range(1, n)) + f"> print (f{n-1} 1).\n",
  'seq': lambda n: "".join(f"> print {i}.\n" for i in range(n)),
  'case': lambda n: "g x = case x of\n    0 -> 0\n" + "".join(f"  | {i} -> {i*2}\n" for i in range(1, n)) + "  | _ -> 1.\n> print (g 3).\n",
}
fpr = sys.argv[1] if len(sys.argv) > 1 else './fpr'
fams = sys.argv[2].split(',') if len(sys.argv) > 2 else list(GEN)
tmp = tempfile.mkdtemp()
for fam in fams:
  rows = {}
  for n in NS:
    path = os.path.join(tmp, f'{fam}{n}.sol'); open(path, 'w').write(GEN[fam](n))
    env = dict(os.environ, SOL_TIMINGS='1', XDG_CACHE_HOME=tempfile.mkdtemp())
    r = subprocess.run([fpr, 'sol', path], capture_output=True, text=True, env=env)
    for m in re.finditer(r'\[sol timing\] (\S+): ([\d.]+) ms', r.stderr):
      rows.setdefault(m[1], []).append(float(m[2]))
  for ph in ['parse', 'typecheck', 'specialize', 'layout', 'lower', 'bytecode', 'startup']:
    t = rows.get(ph, [])
    if len(t) == len(NS):
      ex = math.log(max(t[-1], 1e-3) / max(t[-2], 1e-3)) / math.log(2)
      print(f"{fam:6} {ph:10} " + ' '.join(f'{x:8.1f}' for x in t) + f"  exp {ex:.2f}")
