#!/usr/bin/env python3
"""Deterministic mutation fuzz smoke of `fpr check` (parser, inference,
exhaustiveness). A fixed seed mutates corpus files (byte deletions, token
insertions, duplications, character flips); a mutant must end with exit 0 or
1 and no Haskell exception. A run over a time limit is reported as slow but
only fails if over HANG seconds. FUZZ_N mutants (default 300; 2000 when
RELIABILITY_FULL=1), FUZZ_SEED (default 20261101). Failing mutants are kept
under $FUZZ_OUT (default build/fuzz-smoke) for minimization."""
import os, random, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
FULL = os.environ.get('RELIABILITY_FULL') == '1'
N = int(os.environ.get('FUZZ_N', '2000' if FULL else '300'))
SEED = int(os.environ.get('FUZZ_SEED', '20261101'))
HANG = 60
OUT = Path(os.environ.get('FUZZ_OUT', ROOT / 'build/fuzz-smoke')); OUT.mkdir(parents=True, exist_ok=True)
BAD = ('CallStack', 'Exception', 'error, called at', 'impossible', 'Prelude.', 'Non-exhaustive')
# large/slow inputs are excluded: the smoke must stay fast (vecwide.fpr alone checks for ~19 s)
SKIP = {'vecwide.fpr'}
corpus = sorted(p for g in ['tests/base/*.fpr', 'tests/edge/*.fpr', 'tests/cases/*.fpr', 'tests/*.fpr', 'std/*.fpr']
                for p in ROOT.glob(g) if p.name not in SKIP and p.stat().st_size < 40000)
TOKS = ['(', ')', '[', ']', '{', '}', '.', ';', '|', '->', '::', '=', 'case', 'of', 'fn', 'if', 'then', 'else', '"', '\\',
        '0', '-9223372036854775808', '99999999999999999999999', '@', '#', '\n', '`', 'unsafe', ':', '_', 'Type (A | B)', 'use "x"']
rng = random.Random(SEED)
def mutate(s):
    b = list(s)
    for _ in range(rng.randint(1, 4)):
        k = rng.random(); i = rng.randrange(len(b) + 1)
        if k < .3 and b: j = i % len(b); del b[j:j + rng.randint(1, 8)]
        elif k < .6: b[i:i] = list(rng.choice(TOKS))
        elif k < .8 and b: j = rng.randrange(len(b)); b[i:i] = b[j:j + rng.randint(1, 40)]
        elif b: b[i % len(b)] = chr(rng.randrange(32, 127))
    return ''.join(b)
jobs = []
for n in range(N):
    src = rng.choice(corpus); jobs.append((n, src, mutate(src.read_text(errors='replace'))))
with tempfile.TemporaryDirectory(prefix='fpr-fuzz-') as d:
    tmp = Path(d); env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=str(tmp / 'cache'))
    def run(job):
        n, src, text = job; f = tmp / f'm{n}.fpr'; f.write_text(text)
        try:
            p = subprocess.run([str(ROOT / 'fpr'), 'check', str(f)], capture_output=True, text=True, timeout=HANG, env=env, cwd=tmp)
        except subprocess.TimeoutExpired:
            return n, src, 'HANG', ''
        out = p.stdout + p.stderr
        if p.returncode not in (0, 1) or any(b in out for b in BAD): return n, src, 'CRASH', out[-1500:]
        return n, src, 'ok', ''
    with ThreadPoolExecutor(os.cpu_count() or 4) as ex: res = list(ex.map(run, jobs))
    bad = [r for r in res if r[2] != 'ok']
    for n, src, kind, out in bad:
        keep = OUT / f'{kind.lower()}-seed{SEED}-m{n}.fpr'; keep.write_text(jobs[n][2])
        print(f'{kind} mutant {n} of {src.relative_to(ROOT)} -> {keep}\n{out}')
print(f'fuzz smoke: {N} mutants (seed {SEED}), {len(bad)} failures')
sys.exit(1 if bad else 0)
