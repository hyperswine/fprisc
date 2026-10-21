#!/usr/bin/env python3
"""RV64 Unix lowering/cache checks and optional real Linux cross builds.

  python3 tests/check_rv64_linux.py
  python3 tests/check_rv64_linux.py --cc CROSS-GCC --output /tmp/rv64-tests
  python3 tests/check_rv64_linux.py --execute-only --output /tmp/rv64-tests \
      --runner 'qemu-riscv64 -L SYSROOT'

The runner receives a local executable path and arguments, with test stdin.
It may be an emulator or an SSH upload/execute wrapper. No assembly patching.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FPR = ROOT / 'fpr'

# A native prelude function alone is insufficient evidence that a workload
# exercised the direct backend. Require its specific ABI/runtime functions.
TYPED_REQUIRED = {
    'hello': ('main',),
    'float': ('half', 'hyp', 'sumTo', 'wsum', 'addAll', 'swapF'),
    'vectors': ('affine', 'above', 'fill9'),
    'actors': ('main', 'echo', 'counterLoop'),
    'sleepwake': ('main', 'napper', 'pester'),
    'sleepwait': ('main', 'waiter'),
    'lines': ('main', 'loop'),
    'module-host': ('main', 'run'),
}


def require_native(name, log):
    if os.environ.get('FPR_TYPED_IR_BACKEND'):
        for fn in TYPED_REQUIRED[name]:
            assert re.search(r'typed-ir-backend: ' + re.escape(fn) + r' native ', log), (name, fn, log[-6000:])


def command(args, expected=0, **kwargs):
    p = subprocess.run(list(map(str, args)), cwd=ROOT, capture_output=True,
                       text=True, timeout=180, **kwargs)
    assert p.returncode == expected, (args, p.returncode, p.stdout, p.stderr)
    return p.stdout + p.stderr


def lowering(directory):
    def compile_(name, flags):
        out = directory / (name + '.s')
        command([FPR, 'compile', *flags, '--prelude=' + str(ROOT / 'core/prelude.fpr'),
                 ROOT / 'tests/base/wide.fpr', out])
        units = set(Path(str(out) + '.units').read_text().split())
        text = out.read_text() + ''.join(Path(p).read_text() for p in units)
        return units, text
    bare, b = compile_('bare', ['--profile=base', '--target=rv64'])
    unix, u = compile_('unix', ['--system=posix', '--target=rv64'])
    warm, _ = compile_('warm', ['--target=rv64', '--system=posix'])
    qos, q = compile_('qos', ['--target=qrv64'])
    portable, _ = compile_('portable', ['--system=qos-portable', '--target=qrv64'])
    reverse, _ = compile_('reverse', ['--target=qrv64', '--system=qos-portable'])
    module, m = compile_('module', ['--system=posix', '--target=rv64', '--plugin'])
    assert re.search(r'\bmv\s+\w+,\s*tp\b', b)
    assert '%tprel_hi(fpr_posix_hart)' in u and '%tprel_lo(fpr_posix_hart)' in u
    assert 'fpr_g_tlsoff' in q and '%tprel' not in q
    assert 'la.tls.ie' in m and '.option pic' in m
    assert not re.search(r'^\s*j\s+(?!\.L)\S+', m, re.M)
    refused = command([FPR, 'compile', '--system=posix', '--target=rv32',
                       ROOT / 'tests/base/hello.fpr', directory / 'bad.s'], expected=1)
    assert 'requires a 64-bit target' in refused
    for text in (u, q, m):
        assert not re.search(r'^\s*j\s+(?!\.L)\S+', text, re.M)
        assert not re.search(r'\bmv\s+\w+,\s*tp\b', text)
        assert not re.search(r'^\s*(?:mv|ld|addi|lui)\s+tp,', text, re.M)
    assert unix == warm and qos == portable == reverse
    groups = [bare, unix, qos, module]
    assert all(not (a & b) for i, a in enumerate(groups) for b in groups[i + 1:])
    print('RV64 Unix/QOS/module lowering, flag order and warm-cache isolation PASS', flush=True)


def build(output, cc):
    output.mkdir(parents=True, exist_ok=True)
    cases = []
    sources = {
        'hello': ('tests/base/hello.fpr', ['hello from base']),
        'float': ('tests/float.fpr', ['FLOATS HOLD']),
        'vectors': ('tests/base/veccaps.fpr', ['sum=10000000000', 'kept=49999 sum=7499899999', 'sum=5546500']),
        'actors': ('tests/actors.fpr', ['actor demo done', '-> 42', '-> 12']),
        'sleepwake': ('tests/base/sleepwake.fpr', ['sleepwake: alive']),
        'sleepwait': ('tests/base/sleepwait.fpr', ['waiter got 7', 'main got 1']),
        'lines': ('tests/base/lines.fpr', ['lines: 4 chars: 9', 'lines: to stderr']),
    }
    for name, (source, markers) in sources.items():
        log = command([FPR, 'build', ROOT / source, '--target=linux-riscv64', '--cc', cc,
                 '--harts', '4', '-o', output / name, '-v'])
        require_native(name, log)
        for harts in (1, 4):
            cases.append(dict(name=name, harts=harts, markers=markers,
                              stdin='ab\ncde\n\nlast' if name == 'lines' else ''))
    command([cc, '-O2', '-march=rv64gc', '-mabi=lp64d', '-DFPR_POSIX',
             '-I' + str(ROOT / 'runtime'), ROOT / 'tests/rv64_linux_context.c',
             ROOT / 'machine/unix/ctx_rv64.S', '-lm', '-o', output / 'context'])
    cases.append(dict(name='context', harts=1, markers=['RV64_CONTEXT_PASS']))
    module = output / 'math.fpr'
    module.write_text('unsafe module.\nnativeHart : Unit -> Bool.\nhartOK u = nativeHart u.\nmathOp : Int -> Int.\nmathOp x = x * 3.\nfloatOp : F64 -> F64.\nfloatOp x = x * 2.0.\n')
    helper = output / 'module-helper.c'
    helper.write_text('#include "fpr.h"\nstatic V h_nativeHart(V u) { (void)u; return BOOL(fpr_hart() != 0); }\nFPR_FN(fpr_g_nativeHart, h_nativeHart, 1);\n')
    command([FPR, 'build', module, '--target=linux-riscv64', '--cc', cc,
             '--module', '--with', helper, '-o', output / 'math.so'])
    host = output / 'module-host.fpr'
    host.write_text('''unsafe base.
N = use "std/native".
R = use "std/reload".
main = case Sys.args Unit of path :: rest -> run path | Nil -> error "expected module path".
run path =
    _ = case N.attach path of Ok _ -> Unit | Err why -> error why;
    op = R.bindAt 0 "mathOp";
    f = R.bindAt 0 "floatOp";
    h = R.bindAt 0 "hartOK";
    case op 10 == 30 and f 1.25 == 2.5 and h Unit of
      True -> print "RV64_MODULE_PASS 30 2.5"
    | False -> error "module result mismatch".
''')
    log = command([FPR, 'build', host, '--target=linux-riscv64', '--cc', cc,
             '--harts', '4', '-o', output / 'module-host', '-v'])
    require_native('module-host', log)
    for harts in (1, 4):
        cases.append(dict(name='module-host', harts=harts, markers=['RV64_MODULE_PASS'],
                          artifacts=['math.so']))
    (output / 'cases.json').write_text(json.dumps(cases, indent=2) + '\n')
    print(f'Built {len(cases)} execution cases through fpr build --target=linux-riscv64', flush=True)


def execute(output, runner):
    results = []
    for case in json.loads((output / 'cases.json').read_text()):
        env = dict(os.environ, FPR_HARTS=str(case['harts']), FPR_HEAP_MB='256', FPR_STACK_MAX_MB='8')
        args = [*shlex.split(runner), str(output / case['name'])]
        args += [str(output / p) for p in case.get('artifacts', [])]
        p = subprocess.run(args, cwd=ROOT, env=env, input=case.get('stdin', ''),
                           capture_output=True, text=True, timeout=90)
        text = p.stdout + p.stderr
        passed = p.returncode == 0 and all(m in text for m in case['markers'])
        label = f"{case['name']}-h{case['harts']}"
        (output / (label + '.log')).write_text(text)
        results.append(dict(case=label, passed=passed, exit=p.returncode))
        print(label, 'PASS' if passed else text, flush=True)
    (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    assert all(r['passed'] for r in results), results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cc')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--runner')
    parser.add_argument('--typed-ir', action='store_true', help='exercise direct typed RV64 in mixed mode')
    parser.add_argument('--execute-only', action='store_true')
    args = parser.parse_args()
    if args.typed_ir:
        os.environ['FPR_TYPED_IR_BACKEND'] = 'mixed'
        if args.output:
            os.environ['XDG_CACHE_HOME'] = str(args.output.resolve() / 'cache')
    if not args.execute_only:
        with tempfile.TemporaryDirectory(prefix='fpr-rv64-lowering-') as tmp:
            if not args.typed_ir:
                lowering(Path(tmp))
        if args.cc:
            if not args.output:
                parser.error('--cc requires --output')
            build(args.output.resolve(), args.cc)
    if args.runner:
        if not args.output:
            parser.error('--runner requires --output')
        execute(args.output.resolve(), args.runner)


if __name__ == '__main__':
    main()
