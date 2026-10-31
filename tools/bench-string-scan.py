#!/usr/bin/env python3
"""Reproducible paired StringScan experiment; build everything before timing.

Example: python3 tools/bench-string-scan.py --output /tmp/scan-bench --runs 15
Optional --baseline-compiler checks every fixture against a saved compiler.
The pass is isolated: early loops on, loop motion off in both measured modes.
"""
import argparse
import ast
import hashlib
import json
import os
import platform
import random
import re
import statistics
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def units(cache):
    """{unit key: (sha256, {fn: header})} for every compiled unit in a mode's
    cache, keyed without the flag-dependent cache suffix, so off/on pair up"""
    out = {}
    for path in sorted((cache / 'fpr/build/units').glob('*.s')):
        key = path.name.split('-pd')[0] if path.name.startswith('u-') else path.name.split('-ccore')[0]
        heads = {l.split()[2]: l for l in path.read_text().splitlines() if l.startswith('# fn ')}
        out[key] = (sha(path), heads)
    return out


def library_delta(off_cache, on_cache):
    """units and functions whose emitted code differs between the modes"""
    a, b = units(off_cache), units(on_cache)
    changed = {}
    for key in sorted(set(a) | set(b)):
        if a.get(key, (None,))[0] != b.get(key, (None,))[0]:
            fa, fb = a.get(key, (None, {}))[1], b.get(key, (None, {}))[1]
            changed[key] = sorted(f for f in set(fa) | set(fb) if fa.get(f) != fb.get(f))
    return changed


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--runs', type=int, default=15)
    ap.add_argument('--baseline-compiler', type=Path)
    args = ap.parse_args()
    assert args.runs > 0
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), FPR_HARTS='1',
               FPR_TYPED_IR_EARLY_LOOPS='1', FPR_TYPED_IR_LOOP_MOTION='0')
    for key in ('FPR_TYPED_IR', 'FPR_FOREIGN', 'FPR_NO_INLINE', 'FPR_NO_STR_FAST', 'FPR_NO_INTERVAL'):
        env.pop(key, None)
    fixtures = {}
    for name in ('byteloop', 'sha', 'helpers', 'floatcmp'):
        source = (ROOT / 'tests/bench' / f'{name}.fpr').read_text()
        if name == 'byteloop':
            source = source.replace('rounds s 50 0', 'rounds s 500 0')
        elif name == 'sha':
            source = source.replace('1048576', '10485760')
        else:
            source = source.replace('10000000', '100000000')
        fixtures[name + '-long'] = source
    # Expose dispatch overhead on tiny scans as well as a large streaming loop.
    fixtures['short-scan'] = fixtures['byteloop-long'].replace('String.repeat 100000', 'String.repeat 1').replace('rounds s 500 0', 'rounds s 5000000 0')
    # A partial scan with a nonzero initial index tests the actual range contract.
    fixtures['partial-scan'] = fixtures['byteloop-long'].replace('sumB s 0 (strlen s) 0', 'sumB s 17 (strlen s - 19) 0')
    report = {'platform': platform.platform(), 'machine': platform.machine(), 'runs': args.runs,
              'harts': 1, 'compiler_sha256': sha(ROOT / 'fpr'),
              'baseline_sha256': sha(args.baseline_compiler) if args.baseline_compiler else None,
              'settings': {k: v for k, v in env.items() if k.startswith('FPR_')},
              'method': 'Two warmups; paired off/on runs with seeded balanced randomized order. All compilation ends before timing. Exact output checked on every run. Early loops enabled in both modes; loop motion disabled.',
              'source_sha256': {str(p.relative_to(ROOT)): sha(p) for p in sorted((ROOT / 'compiler').rglob('*.hs'))},
              'benchmarks': {}}

    def run(cmd, settings, timeout=300):
        p = subprocess.run([str(a) for a in cmd], cwd=ROOT, env=settings, capture_output=True, text=True, timeout=timeout)
        assert p.returncode == 0, (cmd, p.stdout[-3000:], p.stderr[-5000:])
        return p.stdout

    exes, outputs = {}, {}
    for name, text in fixtures.items():
        folder = out / name
        folder.mkdir(exist_ok=True)
        source = folder / 'input.fpr'
        source.write_text(text)
        row = {'source': text, 'source_sha256': sha(source), 'modes': {}}
        for mode in ('off', 'on'):
            directory = folder / mode
            directory.mkdir(exist_ok=True)
            settings = dict(env, FPR_TYPED_IR_STRING_SCAN=str(int(mode == 'on')), XDG_CACHE_HOME=str(directory / 'cache'))
            stats = directory / 'compile.rts'
            asm = directory / 'compile.s'
            start = time.perf_counter()
            run([ROOT / 'fpr', 'compile', '--system=posix', source, asm, '+RTS', f'-t{stats}', '--machine-readable', '-RTS'], settings)
            compile_s = time.perf_counter() - start
            rts = dict(ast.literal_eval(stats.read_text().split('\n', 1)[1]))
            exe = directory / 'program'
            run([ROOT / 'fpr', 'build', source, '--harts', '1', '-o', exe], settings)
            exes[name, mode] = exe
            output = run([exe], env)
            if name in outputs:
                assert output == outputs[name], (name, mode)
            outputs[name] = output
            row['modes'][mode] = {'samples_ms': [], 'compile_s': compile_s,
                                   'allocated_bytes': int(rts['bytes allocated']), 'binary_bytes': exe.stat().st_size,
                                   'assembly_sha256': sha(asm), 'binary_sha256': sha(exe),
                                   'scan_header': next((l for l in asm.read_text().splitlines() if l.startswith('# fn sumB ')), None)}
        # Whole-program identity: the root assembly can match while linked
        # library units (std/string, ...) differ between the modes.
        off_m, on_m = row['modes']['off'], row['modes']['on']
        row['root_assembly_identical'] = off_m['assembly_sha256'] == on_m['assembly_sha256']
        row['binary_identical'] = off_m['binary_sha256'] == on_m['binary_sha256']
        row['changed_units'] = library_delta(folder / 'off' / 'cache', folder / 'on' / 'cache')
        if row['root_assembly_identical'] and not row['binary_identical']:
            print(f'{name}: NOTE root assembly identical but the executables differ; changed library code: {row["changed_units"]}', flush=True)
        if args.baseline_compiler:
            exe = folder / 'saved-compiler-program'
            settings = dict(env, FPR_TYPED_IR_STRING_SCAN='0', XDG_CACHE_HOME=str(folder / 'saved-cache'))
            run([args.baseline_compiler, 'build', source, '--harts', '1', '-o', exe], settings)
            assert run([exe], env) == outputs[name], name
            row['saved_compiler_output_verified'] = True
        row['expected_stdout'] = outputs[name]
        report['benchmarks'][name] = row
        print(f'{name}: builds and output oracle ready', flush=True)
    for name in fixtures:
        for _ in range(2):
            for mode in ('off', 'on'):
                assert run([exes[name, mode]], env) == outputs[name]
        orders = [i % 2 for i in range(args.runs)]
        random.Random(20261031).shuffle(orders)
        row = report['benchmarks'][name]
        row['order'] = []
        for order in orders:
            modes = ('off', 'on') if order == 0 else ('on', 'off')
            row['order'].append(list(modes))
            for mode in modes:
                start = time.perf_counter()
                output = run([exes[name, mode]], env)
                elapsed = (time.perf_counter() - start) * 1000
                assert output == outputs[name]
                row['modes'][mode]['samples_ms'].append(elapsed)
        off = row['modes']['off']['samples_ms']
        on = row['modes']['on']['samples_ms']
        ratios = [b / a for a, b in zip(off, on)]
        row['paired_on_off_ratios'] = ratios
        row['paired_wins'] = sum(b < a for a, b in zip(off, on))
        row['median_paired_reduction_pct'] = 100 * (1 - statistics.median(ratios))
        for mode in ('off', 'on'):
            row['modes'][mode]['median_ms'] = statistics.median(row['modes'][mode]['samples_ms'])
        (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        print(f'{name}: {row["paired_wins"]}/{args.runs} wins; paired median reduction {row["median_paired_reduction_pct"]:.2f}%', flush=True)


if __name__ == '__main__':
    main()
