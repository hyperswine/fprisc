#!/usr/bin/env python3
"""Warm-filesystem fresh-process baselines; no performance pass/fail thresholds."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=ROOT / 'fpr')
    parser.add_argument('--runs', type=int, default=10)
    parser.add_argument('--warmups', type=int, default=2)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.runs < 1 or args.warmups < 0:
        parser.error('runs must be positive and warmups nonnegative')
    binary = args.binary.resolve()
    env = {k: v for k, v in os.environ.items() if not k.startswith('SOL_')}
    env.update(SOL_JIT='0', SOL_GPU='0', SOL_CACHE='0')
    def git(*command):
        return subprocess.check_output(['git', '-C', str(ROOT), *command], text=True).strip()
    with tempfile.TemporaryDirectory(prefix='sol-benchmark-') as tmp:
        work = Path(tmp)
        cases = {
            'hello': ('> print "hello".\n', b'hello\n'),
            'process_one': ('> r = Proc.query (ProcessSpec ["/usr/bin/true"] "" [] "" 1000); print "done".\n', b'done\n'),
            'sum_10000': ('sum : unsafe Int -> Int -> Int.\nsum n acc | n == 0 = acc.\nsum n acc = sum (n - 1) (acc + n).\n> print "{sum 10000 0}".\n', b'50005000\n'),
        }
        # Real library expansion plus generated nested patterns at increasing sizes.
        cases['imports'] = ('p = use "' + str(ROOT / 'sol/lib/proc.sol') + '".\nj = use "' + str(ROOT / 'sol/lib/csv.sol') + '".\n> print "imported".\n', b'imported\n')
        for size in (2, 4, 8):
            arms = ' | '.join(f'({i}, {i}) -> {i}' for i in range(size))
            cases[f'patterns_{size}'] = (f'choose p = case p of {arms} | _ -> -1.\n> print "{{choose ({size-1}, {size-1})}}".\n', f'{size-1}\n'.encode())
        paths = {}
        for name, (source, _) in cases.items():
            paths[name] = work / (name + '.sol')
            paths[name].write_text(source)
        samples = {name: [] for name in cases}
        rng = random.Random(0)
        for round_index in range(args.warmups + args.runs):
            order = list(cases)
            rng.shuffle(order)
            for name in order:
                start = time.perf_counter_ns()
                result = subprocess.run([str(binary), 'sol', str(paths[name])], capture_output=True, env=env, timeout=60)
                elapsed = (time.perf_counter_ns() - start) / 1e6
                if result.returncode or result.stdout != cases[name][1] or result.stderr:
                    raise RuntimeError((name, result.returncode, result.stdout, result.stderr))
                if round_index >= args.warmups:
                    samples[name].append(elapsed)
        report = {
            'schema': 1, 'timestamp_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
            'binary': str(binary), 'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
            'source_head': git('rev-parse', 'HEAD'), 'source_status': git('status', '--short'),
            'source_diff_sha256': hashlib.sha256(subprocess.check_output(['git', '-C', str(ROOT), 'diff', 'HEAD'])).hexdigest(),
            'source_files_sha256': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((ROOT / 'compiler').rglob('*')) if p.suffix in ('.hs', '.c', '.h')},
            'cabal_file': (ROOT / 'fp-risc.cabal').read_text(),
            'platform': platform.platform(), 'machine': platform.machine(),
            'settings': {'SOL_JIT': '0', 'SOL_GPU': '0', 'SOL_CACHE': '0', 'warmups': args.warmups, 'runs': args.runs, 'shuffle_seed': 0},
            'measurement': 'fresh processes, warm filesystem, captured output; interpreter only; wall time includes startup, compilation and execution',
            'limitations': 'No isolated VM timings, phase timings, cold-cache control, allocation or peak-memory measurements. Source metadata does not prove binary provenance; rebuild immediately before recording.',
            'cases': {name: {'source': cases[name][0], 'expected_stdout_hex': cases[name][1].hex(), 'samples_ms': values,
                             'median_ms': statistics.median(values), 'min_ms': min(values), 'max_ms': max(values)}
                      for name, values in samples.items()},
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + '\n')
        for name, values in samples.items():
            print(f'{name:20} {statistics.median(values):9.2f} ms median')
        print(f'Report: {args.output.resolve()}')


if __name__ == '__main__':
    main()
