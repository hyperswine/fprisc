#!/usr/bin/env python3
"""Unboxing proposal benchmarks (docs/2026-11-01-UNBOXING-ZERO-OVERHEAD-PROPOSAL.md).

Builds every tests/bench/unbox/*.fpr under each optimisation mode, a probe
build (FPR_COST_PROBE) for allocation counts, the C (gcc -O2) and, if ghc is
on PATH, Haskell (ghc -O2) references; then runs all executables interleaved
RUNS times (default 15) and prints JSON with medians. Wall clock of the whole
process (includes startup; see the empty/sol_empty rows).
usage: tests/bench/unbox/measure.py [RUNS] > out.json
"""
from pathlib import Path
import json, os, platform, shutil, statistics, subprocess, sys, tempfile, time, re
ROOT = Path(__file__).resolve().parents[3]
HERE = ROOT / 'tests/bench/unbox'
RUNS = int(sys.argv[1]) if len(sys.argv) > 1 else 15
FPR = ['list_sum', 'loop_sum', 'list_map', 'list_filter', 'list_fold', 'list_length_rev',
       'option_loop', 'tuple_loop', 'tree_sum', 'string_scan']
MODES = {'default': {}, 'no_reuse': {'FPR_NO_REUSE': '1'}, 'no_spec_inline': {'FPR_NO_SPEC': '1', 'FPR_NO_INLINE': '1'}}
C = {'list_sum': ['cons_sum', 'arr_sum'], 'list_map': ['cons_map'], 'list_filter': ['cons_filter'],
     'list_fold': ['cons_fold'], 'list_length_rev': ['cons_rev'], 'option_loop': ['option'],
     'tuple_loop': ['tuple'], 'tree_sum': ['tree'], 'string_scan': ['scan']}
CARGS = {'option': '20000000 1', 'tuple': '20000000 1', 'tree': '20 10', 'scan': '1048576 20'}
HS = {'list_sum': 'sum', 'list_map': 'map', 'list_filter': 'filter', 'list_fold': 'fold',
      'list_length_rev': 'rev', 'option_loop': 'option', 'tuple_loop': 'tuple', 'tree_sum': 'tree'}

def run(args, env=None, **kw):
    p = subprocess.run(list(map(str, args)), cwd=ROOT, env=env, text=True, capture_output=True, timeout=600, **kw)
    assert p.returncode == 0, (args, p.stdout[-2000:], p.stderr[-2000:])
    return p

def text_size(exe):
    out = run(['size', exe]).stdout.split('\n')[1].split()
    return int(out[0])

with tempfile.TemporaryDirectory(prefix='fpr-unbox-') as d:
    tmp = Path(d); base = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), FPR_HARTS='1')
    jobs = {}; info = {}
    (tmp / 'empty.fpr').write_text('main = print "empty".\n')
    for mode, extra in MODES.items():
        env = dict(base, XDG_CACHE_HOME=str(tmp / ('c-' + mode)), **extra)
        for b in FPR + ['empty']:
            src = tmp / 'empty.fpr' if b == 'empty' else HERE / (b + '.fpr')
            if mode != 'default' and b == 'empty': continue
            exe = tmp / f'{b}.{mode}'
            run([ROOT / 'fpr', 'build', src, '--harts', '1', '-o', exe], env)
            jobs[f'fpr:{mode}:{b}'] = [exe]
            info.setdefault(b, {})[f'text_bytes_{mode}'] = text_size(exe)
            if mode == 'default':
                penv = dict(env, FPR_COST_PROBE='1', XDG_CACHE_HOME=str(tmp / 'c-probe'))
                pexe = tmp / f'{b}.probe'
                run([ROOT / 'fpr', 'build', src, '--harts', '1', '-o', pexe], penv)
                p = run([pexe], dict(base, FPR_COST_REPORT='1'))
                m = re.search(r'\[fpr cost\] (\{.*\})', p.stderr)
                info[b]['output'] = p.stdout.strip()
                info[b]['probe'] = json.loads(m.group(1)) if m else None
    run(['gcc', '-O2', '-o', tmp / 'ref_c', HERE / 'ref.c'])
    for b, ms in C.items():
        for m in ms:
            jobs[f'c:{m}'] = [tmp / 'ref_c', m] + CARGS.get(m, '1000000 20').split()
    jobs['c:empty'] = [tmp / 'ref_c', 'none', '1', '1']
    ghc = shutil.which('ghc') or next((str(p) for p in [Path.home() / '.ghcup/bin/ghc'] if p.exists()), None)
    if ghc:
        run([ghc, '-O2', '-rtsopts', HERE / 'ref.hs', '-outputdir', tmp / 'hs', '-o', tmp / 'ref_hs'])
        for b, m in HS.items():
            jobs[f'hs:{m}'] = [tmp / 'ref_hs', m, '+RTS', '-s', '-RTS']
    for s in ['sol_loop', 'sol_scalar', 'sol_empty']:
        jobs[f'sol:{s}'] = [ROOT / 'fpr', 'sol', HERE / (s + '.sol')]
    samples = {k: [] for k in jobs}; hsalloc = {}
    for i in range(RUNS):
        for k, cmd in jobs.items():
            t0 = time.perf_counter(); p = run(cmd, base); samples[k].append(time.perf_counter() - t0)
            if k.startswith('hs:') and i == 0:
                m = re.search(r'([\d,]+) bytes allocated in the heap', p.stderr)
                hsalloc[k] = int(m.group(1).replace(',', '')) if m else None
    print(json.dumps({'platform': platform.platform(), 'runs': RUNS,
                      'median_s': {k: round(statistics.median(v), 4) for k, v in samples.items()},
                      'min_s': {k: round(min(v), 4) for k, v in samples.items()},
                      'fpr': info, 'hs_alloc_bytes': hsalloc}, indent=1))
