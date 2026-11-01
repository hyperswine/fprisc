#!/usr/bin/env python3
"""Optimization-configuration differential: each program is built under every
configuration below and must print exactly its .expected output (so all
configurations agree). Representative subset on PRs; every no-argument
tests/std program when RELIABILITY_FULL=1 (nightly). Configurations share
nothing but the compiler; each gets its own cache."""
import os, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
CONFIGS = {
    'default': {}, 'no_interval': {'FPR_NO_INTERVAL': '1'}, 'no_inline': {'FPR_NO_INLINE': '1'},
    'no_spec': {'FPR_NO_SPEC': '1'}, 'no_reuse': {'FPR_NO_REUSE': '1'},
    'no_workers': {'FPR_NO_SCALAR_WORKERS': '1', 'FPR_NO_FIELD_WORKERS': '1'},
    'no_vec': {'FPR_NO_VEC_FUSE': '1', 'FPR_NO_VEC_FAST': '1', 'FPR_NO_VEC_SIMD': '1'},
    'no_str': {'FPR_NO_STR_FAST': '1'}, 'no_regions': {'FPR_NO_LOOP_REGIONS': '1', 'FPR_NO_CALL_REGIONS': '1'},
    'harts4': {'FPR_HARTS': '4'},
}
# programs that need arguments, files or environment from tests/check_std.py
NEEDS_HARNESS = {'store', 'storewire', 'storeconc', 'durable', 'posix', 'apps'}
SUBSET = ['list', 'string', 'map', 'json', 'foundation', 'codec', 'ifelse', 'pagination']  # sorting, strings, trees, parsing, ADTs, codecs: wide pass coverage per build
full = os.environ.get('RELIABILITY_FULL') == '1'
progs = sorted(p.stem for p in (ROOT / 'tests/std').glob('*.expected')
               if p.stem not in NEEDS_HARNESS and (ROOT / 'tests/std' / (p.stem + '.fpr')).exists()) if full else SUBSET
with tempfile.TemporaryDirectory(prefix='fpr-configs-') as d:
    tmp = Path(d)
    def job(a):
        name, cfg = a
        env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=str(tmp / f'cache-{cfg}'), **CONFIGS[cfg])
        env.pop('FPR_CC', None)
        exe = tmp / f'{name}.{cfg}'
        b = subprocess.run([str(ROOT / 'fpr'), 'build', str(ROOT / 'tests/std' / f'{name}.fpr'), '-o', str(exe)],
                           cwd=ROOT, env=env, capture_output=True, text=True, timeout=1200)
        if b.returncode: return name, cfg, f'BUILD FAILED\n{b.stdout[-1500:]}{b.stderr[-1500:]}'
        wd = tmp / f'wd-{name}-{cfg}'; wd.mkdir()
        r = subprocess.run([str(exe)], cwd=wd, env=env, capture_output=True, text=True, timeout=600)
        want = (ROOT / 'tests/std' / f'{name}.expected').read_text()
        if r.returncode or r.stdout != want: return name, cfg, f'exit {r.returncode}; output differs\n{r.stdout[-800:]}{r.stderr[-800:]}'
        return name, cfg, None
    with ThreadPoolExecutor(int(os.environ.get('CONFIG_JOBS', str(max(2, (os.cpu_count() or 4)))))) as ex:
        res = list(ex.map(job, [(n, c) for c in CONFIGS for n in progs]))
bad = [r for r in res if r[2]]
for name, cfg, why in bad: print(f'MISMATCH {name} under {cfg}: {why}')
print(f'config differential: {len(progs)} programs x {len(CONFIGS)} configurations, {len(bad)} mismatches')
sys.exit(1 if bad else 0)
