#!/usr/bin/env python3
"""Paired, interleaved timings of the inline bump allocation
(docs/2026-11-03-INLINE-BUMP-ALLOC.md): each allocating unbox row built with
the fast path on (the default) and off (FPR_NO_BUMP_ALLOC=1), run alternately
(the order flips every round) RUNS times on one hart; prints JSON with every
sample, the medians, the median of the per-round on/off ratios, the outputs
(which must agree) and the __TEXT sizes.
usage: tests/bench/unbox/bump_pairs.py [RUNS] > bench/out.json
"""
from pathlib import Path
import json, os, platform, statistics, subprocess, sys, tempfile, time
ROOT = Path(__file__).resolve().parents[3]
HERE = ROOT / 'tests/bench/unbox'
RUNS = int(sys.argv[1]) if len(sys.argv) > 1 else 31
# row -> (source, extra build environment)
ROWS = {
    'list_fold': (HERE / 'list_fold.fpr', {}),
    'list_length_rev': (HERE / 'list_length_rev.fpr', {}),
    'tree_sum': (HERE / 'tree_sum.fpr', {}),
    'list_map_unfused': (HERE / 'list_map.fpr', {'FPR_NO_LIST_FUSE': '1'}),
    'list_filter_unfused': (HERE / 'list_filter.fpr', {'FPR_NO_LIST_FUSE': '1'}),
    'actors': (ROOT / 'tests/bump_alloc/actors.fpr', {}),
}


def run(args, env):
    p = subprocess.run(list(map(str, args)), cwd=ROOT, env=env, text=True, capture_output=True, timeout=900)
    assert p.returncode == 0, (args, p.stdout[-2000:], p.stderr[-2000:])
    return p


def text_size(exe):
    return int(run(['size', exe], os.environ).stdout.split('\n')[1].split()[0])


with tempfile.TemporaryDirectory(prefix='fpr-bump-bench-') as d:
    tmp = Path(d)
    base = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
    base.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), FPR_HARTS='1', FPR_NO_RUN_CACHE='1')
    exes, info = {}, {}
    for row, (src, extra) in ROWS.items():
        for mode, menv in (('on', {}), ('off', {'FPR_NO_BUMP_ALLOC': '1'})):
            env = dict(base, XDG_CACHE_HOME=str(tmp / f'c-{mode}'), **extra, **menv)
            exe = tmp / f'{row}.{mode}'
            run([ROOT / 'fpr', 'build', src, '--harts', '1', '-o', exe], env)
            exes[(row, mode)] = exe
            info.setdefault(row, {})[f'text_bytes_{mode}'] = text_size(exe)
            info[row][f'output_{mode}'] = run([exe], base).stdout.strip()
        assert info[row]['output_on'] == info[row]['output_off'], (row, info[row])
    samples = {f'{row}:{mode}': [] for row, mode in exes}
    for i in range(RUNS):
        for row in ROWS:
            order = ('on', 'off') if i % 2 == 0 else ('off', 'on')
            for mode in order:
                t0 = time.perf_counter(); run([exes[(row, mode)]], base)
                samples[f'{row}:{mode}'].append(time.perf_counter() - t0)
    summary = {}
    for row in ROWS:
        on, off = samples[f'{row}:on'], samples[f'{row}:off']
        summary[row] = {'median_on_s': round(statistics.median(on), 4), 'median_off_s': round(statistics.median(off), 4),
                        'median_ratio_on_off': round(statistics.median(a / b for a, b in zip(on, off)), 4)}
    print(json.dumps({'platform': platform.platform(), 'machine': platform.machine(), 'runs': RUNS,
                      'summary': summary, 'fpr': info,
                      'samples_s': {k: [round(x, 5) for x in v] for k, v in samples.items()}}, indent=1))
