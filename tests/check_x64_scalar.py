#!/usr/bin/env python3
"""Execute generated x64 arithmetic and ABI probes on Intel or macOS Rosetta."""
import re
import subprocess
import shutil
import tempfile
import time
from pathlib import Path
from x64_probe import ROOT, adapt, environment, host, link, run


def fixture():
    source = '''unsafe base.
add a b = a + b.
sub a b = a - b.
mul a b = a * b.
divide a b = a / b.
shift a b = BITSHIFTL a b.
branch a b = if a < b then a - b else a + b.
hot a b c d e = a*b + c*d + e*a + b*c + d*e + a*c + b*d + c*e + d*a + e*b.
calls a b c d e = hot a b c d e + hot e d c b a + a + b + c + d + e.
boolEq : unsafe Int -> Bool -> Bool .
boolEq n b = if n == 0 then b == (n < 1) else boolEq (n - 1) b.
boolNe : unsafe Int -> Bool -> Bool .
boolNe n b = if n == 0 then b != (n < 1) else boolNe (n - 1) b.
boolResult : unsafe Int -> Int -> Int .
boolResult n flag = (if boolEq n (flag > 0) then 10 else 0) + (if boolNe n (flag > 0) then 1 else 0).
'''
    for width in (6, 7, 8, 63):
        names = [f'a{i}' for i in range(width)]
        source += f"rotate{width} : unsafe {' -> '.join(['Int'] * (width + 2))} .\n"
        source += (f"rotate{width} n {' '.join(names)} = if n == 0 then "
                   + ' + '.join(f'{i+1} * {n}' for i, n in enumerate(names))
                   + f" else rotate{width} (n - 1) {' '.join(names[1:] + names[:1])}.\n")
    for width in (6, 7):
        names = [f'a{i}' for i in range(width)]
        args = ' '.join(names)
        source += (f'call{width+1} n {args} = rotate{width} n {args}'
                   + f' + rotate{width} (n + 1) {args} + a0.\n')
    return source + 'main = Unit.\n'


