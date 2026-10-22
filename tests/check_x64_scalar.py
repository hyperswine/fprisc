#!/usr/bin/env python3
"""Execute generated x64 arithmetic and ABI probes on Intel or macOS Rosetta."""
import re
import sys
import shutil
import tempfile
import time
from pathlib import Path
from x64_probe import ROOT, adapt, borrowed_oracle, environment, host, link, run


def fixture():
    source = '''unsafe base.
add a b = a + b.
sub a b = a - b.
mul a b = a * b.
divide a b = a / b.
shift a b = BITSHIFTL a b.
branch a b = if a < b then a - b else a + b.
hot a b c d e = a*b + c*d + e*a + b*c + d*e + a*c + b*d + c*e + d*a + e*b.
forward a b c d e = hot e d c b a.
forwardSwap a b = sub b a.
calls a b c d e = hot a b c d e + hot e d c b a + a + b + c + d + e.
boolEq : unsafe Int -> Bool -> Bool .
boolEq n b = if n == 0 then b == (n < 1) else boolEq (n - 1) b.
boolNe : unsafe Int -> Bool -> Bool .
boolNe n b = if n == 0 then b != (n < 1) else boolNe (n - 1) b.
boolResult : unsafe Int -> Int -> Int .
boolResult n flag = (if boolEq n (flag > 0) then 10 else 0) + (if boolNe n (flag > 0) then 1 else 0).
pressure n = a = n + 1; b = n + 2; c = n + 3; d = n + 4; e = n + 5; f = n + 6; g = n + 7; h = n + 8; i = n + 9; j = n + 10; k = n + 11; l = n + 12;
  t = hot n n n n n; a + b + c + d + e + f + g + h + i + j + k + l + t.
wide n = a1 = n * 2; a2 = n * 3; a3 = n * 4; a4 = n * 5; a5 = n * 6; a6 = n * 7; a7 = n * 8; a8 = n * 9; a9 = n * 10; a10 = n * 11; a11 = n * 12; a12 = n * 13; a13 = n * 14; a14 = n * 15; a15 = n * 16; a16 = n * 17; a17 = n * 18; a18 = n * 19; a19 = n * 20; a20 = n * 21; a21 = n * 22; a22 = n * 23; a23 = n * 24; a24 = n * 25;
  a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9 + a10 + a11 + a12 + a13 + a14 + a15 + a16 + a17 + a18 + a19 + a20 + a21 + a22 + a23 + a24.
answer = 40 + 2.
useCaf : Int -> Int .
useCaf n = n + answer.
tick : Unit -> Int .
tick u = case u of Unit -> 7.
applyLocal : (Int -> Int) -> Int -> Int .
applyLocal f x = f x + f (x + 1).
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
    qos = "--qos" in sys.argv
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
        required = 'add,sub,mul,divide,shift,branch,hot,calls,forward,forwardSwap,boolEq,boolNe,boolResult,rotate6,rotate7,rotate8,rotate63,call7,call8,pressure,wide,answer,useCaf,tick,applyLocal'
        modes = [('typed-ir', dict(FPR_TYPED_IR_BACKEND='mixed', FPR_TYPED_IR_STRICT=required)),
                 ('typed-ir-workers', dict(FPR_TYPED_IR_BACKEND='mixed', FPR_NO_SCALAR_WORKERS='0', FPR_TYPED_IR_STRICT=required)),
                 ('typed-ir-no-loops', dict(FPR_TYPED_IR_BACKEND='mixed', FPR_TYPED_IR_SELF_LOOPS='0', FPR_TYPED_IR_STRICT=required))]
        entry_modes = [("typed-ir-shallow", {"FPR_TYPED_IR_SHALLOW_STACK": "1"}),
                       ("typed-ir-forward", {"FPR_TYPED_IR_FORWARD_PARAMS": "1"}),
                       ("typed-ir-entry", {"FPR_TYPED_IR_SHALLOW_STACK": "1", "FPR_TYPED_IR_FORWARD_PARAMS": "1"})]
        baseline_typed = dict(next(settings for name, settings in modes if name == "typed-ir"))
        modes += [(name, {**baseline_typed, **flags}) for name, flags in entry_modes]
        for name, settings in modes:
            mode = dict(env, **settings)
            assembly = tmp / 'scalar.s'
            run([ROOT / 'fpr', 'compile', '--target=' + ('qx64' if qos else 'x64'), source, assembly], mode)
            text = assembly.read_text()
            # Select complete top-level functions, including their private workers.
            bodies = re.findall(r'(?ms)^# fn ([^\n]+)\n(.*?)(?=^# (?:wcet|native-insns-v1):)', text)
            selected = '\n'.join(body for title, body in bodies if not title.startswith('main '))
            assert 'fpr_fn_rotate63:' in selected and 'idivq' in selected
            # Include tick's dead-arm reason, emitted once in read-only data.
            strings = re.findall(r'(?ms)^    \.balign 8\n(\.L(?:tir)?str[^:\n]*):\n    \.long 9000\n.*?(?=^$)', text)
            objects = re.findall(r'(?ms)^    \.balign 8\n\.L(?:tir)?str[^:\n]*:\n    \.long 9000\n.*?(?=^$)', text)
            assert objects, 'no string object in the unit'
            assert any(l.startswith('.Ltirstr_') for l in strings), strings
            assert sum(l.startswith('.Ltirstr_') for l in strings) == 1, strings
            # appended to every linked or assembled text below, in the format's syntax
            data = lambda on_mac: '\n    ' + ('.const' if on_mac else '.section .rodata') + '\n' + '\n'.join(objects) + '\n'
            native_names = {title.split()[0] for title, _ in bodies if 'typed-ir x64' in title}
            required = set(mode['FPR_TYPED_IR_STRICT'].split(','))
            assert required <= native_names, (required - native_names, native_names)
            if mode.get("FPR_TYPED_IR_FORWARD_PARAMS") == "1":
                wrappers = [title for title, _ in bodies if title.startswith(("forward ", "forwardSwap "))]
                assert len(wrappers) == 2 and all("forward=yes saved=none" in t for t in wrappers), wrappers
            assert 'UNBOUNDED' not in text
            assert all(cell in selected for cell in (('%fs:8(', '%fs:16(') if qos else ('%fs:fpr_x64_a6@tpoff', '%fs:fpr_x64_a7@tpoff')))
            # arguments 9 and 64 through the hart spill cells: the caller's
            # stores and the arrival's loads name the first and last cell
            # (the merge with M3: the arrival loads each cell into the
            # parameter's allocated register, docs/2026-10-21-TYPED-IR-MERGE.md)
            rotate63 = next(body for title, body in bodies if title.startswith('rotate63 '))
            # (the caller's store goes through %r11 when the value itself
            # was reloaded into %r10, the allocator's first scratch)
            assert re.search(r'movq %fs:0\(%r1[01]\), %r1[01]' if qos else r'movq %fs:fpr_posix_hart@tpoff, %r1[01]', rotate63) and re.search(r', 8\(%r1[01]\)', rotate63) and re.search(r', 448\(%r1[01]\)', rotate63), rotate63[:600]
            assert re.search(r'movq 8\(%(\w+)\), %\1', rotate63) and re.search(r'movq 448\(%(\w+)\), %\1', rotate63), rotate63[:600]
            assert 'cqto' in selected and 'imulq' in selected
            headers = {title.split()[0]: title for title, _ in bodies if 'typed-ir x64' in title}
            spills = int(re.search(r'spills=(\d+)', headers['pressure']).group(1))
            assert spills >= 7, headers['pressure']  # twelve values across a call, five budget registers
            assert all(s in ('none', 'rbx', 'r12', 'r13', 'r14', 'r15') for t in headers.values() for s in re.search(r'saved=(\S+)', t).group(1).split(',')), headers
            looped = mode['FPR_TYPED_IR_SELF_LOOPS'] != '0'
            assert int(re.search(r'loops=(\d+)', headers['rotate6']).group(1)) == int(looped), headers['rotate6']
            print(f'{name}: strict direct coverage {len(native_names)} functions; including arities 9 and 64; pressure spills {spills}; rotate6 loop={looped}', flush=True)
            assert ('fpr_fn__x24worker_x2escalar_x2e' in selected) == (mode['FPR_NO_SCALAR_WORKERS'] == '0')
            if shutil.which('clang'):
                raw = tmp / 'real-tls.s'
                raw.write_text('.text\n' + selected + data(False))
                run(['clang', '-target', 'x86_64-unknown-linux-gnu', '-c', raw, '-o', tmp / 'real-tls.o'], mode)
            assembly.write_text(adapt('.text\n' + selected + data(mac), mac, borrowed=qos))
            shim = tmp / 'abi.s'
            shim.write_text(adapt((ROOT / 'tests/base/x64_scalar_abi.s').read_text(), mac))
            exe = tmp / 'oracle'
            growth_flag = ['-DORACLE_TYPED_ENTRY_CHECKS'] if mode.get('FPR_TYPED_IR_SHALLOW_STACK') != '1' else []
            oracle = tmp / 'oracle.c'
            oracle_text = (ROOT / 'tests/base/x64_scalar_oracle.c').read_text()
            oracle.write_text(borrowed_oracle(oracle_text, switch=True) if qos else oracle_text)
            link([*growth_flag, assembly, shim, oracle], exe, mac, mode)
            print(f'{label} {name}: ' + run([*runner, exe], mode).strip(), flush=True)
        # (a 65th parameter never reaches the generator: the front end bundles
        # arguments beyond the 64-argument convention; the lowering's own
        # ceiling check is exercised in tests/TypedIR.hs)
    print(f'x64 scalar/ABI probes: {time.monotonic()-started:.2f}s including compilation/linking; Linux TLS and scheduler are substituted')


if __name__ == '__main__':
    main()
