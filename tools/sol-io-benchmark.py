#!/usr/bin/env python3
"""Measure bounded copy/filter/digest/CSV throughput and RSS in fresh processes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--runs', type=int, default=2)
    ap.add_argument('--cases', nargs='+', choices=['copy','filter','digest','csv'], default=['copy','filter'])
    args = ap.parse_args()
    assert args.runs >= 1
    binary = ROOT / 'fpr'
    env = {k: v for k, v in os.environ.items() if not k.startswith('SOL_')}
    env |= {'SOL_GPU': '0', 'SOL_JIT': '0'}
    samples = []
    with tempfile.TemporaryDirectory(prefix='sol-io-memory-') as tmp:
        work = Path(tmp).resolve()
        env['SOL_CACHE_DIR'] = str(work / 'cache')
        source = work / 'input.log'
        output = work / 'output.bin'
        script = work / 'measure.sol'
        line_size = 65536
        keep = b'KEEP ' + b'x' * (line_size - 6) + b'\n'
        drop = b'DROP ' + b'x' * (line_size - 6) + b'\n'
        block = (keep + drop) * 8

        def measure(case, size, content, record):
            script.write_text(content)
            if output.exists():
                output.unlink()
            command = ['/usr/bin/time', '-l' if platform.system() == 'Darwin' else '-v',
                       str(binary), 'sol', str(script)]
            started = time.monotonic()
            p = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=env, timeout=180)
            wall = time.monotonic() - started
            assert p.returncode == 0, (case, size, p.stderr.decode())
            text = p.stderr.decode()
            if platform.system() == 'Darwin':
                found = re.search(r'(\d+)\s+maximum resident set size', text)
                rss = int(found[1]) if found else None
            else:
                found = re.search(r'Maximum resident set size \(kbytes\):\s*(\d+)', text)
                rss = int(found[1]) * 1024 if found else None
            assert rss is not None, text
            if case == 'copy':
                assert output.stat().st_size == size
                # Verify independently, incrementally, outside the measured child.
                def digest(path):
                    h = hashlib.sha256()
                    with path.open('rb') as f:
                        for data in iter(lambda: f.read(1024 * 1024), b''):
                            h.update(data)
                    return h.digest()
                assert digest(output) == digest(source)
            if record:
                samples.append({'case': case, 'input_bytes': size, 'peak_rss_bytes': rss,
                                'wall_seconds': wall, 'mib_per_second': size / 1024**2 / wall,
                                'command': command, 'source': content, 'stderr': text})
                print(f'{case}: {size} bytes, RSS {rss / 1024**2:.1f} MiB, {wall:.3f} s', flush=True)

        idle = '> print "idle".\n'
        measure('idle', 0, idle, False)
        for _ in range(args.runs):
            measure('idle', 0, idle, True)
        for size in (100 * 1024**2, 1024**3):
            source_digest = hashlib.sha256()
            with source.open('wb') as f:
                for _ in range(size // len(block)):
                    f.write(block)
                    source_digest.update(block)
            assert source.stat().st_size == size
            qsource = json.dumps(str(source))
            qoutput = json.dumps(str(output))
            cases = {
                'copy': f'> r = Fs.copyPublishNow {qsource} {qoutput} 65536 False;'
                        f' case r of Ok n -> (case n == {size} of True -> Unit | False -> error "copy size")'
                        ' | Err e -> error (str e).\n',
                'filter': 'pick needle n b = case Bytes.contains needle b of\n'
                          ' True -> u = unwrap (IO.stdout b); n + Bytes.len b\n| False -> n.\n'
                          f'> needle = unwrap (Utf8.encode "KEEP"); r = unwrap (Stream.openRead {qsource} 65536);'
                          ' (result,r2) = Stream.foldLines (pick needle) 0 65536 r; u = unwrap (Stream.closeRead r2);'
                          f' n = unwrap result; case n == {size // 2} of True -> Unit | False -> error "filter count".\n',
                'digest': f'> r = unwrap (Stream.openRead {qsource} 65536); (result,r2) = Sha256.stream r;'
                          ' u = unwrap (Stream.closeRead r2); hex = Hex.encode (unwrap result);'
                          f' case hex == "{source_digest.hexdigest()}" of True -> Unit | False -> error "digest mismatch".\n',
                'csv': 'countRows n row = n + 1.\n'
                       f'> r = unwrap (Stream.openRead {qsource} 65536);'
                       ' (result,r2) = Stream.foldCsv countRows 0 1 65536 65536 r; u = unwrap (Stream.closeRead r2);'
                       f' n = unwrap result; case n == {size // line_size} of True -> Unit | False -> error "CSV record count".\n',
            }
            for name in args.cases:
                content = cases[name]
                measure(name, size, content, False)
                for _ in range(args.runs):
                    measure(name, size, content, True)

    baseline = max(x['peak_rss_bytes'] for x in samples if x['case'] == 'idle')
    gates = {}
    for name in args.cases:
        small = max(x['peak_rss_bytes'] for x in samples if x['case'] == name and x['input_bytes'] == 100 * 1024**2)
        large = max(x['peak_rss_bytes'] for x in samples if x['case'] == name and x['input_bytes'] == 1024**3)
        delta = (large - baseline) - (small - baseline)
        gates[name] = {'small_peak_rss_bytes': small, 'large_peak_rss_bytes': large,
                       'idle_baseline_bytes': baseline, 'incremental_growth_bytes': delta,
                       'allowance_bytes': 32 * 1024**2, 'passed': delta <= 32 * 1024**2}
    report = {'schema': 1, 'platform': platform.platform(), 'machine': platform.machine(),
              'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
              'source_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
              'source_status': subprocess.check_output(['git', 'status', '--short'], cwd=ROOT, text=True),
              'source_files_sha256': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                  for p in [*sorted((ROOT / 'compiler/Sol').glob('*.hs')), ROOT / 'compiler/cbits/fsx.c',
                            ROOT / 'compiler/cbits/sol_digest.c', ROOT / 'sol/lib/digest.sol',
                            ROOT / 'fp-risc.cabal', ROOT / 'tools/sol-io-benchmark.py', ROOT / 'tools/sol-io-check.py']},
              'settings': {'SOL_JIT': '0', 'SOL_GPU': '0', 'chunk_bytes': 65536, 'line_limit_bytes': 65536,
                           'warmups': 1, 'runs': args.runs},
              'measurement': 'fresh child process via /usr/bin/time; macOS RSS bytes or Linux RSS KiB converted to bytes; warm compile cache; output to /dev/null',
              'samples': samples, 'gates': gates}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    assert all(g['passed'] for g in gates.values()), gates
    print(f'All selected 32 MiB growth gates passed. Report: {args.output}')


if __name__ == '__main__':
    main()
