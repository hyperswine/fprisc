#!/usr/bin/env python3
"""C2 cost against explicit monomorphic twins; no timing-based pass/fail.

The twins print the same constants and consume the same raw/managed values.
Require equal assembled code bytes and the same number of functions.
Measure GHC allocation/residency and cold compile time separately, for selected
problem sizes. The compiler-allocation comparison has the existing 10% margin
from check_compile_budget, rather than a new clone or machine-code size cap.
Host-specific absolute allocation baselines catch regressions shared by both
forms. Residency is reported, not gated: the smallest case may not trigger a
major collection from which GHC could measure a meaningful live heap.
"""
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
from check_compile_budget import ALLOCATION_MARGIN, environment

ROOT = Path(__file__).resolve().parents[1]
BASELINE = ROOT / 'tests' / 'type_spec_cost_budget.json'


def source(count, generic):
    definitions, calls = [], []
    for i in range(count):
        if generic:
            definitions.append(f'f{i} x = _ = print {i}; x.')
            integer = word = f'f{i}'
        else:
            integer, word = f'i{i}', f'w{i}'
            definitions.extend([f'{integer} : Int -> Int.', f'{integer} x = _ = print {i}; x.',
                                f'{word} : Word -> Word.', f'{word} x = _ = print {i}; x.'])
        calls.extend([f'_ = print ({integer} {i})', f'_ = print (Word.toInt ({word} (Word.fromInt {i})))'])
    return '\n'.join(definitions) + '\nmain = ' + '; '.join(calls) + '; Unit.\n'


def measure(tmp, count, generic):
    label = f'{count}-' + ('generic' if generic else 'explicit')
    path, output, stats = (tmp / (label + suffix) for suffix in ('.fpr', '.s', '.rts'))
    path.write_text(source(count, generic))
    env = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
    env.update(XDG_CACHE_HOME=str(tmp / ('cache-' + label)), FPR_HOME=str(ROOT))
    env.pop('GHCRTS', None)
    start = time.monotonic()
    result = subprocess.run([ROOT / 'fpr', 'compile', '--system=bare-metal', '--profile=builtin', '--arc', path, output,
                             '+RTS', f'-t{stats}', '--machine-readable', '-RTS'], cwd=ROOT, env=env,
                            capture_output=True, text=True, timeout=180)
    elapsed = time.monotonic() - start
    assert result.returncode == 0, result.stdout + result.stderr
    rts = dict(ast.literal_eval(stats.read_text().split('\n', 1)[1]))
    asm = output.read_text()
    obj = tmp / (label + '.o')
    subprocess.run(['riscv64-unknown-elf-gcc', '-march=rv64imafdc_zicsr', '-mabi=lp64',
                    '-c', output, '-o', obj], check=True, capture_output=True)
    sizes = subprocess.check_output(['riscv64-unknown-elf-size', '-A', obj], text=True)
    text_bytes = sum(int(n) for n in re.findall(r'^\.text(?:\.\S+)?\s+(\d+)', sizes, re.M))
    functions = len(re.findall(r'^# fn ', asm, re.M))
    assert text_bytes and functions, sizes
    return dict(allocated_bytes=int(rts['bytes allocated']), max_bytes_used=int(rts['max_bytes_used']),
                wall_seconds=round(elapsed, 4), text_bytes=text_bytes, functions=functions)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--record', type=Path)
    parser.add_argument('--sizes', type=int, nargs='+', default=[16,32,64])
    parser.add_argument('--require-baseline', action='store_true')
    args = parser.parse_args()
    if any(n <= 0 for n in args.sizes):
        parser.error('sizes must be positive')
    rows = []
    host = environment()
    baseline = json.loads(BASELINE.read_text()).get(host, {})
    with tempfile.TemporaryDirectory(prefix='fpr-type-spec-cost-') as directory:
        tmp = Path(directory)
        for count in args.sizes:
            generic = measure(tmp, count, True)
            explicit = measure(tmp, count, False)
            assert generic['text_bytes'] == explicit['text_bytes'], (count, generic, explicit)
            assert generic['functions'] == explicit['functions'], (count, generic, explicit)
            assert generic['allocated_bytes'] <= explicit['allocated_bytes'] * (1 + ALLOCATION_MARGIN), (count, generic, explicit)
            # The twin comparison alone would also accept a shared compiler
            # regression. Keep an absolute, host-specific cost gate as well.
            expected = baseline.get(str(count))
            if expected:
                for form, got in [('generic', generic), ('explicit', explicit)]:
                    assert got['allocated_bytes'] <= expected[form]['allocated_bytes'] * (1 + ALLOCATION_MARGIN), (count, form, got, expected[form])
            elif args.require_baseline:
                raise AssertionError(f'no C2 compile-cost baseline for {host}, {count} helpers')
            else:
                print(f'{count} helpers: no absolute baseline for {host}; twin gate only', flush=True)
            rows.append(dict(helpers=count, generic=generic, explicit=explicit))
            print(f"{count} helpers: same {generic['text_bytes']} code bytes/{generic['functions']} functions; "
                  f"compiler allocation {generic['allocated_bytes']/explicit['allocated_bytes']:.3f}x explicit twins", flush=True)
    if args.record:
        args.record.write_text(json.dumps(dict(compiler_sha256=hashlib.sha256((ROOT / 'fpr').read_bytes()).hexdigest(),
                                              environment=host, target='rv64imafdc_zicsr/lp64', cold_cache=True,
                                              allocation_margin=ALLOCATION_MARGIN, rows=rows), indent=2) + '\n')


if __name__ == '__main__':
    main()
