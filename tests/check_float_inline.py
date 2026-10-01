#!/usr/bin/env python3
"""F64 fast paths: C-reference differential tests and x64 backend execution."""
import os, platform, re, shutil, subprocess, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
ENV = {**os.environ, 'FPR_HOME': str(ROOT), 'FPR_PATH': str(ROOT)}
ENV.pop('FPR_FOREIGN', None)
def run(args, env=None, timeout=180):
    p = subprocess.run([str(a) for a in args], cwd=ROOT, env={**ENV, **(env or {})},
                       capture_output=True, text=True, timeout=timeout)
    assert p.returncode == 0, f'{args}: exit {p.returncode}\n{p.stdout}{p.stderr}'
    return p
run(['make', 'fpr'], timeout=300)
with tempfile.TemporaryDirectory(prefix='fpr-f64-') as temp:
    tmp = Path(temp)
    for no_float in ('0', '1'):
        for no_inline in ('0', '1'):
            exe = tmp / ('float-' + no_float + no_inline)
            run(['./fpr', 'build', 'tests/base/floatinline.fpr', '--with',
                 'tests/base/floatprobe.c', '-o', exe],
                {'FPR_NO_F64_INLINE': no_float, 'FPR_NO_INLINE': no_inline})
            out = run([exe]).stdout
            assert out == 'F64 inline: 0 mismatches over 400 pairs\n', out
    print('F64: C-reference agreement on 400 edge-case pairs, fast paths and inliner independently on/off: PASS')
    # Compile through the real x64 code generator and assembler. On an
    # arm64 Mac, execute its ten leaf functions under Rosetta after adapting
    # ONLY ELF symbol spelling and the hart TLS load to this C harness.
    # The emitted prologue, arithmetic, comparisons and epilogue stay intact.
    ops = {'add': '+', 'sub': '-', 'mul': '*', 'div': '/',
           'lt': '<', 'le': '<=', 'gt': '>', 'ge': '>=', 'eq': '==', 'ne': '!='}
    source = tmp / 'backend.fpr'
    source.write_text(''.join(f'{n} : F64 -> F64 -> {"F64" if n in ("add", "sub", "mul", "div") else "Bool"} .\n{n} a b = a {op} b.\n'
                              for n, op in ops.items()) + 'main = Unit.\n')
    asm = tmp / 'backend.s'
    run(['./fpr', '--target=x64', f'--prelude={ROOT}/core/prelude.fpr', source, asm],
        {'FPR_NO_F64_INLINE': '0'})
    cc = shutil.which('clang') or shutil.which('cc')
    if shutil.which('clang'):
        run(['clang', '--target=x86_64-linux-gnu', '-c', asm, '-o', tmp / 'backend.o'])
    mac = platform.system() == 'Darwin'
    native = platform.machine() in ('x86_64', 'AMD64')
    rosetta = mac and not native and subprocess.run(['arch', '-x86_64', '/usr/bin/true'], capture_output=True).returncode == 0
    if native or rosetta:
        text = asm.read_text()
        chunks = []
        for n in ops:
            m = re.search(r'(?ms)^\s*\.globl fpr_fn_' + n + r'\n.*?(?=^# wcet:|^# fn |\Z)', text)
            assert m, f'missing generated {n}'
            chunks.append(m.group())
        selected = '.text\n' + ''.join(chunks)
        selected = selected.replace('%fs:fpr_posix_hart@tpoff', 'probe_hart(%rip)')
        if mac:
            selected = re.sub(r'\bfpr_[A-Za-z0-9_]+\b', lambda m: '_' + m.group(), selected)
            selected = selected.replace('probe_hart(%rip)', '_probe_hart(%rip)')
        leaf = tmp / 'leaf.s'; leaf.write_text(selected)
        exe = tmp / 'x64-probe'
        run([cc, *(['-arch', 'x86_64'] if mac else []), '-O2', leaf,
             ROOT / 'tests/base/floatbackend.c', '-o', exe])
        p = run([*(['arch', '-x86_64'] if rosetta else []), exe])
        assert p.stdout == 'x64 F64: 0 mismatches over 1280 pairs\n', p.stdout
        print(p.stdout.strip() + ': PASS')
    else:
        print('x64 F64 execution: SKIP (needs native x64 or Rosetta; generated assembly checked when clang is available)')
