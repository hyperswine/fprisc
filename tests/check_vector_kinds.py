#!/usr/bin/env python3
"""Raw argument kinds, legal captured pipelines and A64 SIMD versus scalar/C."""
import os, platform, re, subprocess, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
def run(args, env=None, ok=True):
    p=subprocess.run(list(map(str,args)),cwd=ROOT,env={**os.environ,**(env or {})},capture_output=True,text=True,timeout=240)
    if ok: assert p.returncode==0,(args,p.stdout,p.stderr)
    return p
with tempfile.TemporaryDirectory(prefix='fpr-vector-kinds-') as d:
    tmp=Path(d);exe=tmp/'probe'
    expected='kinds: floats=11.5 mixed=12 pipeline=4,38 f32=8\n'
    for env in ({},{'FPR_NO_VEC_FUSE':'1'},{'FPR_NO_VEC_SIMD':'1'},{'FPR_NO_INLINE':'1'}):
        for src,want,extra in [('veckinds.fpr',expected,[]),('vecsimd.fpr',None,[]),
                               ('vecsimd_int.fpr',''.join(f'simd-int: {n} {n*(n-1)//2+7*n}\n' for n in range(99,-1,-1)),[]),
                               ('vecsimd_edges.fpr','SIMD IEEE reference: 0 mismatches\n',['--with','tests/base/floatprobe.c'])]:
            run(['./fpr','build','tests/base/'+src,'-o',exe,*extra],env)
            p=run([exe],env)
            if want: assert p.stdout==want,(src,env,p.stdout)
            else:
                want=''.join(f'simd: {n} {format(1.5*n*(n+1)/2+n,"g")}\n' for n in range(99,-1,-1))
                assert p.stdout==want,(env,p.stdout)
    fuel=tmp/'fuel.fpr'
    source=(ROOT/'tests/base/vecsimd.fpr').read_text()
    source=source.replace('profile base.', 'profile base.\nforceKernelFuel : Unit -> Unit.')
    source=source.replace('  v = fill n (Vec.new Unit) |> Vec.map first |> Vec.map second;',
                          '  original = fill n (Vec.new Unit);\n  _ = forceKernelFuel Unit;\n  v = original |> Vec.map first |> Vec.map second;')
    fuel.write_text(source)
    run(['./fpr','build',fuel,'--with','tests/base/vecfuel.c','-o',exe])
    result=run([exe],{'FPR_HARTS':'4'})
    assert result.stdout==''.join(f'simd: {n} {format(1.5*n*(n+1)/2+n,"g")}\n' for n in range(99,-1,-1)),result.stdout
    # Emission gates assert selected plans, not merely a green generic fallback.
    asm=tmp/'kinds.s'
    run(['./fprc','--profile=base','--target=a64','tests/base/veckinds.fpr',asm])
    text=asm.read_text()
    assert '([KD,KD,KD],KD)' in text and '([KD,KI,KD,KI,KD,KD],KD)' in text,text[-15000:]
    assert re.search(r'Vec.map specialized on _vfuse_',text),text[-15000:]
    assert re.search(r'Vec.filter specialized on _vfuse_',text),text[-15000:]
    run(['./fprc','--profile=base','--target=a64','tests/base/vecsimd.fpr',asm])
    text=asm.read_text()
    assert text.count('[NEON 2 lanes]')==1 and 'fmul v' in text and '.2d' in text
    assert 'Vec.map specialized on _vfuse_' in text
    ints=tmp/'ints.s'
    run(['./fprc','--profile=base','--target=a64','tests/base/vecsimd_int.fpr',ints])
    assert '[NEON 2 lanes]' in ints.read_text() and re.search(r'add v\d+\.2d',ints.read_text())
    scalar=tmp/'scalar.s'
    run(['./fprc','--profile=base','--target=a64','tests/base/vecsimd.fpr',scalar],{'FPR_NO_VEC_SIMD':'1'})
    assert '[NEON' not in scalar.read_text()
    # Native IEEE/int failures must keep their original visitation order.
    for source in ('vecfuse_effects.fpr','vecfuse_fail.fpr','vecfuse_capture.fpr'):
        outputs=[]
        for env in ({},{'FPR_NO_VEC_FUSE':'1'}):
            run(['./fpr','build','tests/base/'+source,'-o',exe],env)
            p=run([exe],env,ok=False);outputs.append((p.returncode,p.stdout))
        assert outputs[0]==outputs[1],(source,outputs)
    print('Vector kinds: float captures, mixed record fold, captured map/map and filter/filter, strict order and 100 SIMD tails PASS')
    print('A64 NEON execution: '+('native host and C IEEE reference PASS' if platform.machine() in ('arm64','aarch64') else 'emission PASS; host SIMD execution unavailable'))
