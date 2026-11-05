#!/usr/bin/env python3
"""Native Base helper throughput, with ordinary inlining/regions/fuel intact."""
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'tests'))
from check_base_products import loop
from check_base_product_trees import NUMERIC, numeric_source, explicit_source
from check_finite_field_workers import fixture as finite_fixture
from check_product_returns import fixture as return_fixture


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--baseline-compiler', type=Path, required=True)
    ap.add_argument('--shape', choices=['single', *(name for name, (_, _, _, remaining) in NUMERIC.items() if remaining == 0)], default='single')
    ap.add_argument('--finite-kind', choices=['depth', 'parameters', 'body'])
    ap.add_argument('--unary-return', action='store_true')
    ap.add_argument('--compile-cost', action='store_true', help='measure cold RV64 compiler allocation and root text size (automatic for unary returns)')
    ap.add_argument('--amount', type=int, default=8)
    ap.add_argument('--count', type=int, default=20_000_000)
    ap.add_argument('--samples', type=int, default=13)
    ap.add_argument('--record', type=Path, required=True)
    args = ap.parse_args()
    assert args.count > 0 and args.samples > 0 and args.amount > 0
    assert not (args.unary_return and args.finite_kind)
    rows, builds = [], {}
    with tempfile.TemporaryDirectory(prefix='fpr-base-product-bench-') as directory:
        tmp = Path(directory)
        base = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
        base.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=str(tmp/'cache'))
        expected = str(args.count*(args.count+1)//2 if args.unary_return else
                       finite_fixture(args.finite_kind, args.amount, args.count)[1] if args.finite_kind else args.count*32)+'\n'

        def unary_source(explicit):
            if not explicit:
                return return_fixture(1,args.count)
            return ('unsafe base.\nmake : unsafe Int -> Int .\n'
                    'make n = if n < 0 then make (0 - n) else n.\n'
                    'loop : unsafe Int -> Int -> Int .\n'
                    'loop n acc = if n == 0 then acc else loop (n - 1) (acc + make n).\n'
                    f'main = print (loop {args.count} 0).\n')

        def run(command, env):
            p = subprocess.run(command, cwd=ROOT, env=env, text=True, capture_output=True, timeout=180)
            assert p.returncode == 0, (list(map(str, command)), p.stdout[-2000:], p.stderr[-5000:])
            return p

        for name, compiler, explicit, switches in [
                ('before', args.baseline_compiler.resolve(), False, {}),
                ('after', ROOT/'fpr', False, {}),
                ('explicit', ROOT/'fpr', True, {}),
                ('rollback', ROOT/'fpr', False, {'FPR_NO_PAIR_RETURNS' if args.unary_return else 'FPR_NO_FIELD_WORKERS':'1'})]:
            source = tmp/(name+'.fpr')
            source.write_text(unary_source(explicit) if args.unary_return else
                              finite_fixture(args.finite_kind,args.amount,args.count,explicit)[0] if args.finite_kind else
                              loop(args.count, explicit) if args.shape == 'single' else
                              (explicit_source if explicit else numeric_source)(args.shape, args.count))
            env = dict(base, **switches)
            probe = tmp/(name+'-probe')
            probeenv = dict(env, FPR_COST_PROBE='1', FPR_COST_REPORT='1', FPR_HARTS='1')
            run([compiler, 'build', source, '--harts', '4', '-o', probe], probeenv)
            p = run([probe], probeenv)
            assert p.stdout == expected, p
            cost = json.loads(re.search(r'\[fpr cost\] (\{.*\})', p.stderr)[1])
            assert (cost['alloc_requests'] >= args.count) if name in ('before', 'rollback') else (cost['alloc_requests'] == 0), (name, cost)
            exe = tmp/name
            run([compiler, 'build', source, '--harts', '4', '-o', exe], env)
            builds[name] = exe, dict(env, FPR_HARTS='1')
            compile_cost = None
            if args.compile_cost or args.unary_return:
                cold = tmp/('cold-'+name); cold.mkdir()
                cost_source = cold/'main.fpr'; cost_source.write_text(source.read_text())
                asm, stats, obj = cold/'out.s', cold/'rts', cold/'out.o'
                costenv = dict(env, XDG_CACHE_HOME=str(cold/'cache'))
                costenv.pop('GHCRTS',None)
                start = time.perf_counter()
                run([compiler,'compile','--system=posix','--target=rv64',cost_source,asm,
                     '+RTS','-t'+str(stats),'--machine-readable','-RTS'],costenv)
                seconds = time.perf_counter()-start
                rts = dict(ast.literal_eval(stats.read_text().split('\n',1)[1]))
                run(['riscv64-unknown-elf-gcc','-march=rv64imafdc_zicsr','-mabi=lp64','-c',asm,'-o',obj],costenv)
                sizes = run(['riscv64-unknown-elf-size','-A',obj],costenv).stdout
                text_bytes = sum(int(n) for n in re.findall(r'^\.text(?:\.\S+)?\s+(\d+)',sizes,re.M))
                compile_cost = dict(allocated_bytes=int(rts['bytes allocated']),max_bytes_used=int(rts['max_bytes_used']),
                                    wall_seconds=seconds,root_text_bytes=text_bytes,
                                    root_functions=len(re.findall(r'^# fn ',asm.read_text(),re.M)),
                                    target='rv64imafdc_zicsr/lp64',scope='Cold whole compiler; root-unit text only')
            rows.append(dict(form=name, compiler_sha256=digest(compiler), source_sha256=digest(source),
                             switches=switches, cost=cost, compile_cost=compile_cost, samples_seconds=[]))
        # No compilation, probes or other qualification work during samples.
        for exe, env in builds.values():
            p = run([exe], env)
            assert p.stdout == expected and not p.stderr, p
        by_name = {r['form']:r for r in rows}
        for sample in range(args.samples):
            for name in list(builds)[::1 if sample % 2 == 0 else -1]:
                exe, env = builds[name]
                start = time.perf_counter()
                p = run([exe], env)
                elapsed = time.perf_counter()-start
                assert p.stdout == expected and not p.stderr, p
                by_name[name]['samples_seconds'].append(elapsed)
        for row in rows:
            row['median_seconds'] = statistics.median(row['samples_seconds'])
            print(f"{row['form']}: {row['cost']['alloc_requests']} allocations; {row['median_seconds']:.6f}s", flush=True)
    args.record.write_text(json.dumps(dict(host=platform.platform(), count=args.count, samples=args.samples,
        tool_sha256=digest(Path(__file__)), fixture_sha256=digest(ROOT/'tests/check_base_products.py'),
        tree_fixture_sha256=digest(ROOT/'tests/check_base_product_trees.py'), shape=args.shape,
        finite_fixture_sha256=digest(ROOT/'tests/check_finite_field_workers.py'), finite_kind=args.finite_kind, amount=args.amount,
        return_fixture_sha256=digest(ROOT/'tests/check_product_returns.py'), unary_return=args.unary_return,
        compiler_sha256=digest(ROOT/'fpr'), runtime_sha256={str(p.relative_to(ROOT)):digest(p) for p in (ROOT/'runtime').glob('*.[ch]')},
        inlining='normal', regions='normal', timing='uninstrumented alternating native subprocess wall time',
        results=rows), indent=2)+'\n')


if __name__ == '__main__':
    main()
