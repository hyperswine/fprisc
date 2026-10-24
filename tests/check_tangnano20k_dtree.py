#!/usr/bin/env python3
"""Check the existing decision-tree classifier against an independent reference.

Without execution flags this computes only the Python reference. --hardware
builds the selected RV32IMC/RV64IMC image and uses UART readback/exit checks;
load the matching FPGA image first. --qemu uses the QEMU UART adapter instead.
--source-root permits an isolated committed
runtime snapshot when the primary checkout contains unrelated runtime edits.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def reference(train_rows, test_rows, bins, max_depth, min_leaf):
    def dataset(seed, n):
        values = []
        for _ in range(3 * n):
            seed = (1103515245 * seed + 12345) % 2147483648
            values.append(seed / 2147483648)
        x = [v * 2 - 1 for v in values[:n]]
        z = [v * 2 - 1 for v in values[n:2*n]]
        y = [int((a > 0) != (b > 0)) ^ int(noise < .05)
             for a, b, noise in zip(x, z, values[2*n:])]
        return x, z, y

    train, test = dataset(42, train_rows), dataset(7, test_rows)
    limits, codes = [], []
    for col in train[:2]:
        lo, hi = min(col), max(col)
        width = (hi - lo) / bins or 1.0
        limits.append((lo, width))
        codes.append([min(bins - 1, int((x - lo) / width)) for x in col])

    def entropy(counts):
        n = sum(counts)
        return -sum((c/n) * math.log2(c/n) for c in counts if c) if n else 0.0

    def build(rows, depth):
        counts = [sum(train[2][i] == k for i in rows) for k in range(2)]
        leaf = ('leaf', int(counts[1] > counts[0]))
        n = len(rows)
        parent = entropy(counts)
        if depth >= max_depth or n < 2 * min_leaf or parent == 0:
            return leaf
        best = None
        for col in range(2):
            hist = [[0, 0] for _ in range(bins)]
            for i in rows:
                hist[codes[col][i]][train[2][i]] += 1
            left = [0, 0]
            for threshold in range(bins - 1):
                left = [left[k] + hist[threshold][k] for k in range(2)]
                nl = sum(left)
                if nl < min_leaf or n - nl < min_leaf:
                    continue
                right = [counts[k] - left[k] for k in range(2)]
                gain = parent - ((nl/n) * entropy(left) + ((n-nl)/n) * entropy(right))
                # Equal gains retain the earlier bin and then earlier column.
                if best is None or gain > best[0]:
                    best = gain, col, threshold
        if best is None or best[0] < .001:
            return leaf
        _, col, threshold = best
        lo, width = limits[col]
        return ('split', col, lo + (threshold + 1) * width,
                build([i for i in rows if codes[col][i] <= threshold], depth + 1),
                build([i for i in rows if codes[col][i] > threshold], depth + 1))

    tree = build(list(range(train_rows)), 0)

    def predict(node, x, z):
        if node[0] == 'leaf':
            return node[1]
        return predict(node[3] if (x, z)[node[1]] < node[2] else node[4], x, z)

    def shape(node):
        if node[0] == 'leaf':
            return 1, 0
        a, b = shape(node[3]), shape(node[4])
        return 1 + a[0] + b[0], 1 + max(a[1], b[1])

    def score(data):
        predictions = [predict(tree, x, z) for x, z in zip(*data[:2])]
        digest = 0
        for p in predictions:
            digest = (digest * 257 + p + 1) % 1000003
        return {'hits': sum(p == y for p, y in zip(predictions, data[2])),
                'rows': len(predictions), 'digest': digest,
                'predictions_sha256': hashlib.sha256(bytes(predictions)).hexdigest()}

    nodes, depth = shape(tree)
    return {'train_rows': train_rows, 'test_rows': test_rows, 'bins': bins,
            'max_depth': max_depth, 'min_leaf': min_leaf, 'nodes': nodes,
            'depth': depth, 'train': score(train), 'test': score(test),
            'root': {'column': tree[1], 'threshold': tree[2]} if tree[0] == 'split' else {'leaf': tree[1]},
            'entropy': 'Independent Python math.log2; classifier uses its existing 48-step log2'}


def validate(output, expected):
    wanted = [f'DTREE BEGIN train={expected["train_rows"]} test={expected["test_rows"]} bins={expected["bins"]} depth={expected["max_depth"]} minLeaf={expected["min_leaf"]}',
              'DTREE DATA READY', f'DTREE nodes={expected["nodes"]} depth={expected["depth"]}']
    for tag in ('train', 'test'):
        row = expected[tag]
        wanted.append(f'DTREE {tag} hits={row["hits"]}/{row["rows"]} digest={row["digest"]}')
    for line in wanted:
        assert output.splitlines().count(line) == 1, (line, output)
    root = expected['root']
    if 'column' in root:
        found = re.search(r'^root split: col (\d+) @ ([^\n]+)$', output, re.M)
        assert found and int(found[1]) == root['column'], output
        assert math.isclose(float(found[2]), root['threshold'], rel_tol=1e-12, abs_tol=1e-12), output
    else:
        assert 'root: leaf\n' in output, output
    elapsed = re.search(r'^DTREE elapsed_us=(\d+)$', output, re.M)
    assert elapsed, output
    return int(elapsed[1])


def validate_runs(output, expected, repeats):
    runs = re.split(r'(?=^DTREE BEGIN )', output, flags=re.M)[1:]
    assert len(runs) == repeats, (len(runs), repeats, output)
    return [validate(run, expected) for run in runs]


def heap_samples(output):
    return [dict((key, int(value)) for key, value in re.findall(r'(\w+)=(\d+)', line))
            for line in output.splitlines() if line.startswith(('HEAP ', 'GC HEAP '))]


def execute(command, cwd, env, timeout, live=False):
    started = time.monotonic()
    process = subprocess.Popen([str(x) for x in command], cwd=cwd, env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    data = bytearray()
    try:
        while process.poll() is None:
            if time.monotonic() - started >= timeout:
                raise subprocess.TimeoutExpired(command, timeout)
            if select.select([process.stdout], [], [], .1)[0]:
                chunk = os.read(process.stdout.fileno(), 65536)
                data.extend(chunk)
                if live:
                    print(chunk.decode('utf-8', errors='replace'), end='', flush=True)
        tail = process.stdout.read()
        data.extend(tail)
        if live and tail:
            print(tail.decode('utf-8', errors='replace'), end='', flush=True)
    except subprocess.TimeoutExpired:
        process.send_signal(signal.SIGINT)
        try:
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()
        raise
    output = data.decode('utf-8', errors='replace')
    assert process.returncode == 0, output
    return output, time.monotonic() - started


def board_artifact(out):
    image = out / 'base.bin'
    symbols = subprocess.check_output(['riscv64-unknown-elf-nm', str(out / 'base.elf')], text=True)
    def symbol(name):
        return int(re.search(rf'^([0-9a-f]+) \w {name}$', symbols, re.M)[1], 16)
    low, high = (symbol('_heap_start') + 15) & ~15, symbol('_heap_end') & ~15
    bitmap = ((((high-low) // 16 + 7) // 8) + 15) & ~15
    return {'image_sha256': hashlib.sha256(image.read_bytes()).hexdigest(),
            'image_bytes': image.stat().st_size, 'heap_arena_bytes': high-low,
            'heap_bitmap_bytes': bitmap, 'usable_heap_block_bytes': high-low-bitmap,
            'stack_bytes': symbol('_stack_top')-symbol('_heap_end')}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--train', type=int, default=32)
    parser.add_argument('--test', type=int, default=16)
    parser.add_argument('--bins', type=int, default=4)
    parser.add_argument('--depth', type=int, default=3)
    parser.add_argument('--min-leaf', type=int, default=2)
    parser.add_argument('--hardware', action='store_true')
    parser.add_argument('--qemu', action='store_true')
    parser.add_argument('--xlen', type=int, choices=(32, 64), default=64)
    parser.add_argument('--native', action='store_true')
    parser.add_argument('--source-root', type=Path, default=ROOT)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--port', default='/dev/cu.usbserial-20250303171')
    parser.add_argument('--freq-mhz', type=int, default=27)
    parser.add_argument('--timeout', type=float, default=240)
    parser.add_argument('--bitstream', type=Path)
    parser.add_argument('--repeat', type=int, default=1, help='repeat inside one guest process and heap')
    args = parser.parse_args()
    if not 1 <= args.repeat <= 100:
        parser.error('--repeat must be in 1..100')
    if args.qemu and (args.hardware or args.xlen != 32):
        parser.error('--qemu currently requires --xlen 32 and excludes --hardware')
    if min(args.train, args.test, args.min_leaf, args.freq_mhz) < 1 or args.bins < 2 or not 1 <= args.depth <= 12 or not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error('positive sizes/clock/timeout, bins >= 2 and depth 1..12 required')
    expected = reference(args.train, args.test, args.bins, args.depth, args.min_leaf)
    print(json.dumps(expected, indent=2), flush=True)
    if not (args.hardware or args.native or args.qemu):
        return
    source_root = args.source_root.resolve()
    out = (args.output or ROOT / 'build/tangnano20k-dtree' /
           f'n{args.train}-t{args.test}-b{args.bins}-d{args.depth}').resolve()
    out.mkdir(parents=True, exist_ok=True)
    source = (ROOT / 'tests/tangnano20k_dtree.fpr').read_text()
    source = source.replace('D = use "dtree".', f'D = use "{source_root}/tests/dtree".')
    source, replacements = re.subn(r'main = run \d+ \d+ \d+ \d+ \d+\.',
                                  f'main = run {args.train} {args.test} {args.bins} {args.depth} {args.min_leaf}.', source)
    assert replacements == 1, 'classifier fixture main parameters were not found exactly once'
    if args.repeat > 1:
        call = f'run {args.train} {args.test} {args.bins} {args.depth} {args.min_leaf}'
        source = source.replace(f'main = {call}.',
            f'main = repeatRuns {args.repeat}.\n'
            'repeatRuns : unsafe Int -> Unit .\n'
            'repeatRuns 0 = Unit.\n'
            f'repeatRuns n = _ = {call}; repeatRuns (n - 1).')
    fixture = out / 'program.fpr'
    fixture.write_text(source)
    sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
    report = {'reference': expected, 'source_sha256': sha(fixture),
              'classifier_sha256': sha(source_root / 'tests/dtree.fpr'),
              'compiler_sha256': sha(source_root / 'fpr'), 'repeats': args.repeat, 'executions': {}}
    environment = {**os.environ, 'FPR_RVC': '1', 'FPR_XLEN': str(args.xlen), 'FPR_QEMU': str(int(args.qemu)), 'FPR_CPU_MHZ': str(args.freq_mhz),
                   'FPR_SOFTFLOAT_ROOT': os.environ.get('FPR_SOFTFLOAT_ROOT', str(ROOT / 'build/tangnano20k-softfloat'))}
    report['build_options']={key:environment.get(key,'0') for key in
                            ('FPR_XLEN','FPR_RVC','FPR_QEMU','FPR_CPU_MHZ','FPR_HEAP_REPORT')}
    try:
        if args.native:
            output, _ = execute([source_root / 'fpr', 'build', fixture, '-o', out / 'native'], source_root, environment, 180)
            (out / 'native-build.log').write_text(output)
            output, wall = execute([out / 'native'], source_root, environment, args.timeout)
            (out / 'native.log').write_text(output)
            times = validate_runs(output, expected, args.repeat)
            report['executions']['native'] = {'elapsed_us': times[-1], 'elapsed_us_runs': times, 'wall_seconds': wall, 'passed': True}
            print(output, flush=True)
        if args.hardware or args.qemu:
            output, _ = execute([source_root / 'machine/tangnano20k/build.sh', fixture, out], source_root, environment, 180)
            (out / 'board-build.log').write_text(output)
            image = out / 'base.bin'
            board = {**board_artifact(out), 'frequency_mhz': args.freq_mhz,
                     'isa': f'RV{args.xlen}IMC', 'passed': False}
            report['executions']['qemu' if args.qemu else 'board'] = board
            if args.qemu:
                from check_tangnano20k_rv32_base import run_image
                output = run_image(out / 'base.elf', out, args.timeout)
                (out / 'qemu.log').write_text(output)
                board['heap_samples'] = heap_samples(output)
                times = validate_runs(output, expected, args.repeat)
                board.update(elapsed_us=times[-1], elapsed_us_runs=times, heap_samples=heap_samples(output), passed=True)
                report['executions']['qemu'] = board
                print(output, flush=True)
                return
            if args.bitstream:
                board['bitstream_sha256'] = sha(args.bitstream)
            report['executions']['board'] = board
            print(f'Uploading {image.stat().st_size:,} bytes; execution timeout {args.timeout:g}s', flush=True)
            command = ['python3', '-u', ROOT / 'tools/run_tangnano20k_base.py', image,
                       '--root', out, '--port', args.port, '--freq-mhz', args.freq_mhz, '--timeout', args.timeout]
            output, wall = execute(command, ROOT, environment,
                                   args.timeout + image.stat().st_size * 8680 / (args.freq_mhz * 1e6) + 60, live=True)
            (out / 'board.log').write_text(output)
            board['heap_samples'] = heap_samples(output)
            assert 'FPR EXIT 0\n' in output and output.rstrip().endswith('DONE'), output
            times = validate_runs(output, expected, args.repeat)
            board.update(elapsed_us=times[-1], elapsed_us_runs=times, heap_samples=heap_samples(output), wall_seconds_with_upload=wall, passed=True)
    except BaseException as error:
        report['error'] = str(error)
        (out / 'failure.log').write_text(str(error) + '\n')
        raise
    finally:
        (out / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print('PASS: decision-tree shape, all prediction digests, hit counts and root split match the independent reference', flush=True)


if __name__ == '__main__':
    main()
