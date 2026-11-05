#!/usr/bin/env python3
"""Measure private product returns separately from instrumented allocation counts.

Default optimization settings, one hart, alternating on/off execution order.
Timing is informational; no machine-dependent speed threshold is a test gate.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'tests'))
from check_product_returns import expected, fixture, run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--record', required=True, type=Path)
    parser.add_argument('--count', default=500000, type=int)
    parser.add_argument('--samples', default=13, type=int)
    parser.add_argument('--target', choices=['macos-x86_64'])
    args = parser.parse_args()
    if args.count <= 0 or args.samples <= 0:
        parser.error('count and samples must be positive')
    env = {k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
    env.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), FPR_HARTS='1')
    rows = []
    with tempfile.TemporaryDirectory(prefix='fpr-product-bench-') as directory:
        tmp = Path(directory)
        env['XDG_CACHE_HOME'] = str(tmp/'cache')
        for width in (3,4,8):
            source = tmp/f'width{width}.fpr'; source.write_text(fixture(width, args.count))
            executables, ledgers = {}, {}
            for enabled in (False, True):
                mode = 'on' if enabled else 'off'
                settings = dict(env, **({} if enabled else {'FPR_NO_PAIR_RETURNS':'1'}))
                for probe in (False, True):
                    exe = tmp/f'width{width}-{mode}-{probe}'
                    settings_probe = dict(settings, **({'FPR_COST_PROBE':'1', 'FPR_COST_REPORT':'1'} if probe else {}))
                    p = run([ROOT/'fpr', 'build', *(['--target='+args.target] if args.target else []), source, '--harts', '1', '-o', exe], settings_probe)
                    assert p.returncode == 0, p.stderr[-5000:]
                    p = run([exe], settings_probe)
                    assert p.returncode == 0 and p.stdout == str(expected(width,args.count))+'\n', p
                    if probe:
                        line = next(line for line in p.stderr.splitlines() if line.startswith('[fpr cost] '))
                        ledgers[mode] = json.loads(line[len('[fpr cost] '):])
                    else:
                        executables[mode] = exe
            samples = {'on':[], 'off':[]}
            for i in range(args.samples):
                for mode in (('off','on') if i%2 == 0 else ('on','off')):
                    start = time.perf_counter_ns()
                    p = run([executables[mode]], env)
                    elapsed = (time.perf_counter_ns()-start)/1e6
                    assert p.returncode == 0 and p.stdout == str(expected(width,args.count))+'\n', p
                    samples[mode].append(elapsed)
            row = dict(width=width, count=args.count, allocation_ledgers=ledgers, milliseconds=samples,
                       median_ms={k:statistics.median(v) for k,v in samples.items()},
                       wins=sum(on<off for on,off in zip(samples['on'],samples['off'])))
            rows.append(row)
            print(json.dumps({k:v for k,v in row.items() if k not in ('milliseconds','allocation_ledgers')}), flush=True)
    report = dict(compiler_sha256=hashlib.sha256((ROOT/'fpr').read_bytes()).hexdigest(),
                  head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
                  working_tree='uncommitted', platform=platform.platform(), target=args.target or platform.machine(),
                  controls={'harts':1,'optimizer':'default','rollback':'FPR_NO_PAIR_RETURNS=1',
                            'timing':'uninstrumented process wall time, alternating order',
                            'allocations':'separate FPR_COST_PROBE binaries; includes region adapters'},
                  samples=args.samples, rows=rows)
    args.record.parent.mkdir(parents=True,exist_ok=True)
    args.record.write_text(json.dumps(report,indent=2)+'\n')


if __name__ == '__main__':
    main()
