#!/usr/bin/env python3
"""Fast local x64 execution suite: native Intel or macOS Rosetta, no Linux VM."""
import argparse
import os
import sys
import time
from x64_probe import ROOT, host, run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--require-execution', action='store_true',
                        help='fail instead of skipping when x64 execution is unavailable')
    args = parser.parse_args()
    target = host()
    if target is None:
        print('Local x64 execution unavailable: needs native x86-64 or macOS Rosetta')
        return 1 if args.require_execution else 0
    _, _, label = target
    env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT))
    env.pop('FPR_FOREIGN', None)
    env.pop('FPR_TYPED_IR', None)
    env['FPR_TYPED_IR_BACKEND'] = 'mixed'
    env.pop('FPR_TYPED_IR_STRICT', None)
    started = time.monotonic()
    run(['make', 'fpr'], env)
    for test in ('check_x64_scalar.py', 'check_self_loop_x64.py', 'check_x64_vectors.py'):
        begin = time.monotonic()
        print(run([sys.executable, ROOT / 'tests' / test], env), end='', flush=True)
        if test == 'check_x64_scalar.py':
            print(run([sys.executable, ROOT / 'tests' / test, '--qos'], env), end='', flush=True)
        print(f'{test}: {time.monotonic()-begin:.2f}s', flush=True)
    print(f'Local x64 suite ({label}): PASS in {time.monotonic()-started:.2f}s including build check')
    print('Evidence: adapted generated instructions and C oracles; not Linux TLS, actor scheduling or native x86 performance.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