def main():
    target = host()
    if target is None:
        print('x64 scalar execution SKIP: needs x86-64 or macOS Rosetta')
        return
    mac, runner, label = target
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix='fpr-x64-scalar-') as d:
        tmp = Path(d)
        env = environment(tmp / 'cache')
        source = tmp / 'scalar.fpr'
        source.write_text(fixture())
        modes = [('baseline', {}),
                 ('registers', dict(FPR_NO_REGISTERS='0', FPR_RETAINED_REGISTERS='1',
                                    FPR_COMPACT_FRAMES='1', FPR_SELF_LOOPS='1')),
                 ('costed', dict(FPR_NO_REGISTERS='0', FPR_RETAINED_REGISTERS='1',
                                 FPR_COSTED_REGISTERS='1', FPR_COMPACT_FRAMES='1', FPR_SELF_LOOPS='1')),
                 ('workers', dict(FPR_NO_REGISTERS='0', FPR_RETAINED_REGISTERS='1',
                                  FPR_COMPACT_FRAMES='1', FPR_SELF_LOOPS='1',
                                  FPR_NO_SCALAR_WORKERS='0')),
                 ('typed-ir', dict(FPR_TYPED_IR_BACKEND='mixed',
                                   FPR_TYPED_IR_STRICT='add,sub,mul,divide,branch,hot,calls,boolEq,boolNe,boolResult,rotate6,rotate7,call7,call8')),
                 ('typed-ir-workers', dict(FPR_TYPED_IR_BACKEND='mixed', FPR_NO_SCALAR_WORKERS='0',
                                           FPR_TYPED_IR_STRICT='add,sub,mul,divide,branch,hot,calls,boolEq,boolNe,boolResult,rotate6,rotate7,call7,call8')),
                 ('baseline-repeat', {})]
        original = None
        for name, settings in modes:
            mode = dict(env, **settings)
            assembly = tmp / 'scalar.s'
            run([ROOT / 'fpr', 'compile', '--target=x64', source, assembly], mode)
            text = assembly.read_text()
            # Select complete top-level functions, including their private workers.
            bodies = re.findall(r'(?ms)^# fn ([^\n]+)\n(.*?)(?=^# (?:wcet|native-insns-v1):)', text)
            selected = '\n'.join(body for title, body in bodies if not title.startswith('main '))
            assert 'fpr_fn_rotate63:' in selected and 'idivq' in selected
            native = 'FPR_TYPED_IR_BACKEND' in mode
            if native:
                native_names = {title.split()[0] for title, _ in bodies if 'typed-ir x64' in title}
                required = set(mode['FPR_TYPED_IR_STRICT'].split(','))
                assert required <= native_names, (required - native_names, native_names)
                assert not {'rotate8', 'rotate63', 'shift'} & native_names
                assert 'UNBOUNDED' not in text
                assert '%fs:fpr_x64_a6@tpoff' in selected and '%fs:fpr_x64_a7@tpoff' in selected
                assert 'cqto' in selected and 'imulq' in selected
                print(f'{name}: strict direct coverage {len(native_names)} functions; shifts and arities 9/64 explicitly legacy', flush=True)
            else:
                hot = next(body for title, body in bodies if title == 'hot (arity 5)')
                # Costed placement may legitimately reject promotion.
                if mode['FPR_COSTED_REGISTERS'] == '0':
                    assert bool(re.search(r'%(?:rbx|r12|r13|r14|r15)\b', hot)) == (mode['FPR_NO_REGISTERS'] == '0')
                assert bool(re.search(r'^\.Lself\d+:', selected, re.M)) == (mode['FPR_SELF_LOOPS'] == '1')
            assert ('fpr_fn__x24worker_x2escalar_x2e' in selected) == (mode['FPR_NO_SCALAR_WORKERS'] == '0')
            if name == 'baseline':
                original = selected
                baseline_bodies = {title.split()[0]: body for title, body in bodies}
            if name == 'baseline-repeat':
                assert selected == original, 'off/on/off emission changed'
            if native and shutil.which('clang'):
                raw = tmp / 'real-tls.s'
                raw.write_text('.text\n' + selected)
                run(['clang', '-target', 'x86_64-unknown-linux-gnu', '-c', raw, '-o', tmp / 'real-tls.o'], mode)
            assembly.write_text(adapt('.text\n' + selected, mac))
            shim = tmp / 'abi.s'
            shim.write_text(adapt((ROOT / 'tests/base/x64_scalar_abi.s').read_text(), mac))
            exe = tmp / 'oracle'
            link([assembly, shim, ROOT / 'tests/base/x64_scalar_oracle.c'], exe, mac, mode)
            print(f'{label} {name}: ' + run([*runner, exe], mode).strip(), flush=True)
            if name == 'typed-ir':
                for boundary, legacy_names in [('legacy-callees', {'hot', 'rotate6', 'rotate7'}),
                                               ('legacy-callers', {'calls', 'call7', 'call8', 'boolResult'})]:
                    # Different compilations have independent local-label counters.
                    # Keep them in separate objects, just like real mixed units.
                    mixed = '\n'.join(body for title, body in bodies
                                      if not title.startswith('main ') and title.split()[0] not in legacy_names)
                    legacy_asm = tmp / 'legacy-boundary.s'
                    legacy_asm.write_text(adapt('.text\n' + '\n'.join(baseline_bodies[n] for n in sorted(legacy_names)), mac))
                    assembly.write_text(adapt('.text\n' + mixed, mac))
                    link([assembly, legacy_asm, shim, ROOT / 'tests/base/x64_scalar_oracle.c'], exe, mac, mode)
                    print(f'{label} typed-ir/{boundary}: ' + run([*runner, exe], mode).strip(), flush=True)
        refused = subprocess.run([str(ROOT / 'fpr'), 'compile', '--target=x64', str(source), str(assembly)],
            cwd=ROOT, env=dict(env, FPR_TYPED_IR_BACKEND='mixed', FPR_TYPED_IR_STRICT='rotate63'),
            capture_output=True, text=True, timeout=240)
        assert refused.returncode != 0 and 'rotate63:' in refused.stderr and 'typed-ir strict' in refused.stderr, refused.stderr
        print('typed-ir strict refusal for unsupported arity: PASS')
    print(f'x64 scalar/ABI probes: {time.monotonic()-started:.2f}s including compilation/linking; Linux TLS and scheduler are substituted')


if __name__ == '__main__':
    main()
