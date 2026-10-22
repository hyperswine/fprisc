#!/usr/bin/env python3
"""Fresh allocation reuse: immutable aliases, ordered fields and allocation cost."""
from pathlib import Path
import os,subprocess,tempfile,json,shutil
ROOT=Path(__file__).resolve().parents[1]
EXPECTED='''{left = 11, right = 10}
(11, 10)
[11]
({left = 10, right = 11}, {left = 11, right = 10})
({left = 10, right = 11}, {left = 11, right = 10})
({left = 11, right = 10}, {left = 10, right = 11})
{first = hello world, second = hello world}
left
right
{left = 2, right = 1}
'''
def check_execution(run,enabled):
    for harts in (1,4):
        code,out,err=run('',harts)
        assert code==0 and out==EXPECTED,(code,out,err)
        code,out,err=run('bad',harts)
        assert code==1 and 'field failure' in out+err and 'WRONG' not in out+err,(code,out,err)
    code,out,err=run('cost',1)
    assert code==0,(out,err)
    result,ledger=out.splitlines()
    ledger=json.loads(ledger)
    assert result=='100020000' and ledger['alloc_requests']==(10000 if enabled else 20000),(result,ledger)
    return ledger

def command(args,env):
    p=subprocess.run(list(map(str,args)),cwd=ROOT,env=env,capture_output=True,text=True,timeout=300)
    assert p.returncode==0,(args,p.stdout[-2500:],p.stderr[-2500:])
    return p
def main():
    with tempfile.TemporaryDirectory(prefix='fpr-reuse-') as td:
        tmp=Path(td); exe=tmp/'reuse'
        env=dict(os.environ,FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),FPR_COST_PROBE='1',XDG_CACHE_HOME=str(tmp/'cache'))
        ghc=['cabal','exec','--','runghc'] if shutil.which('cabal') else ['runghc']
        print(command([*ghc,'-w','-icompiler','tests/Reuse.hs'],env).stdout,end='',flush=True)
        for no_inline in ('0','1'):
            for no_regs in ('0','1'):
                for off in ('1','0','1'):
                    mode=dict(env,FPR_NO_REUSE=off,FPR_NO_INLINE=no_inline,FPR_NO_REGISTERS=no_regs)
                    command([ROOT/'fpr','build',ROOT/'tests/base/freshreuse.fpr','--harts','4',
                             '--with',ROOT/'tests/bench/costprobe.c','--with',ROOT/'tests/bench/workers_clock.c','-o',exe],mode)
                    def run(case,harts):
                        p=subprocess.run([str(exe)]+([case] if case else []),env=dict(mode,FPR_HARTS=str(harts)),capture_output=True,text=True,timeout=90)
                        return p.returncode,p.stdout,p.stderr
                    ledger=check_execution(run,off=='0')
                    print(f'reuse disabled={off} inline-disabled={no_inline} registers-disabled={no_regs}: {ledger["alloc_requests"]} allocations PASS',flush=True)
        for target in ('rv64','rv32'):
            for off in ('0','1'):
                asm=tmp/'reuse.s'
                # the legacy emitter's marker; the typed backend's native
                # reuse is checked by the allocation ledger above instead
                command([ROOT/'fpr','compile','--target='+target,ROOT/'tests/base/freshreuse.fpr',asm],dict(env,FPR_NO_REUSE=off,FPR_TYPED_IR_BACKEND='legacy'))
                assert ('# reuse fresh constructor' in asm.read_text())==(off=='0' and target!='rv32'),(target,off)
        # Exercise the separate executable-run cache, not only unit caching.
        for off in ('1','0','1'):
            mode=dict(env,FPR_NO_REUSE=off,FPR_HARTS='1')
            mode.pop('FPR_NO_RUN_CACHE',None)
            out=command([ROOT/'fpr','run',ROOT/'tests/base/freshreuse.fpr',
                         '--with',ROOT/'tests/bench/costprobe.c',
                         '--with',ROOT/'tests/bench/workers_clock.c','cost'],mode).stdout
            assert json.loads(out.splitlines()[-1])['alloc_requests']==(20000 if off=='1' else 10000),out
        print('Fresh reuse: native values, alias/child preservation, field failure order, 1/4 harts, allocation ratchet, warm caches and RV64/RV32 legacy emission PASS')
if __name__=='__main__': main()
