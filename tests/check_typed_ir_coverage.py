#!/usr/bin/env python3
"""Native float value ABI and preservation of enabled vector specialization."""
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ENV = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
ENV.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), FPR_HARTS='1')


def run(cmd, env):
    p = subprocess.run(list(map(str, cmd)), cwd=ROOT, env=env,
                       capture_output=True, text=True, timeout=600)
    assert p.returncode == 0, (cmd, p.stdout[-2000:], p.stderr[-4000:])
    return p.stdout + p.stderr


def main():
    run(['make', 'fpr'], ENV)
    with tempfile.TemporaryDirectory(prefix='fpr-tir-coverage-') as d:
        tmp = Path(d)
        for inline in ('0', '1'):
            env = dict(ENV, FPR_TYPED_IR_BACKEND='mixed', FPR_NO_INLINE=inline,
                       XDG_CACHE_HOME=str(tmp / ('floats-' + inline)))
            for src, names, extra, expected in (
                ('tests/base/floatinline.fpr', 'same,one,row,allPairs',
                 ['--with', 'tests/base/floatprobe.c'], 'F64 inline: 0 mismatches over 400 pairs\n'),
                ('tests/float.fpr', 'half,hyp,sumTo,wsum,addAll,swapF', [], 'FLOATS HOLD\n'),
            ):
                exe = tmp / 'floats'
                notes = run([ROOT / 'fpr', 'build', src, *extra, '-o', exe, '-v'],
                            dict(env, FPR_TYPED_IR_STRICT=names))
                for name in names.split(','):
                    assert re.search(r'typed-ir-backend: ' + name + r' native ', notes), (name, notes[-4000:])
                for harts in ('1', '4'):
                    out = run([exe], dict(env, FPR_HARTS=harts))
                    assert out.endswith(expected) and 'FAIL' not in out, out
            print(f'float V ABI: C reference on 400 edge pairs, F32/F64, 10 arguments, aggregates, deep tail loop, one/four harts, no-inline={inline} PASS', flush=True)

        src = tmp / 'pipeline.fpr'
        src.write_text('''unsafe base.
inc x = x + 1.
above x = x > 500.
weighted a x = a + 2 * x.
main = v = Vec.iota 1000;
  (answer, v) = Vec.fold weighted 7 (Vec.filter above (Vec.map inc v));
  _ = Vec.free v; print answer.
''')
        original = src.read_text()
        for generic in (False, True):
            if generic:
                src.write_text(original.replace(
                    'Vec.fold weighted 7 (Vec.filter above (Vec.map inc v))',
                    'runPipeline inc above weighted v') +
                    'runPipeline inc above weighted v = Vec.fold weighted 7 (Vec.filter above (Vec.map inc v)).\n')
            env = dict(ENV, FPR_TYPED_IR_BACKEND='mixed', FPR_NO_INLINE='1',
                       XDG_CACHE_HOME=str(tmp / ('pipeline-' + str(generic))))
            for target in ('a64', 'x64', 'rv64', 'rv32'):
                asm = tmp / (target + '.s')
                notes = run([ROOT / 'fpr', '--target=' + target,
                             '--prelude=' + str(ROOT / 'core/prelude.fpr'), src, asm], env)
                text = asm.read_text()
                if not generic:
                    # the caller is native and calls the fused kernel the legacy
                    # specialiser still emits (docs/2026-10-22-TYPED-IR-KERNELS.md)
                    assert 'typed-ir-backend: main native ' in notes, notes[-2000:]
                    assert '# mixed scalar pipeline:' in text, target
                    kernels = set(re.findall(r'^_?(fpr_vspec_pipeline\w*):', text, re.M))
                    assert kernels, target
                    calls = re.findall(r'^\s+(?:bl|call|jal|jal ra,|tail|b|jmp)\s+_?(fpr_vspec_pipeline\w*)', text, re.M)
                    assert set(calls) & kernels, (target, sorted(kernels)[:1])
                else:
                    assert 'typed-ir-backend: main native ' in notes, notes[-2000:]
                    assert '# mixed scalar pipeline:' not in text, target
            exe = tmp / 'pipeline'
            run([ROOT / 'fpr', 'build', src, '-o', exe], env)
            assert run([exe], env) == '750507\n'
        print('vector kernels: native callers call the legacy-emitted fused kernel on all four selectors; local callback parameters admit direct main; native results equal independent arithmetic PASS', flush=True)


if __name__ == '__main__':
    main()
