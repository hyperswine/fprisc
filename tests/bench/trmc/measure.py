#!/usr/bin/env python3
"""Paired, uninstrumented TRMC timing; validate every run and retain raw data.

Run from any directory. Builds finish before sampling starts. List fusion is
intentionally off to measure materialized lists. This is a throughput probe,
not a scheduling-latency qualification. Allocation gates live in check_trmc.py.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[3]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--samples', type=int, default=11)
    parser.add_argument('--elements', type=int, default=200_000)
    args = parser.parse_args()
    assert args.samples > 0 and args.elements > 0
    n = args.elements
    cases = {
        'map': (f'main = print (List.length (List.map (fn x -> x + 1) (List.range 1 {n}))).', n),
        'filter': (f'main = print (List.length (List.filter (fn x -> x <= {n // 2}) (List.range 1 {n}))).', n // 2),
        'append': (f'main = xs = List.range 1 {n}; ys = List.range 1 {n // 2}; print (List.length (List.append xs ys)).', n + n // 2),
    }
    flags = {'FPR_NO_LIST_FUSE': '1', 'FPR_HARTS': '1'}
    env = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
    env.update(flags, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT))
    records = []
    compiler_digest = hashlib.sha256((ROOT / 'fpr').read_bytes()).hexdigest()
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    dirty = bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True))
    with tempfile.TemporaryDirectory(prefix='fpr-trmc-bench-') as directory:
        tmp = Path(directory)
        for name, (body, answer) in cases.items():
            source = 'List = use "std/list".\n' + body + '\n'
            path = tmp / f'{name}.fpr'
            path.write_text(source)
            for mode in ('default', 'FPR_NO_SPEC', 'FPR_NO_INLINE'):
                row = {'case': name, 'mode': mode, 'source': source, 'expected_stdout': f'{answer}\n', 'variants': {}}
                for disabled in (False, True):
                    variant = 'off' if disabled else 'on'
                    run_env = dict(env, XDG_CACHE_HOME=str(tmp / f'cache-{name}-{mode}-{variant}'))
                    if mode != 'default':
                        run_env[mode] = '1'
                    if disabled:
                        run_env['FPR_NO_TRMC'] = '1'
                    exe = tmp / f'{name}-{mode}-{variant}'
                    command = [str(ROOT / 'fpr'), 'build', str(path), '--harts', '1', '-o', str(exe)]
                    compile_seconds = []
                    for _ in range(2):  # cold, then identical warm build
                        start = time.perf_counter()
                        made = subprocess.run(command, cwd=ROOT, env=run_env, capture_output=True, text=True, timeout=180)
                        compile_seconds.append(time.perf_counter() - start)
                        assert made.returncode == 0, (name, mode, variant, made.stdout, made.stderr)
                    row['variants'][variant] = {'compile_cold_warm_seconds': compile_seconds, 'executable_bytes': exe.stat().st_size,
                                                'seconds': [], '_exe': str(exe), '_env': run_env}
                records.append(row)
        for row in records:
            def execute(variant):
                data = row['variants'][variant]
                start = time.perf_counter()
                result = subprocess.run([data['_exe']], env=data['_env'], capture_output=True, text=True, timeout=60)
                elapsed = time.perf_counter() - start
                assert (result.returncode, result.stdout, result.stderr) == (0, row['expected_stdout'], ''), (row['case'], row['mode'], variant, result)
                return elapsed
            execute('on')
            execute('off')
            for i in range(args.samples):
                for variant in (('on', 'off') if i % 2 == 0 else ('off', 'on')):
                    row['variants'][variant]['seconds'].append(execute(variant))
            for data in row['variants'].values():
                data.pop('_exe')
                data.pop('_env')
                data['median_seconds'] = statistics.median(data['seconds'])
            row['median_speedup'] = row['variants']['off']['median_seconds'] / row['variants']['on']['median_seconds']
            print(f"{row['case']} {row['mode']}: {row['median_speedup']:.3f}x", flush=True)
    assert hashlib.sha256((ROOT / 'fpr').read_bytes()).hexdigest() == compiler_digest, 'compiler changed during measurement'
    output = {'revision': revision, 'dirty': dirty, 'compiler_sha256': compiler_digest,
              'host': platform.platform(), 'machine': platform.machine(), 'flags': flags, 'elements': n,
              'samples': args.samples, 'measurement': 'wall time including process startup; alternating pairs; one warmup per variant', 'results': records}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, indent=2) + '\n')


if __name__ == '__main__':
    main()
