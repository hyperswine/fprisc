#!/usr/bin/env python3
"""Mixed scalar pipelines: values, stable compaction, captures, ABI and effects."""
from pathlib import Path
import os,subprocess,tempfile,json
ROOT=Path(__file__).resolve().parents[1]
FIXTURE=ROOT/'tests/base/vecpipeline.fpr'

def expected():
    lines=[]
    show=lambda xs:'['+', '.join(map(str,xs))+']'
    for n in range(100):
        xs=[x+1 for x in range(n) if x+1>5]
        lines.append(f'nested {n} {7+2*sum(xs)} {show(xs)}')
        xs=[2*(x+1) for x in range(n) if x+1>3 and 2*(x+1)<20]
        lines.append(f'lets {n} {4+3*sum(xs)} {show(xs)}')
        xs=[x*2 for x in range(n) if x>3]
        lines.append(f'nofold {n} {show(xs)}')
        lines.append(f'none {n} 9 []')
    xs=[2*(x+1)+4 for x in range(10) if 2*(x+1)>3 and 2*(x+1)+4<20]
    lines += [f'seven {5+3*sum(xs)} {show(xs)}','boxed 87 [6, 7, 8, 9, 10]',
              'float 5.5 0.5;1.5;3.5;','small 5.5 0.5;1.5;3.5;','ordered 3','IEEE 0']
    return '\n'.join(lines)+'\n'

def check_execution(run):
    for harts in (1,4):
        code,out,err=run('',harts)
        assert code==0 and out==expected(),(code,out[-900:],err[-1500:],expected()[-900:])
        code,out,err=run('effects',harts)
        assert code==0 and out=='map 0\nmap 1\nmap 2\nfilter 1\nfilter 2\nfilter 3\neffects 6\n',(code,out,err)
        code,out,err=run('seed',harts)
        assert code==0 and out=='map 0\nmap 1\nmap 2\nseed\nseed-total 6\n',(code,out,err)
        code,out,err=run('trap',harts)
        assert code==1 and 'filter ' not in out+err,(code,out,err)
        assert 'zero' in (out+err).lower(),(out,err)

def command(args,env):
    if 'compile' in args:
        # Static assertions below describe legacy pipeline assembly. Runtime
        # differentials keep the selected backend; typed CFGs have their own
        # four-target execution gate in check_typed_ir_kernels.py.
        env=dict(env)
        env.pop('FPR_TYPED_IR_BACKEND',None)
        env.pop('FPR_TYPED_IR_STRICT',None)
    p=subprocess.run(list(map(str,args)),cwd=ROOT,env=env,capture_output=True,text=True,timeout=300)
    assert p.returncode==0,(args,p.stdout[-1200:],p.stderr[-3000:])
    return p

def main():
    with tempfile.TemporaryDirectory(prefix='fpr-pipelines-') as td:
        tmp=Path(td)
        base=dict(os.environ,FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),XDG_CACHE_HOME=str(tmp/'cache'))
        base.pop('FPR_FOREIGN',None)
        for no_inline in ('0','1'):
            for no_regs in ('0','1'):
                for no_fuse,no_pipe_inline in [('1','0'),('0','1'),('0','0'),('1','0')]:
                    env=dict(base,FPR_NO_INLINE=no_inline,FPR_NO_REGISTERS=no_regs,FPR_NO_VEC_FUSE=no_fuse,FPR_NO_PIPELINE_INLINE=no_pipe_inline)
                    exe=tmp/'pipeline'
                    command([ROOT/'fpr','build',FIXTURE,'--harts','4','--with',ROOT/'tests/bench/workers_clock.c','--with',ROOT/'tests/base/floatprobe.c','-o',exe],env)
                    def run(case,harts):
                        p=subprocess.run([str(exe)]+([case] if case else []),env=dict(env,FPR_HARTS=str(harts)),capture_output=True,text=True,timeout=60)
                        return p.returncode,p.stdout,p.stderr
                    check_execution(run)
                    print(f'pipeline inline-disabled={no_inline} registers-disabled={no_regs} fusion-disabled={no_fuse} pipeline-inline-disabled={no_pipe_inline}: PASS',flush=True)
        for target in ('rv64','a64','x64','rv32'):
            for off,no_pipe_inline in (('0','0'),('0','1'),('1','0')):
                out=tmp/f'{target}-{off}-{no_pipe_inline}.s'
                command([ROOT/'fpr','compile','--target='+target,FIXTURE,out],dict(base,FPR_NO_VEC_FUSE=off,FPR_NO_PIPELINE_INLINE=no_pipe_inline))
                asm=out.read_text()
                if off=='0':
                    assert ('# inline pipeline callback' in asm)==(no_pipe_inline=='0'),target
                    assert '# mixed scalar pipeline: map plus -> filter above -> fold weighted' in asm,target
                    assert '# mixed scalar pipeline: map floatPlus -> filter floatAbove -> fold floatSum' in asm or target=='rv32',target
                else: assert '# mixed scalar pipeline:' not in asm,target
                assert 'mixed scalar pipeline: map noisy' not in asm
                assert 'mixed scalar pipeline: map divide' not in asm
        print('mixed scalar pipelines: native differential, 1/4 harts, returns/compaction, floats, captures, effects/traps and four-target emission PASS')
if __name__=='__main__': main()
