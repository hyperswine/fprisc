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
def check_execution(run,run_cost,enabled):
    for harts in (1,4):
        code,out,err=run('',harts)
        assert code==0 and out==EXPECTED,(code,out,err)
        code,out,err=run('bad',harts)
        assert code==1 and 'field failure' in out+err and 'WRONG' not in out+err,(code,out,err)
    code,out,err=run_cost('cost',1)
    assert code==0,(out,err)
    result,ledger=out.splitlines()
    ledger=json.loads(ledger)
    assert result=='100020000' and ledger['alloc_requests']==(10000 if enabled else 20000),(result,ledger)
    return ledger

NO_REGIONS={'FPR_NO_LOOP_REGIONS':'1','FPR_NO_CALL_REGIONS':'1'}
def command(args,env):
    p=subprocess.run(list(map(str,args)),cwd=ROOT,env=env,capture_output=True,text=True,timeout=300)
    assert p.returncode==0,(args,p.stdout[-2500:],p.stderr[-2500:])
    return p
def main():
    with tempfile.TemporaryDirectory(prefix='fpr-reuse-') as td:
        tmp=Path(td); exe=tmp/'reuse'
        env=dict(os.environ,FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),FPR_COST_PROBE='1',XDG_CACHE_HOME=str(tmp/'cache'))
        ghc=['cabal','exec','--','runghc'] if shutil.which('cabal') else ['runghc']
        print(command([*ghc,'-w','-icompiler','tests/ReuseCheck.hs'],env).stdout,end='',flush=True)
        for no_inline in ('0','1'):
            for no_regs in ('0',):
                for off in ('1','0','1'):
                    mode=dict(env,FPR_NO_REUSE=off,FPR_NO_INLINE=no_inline)
                    # the values are checked as built by default (loop and call
                    # regions on); the allocation ratchet counts the program's
                    # own requests, so its probe is built without the regions,
                    # whose scope records and per-slab state copies go through
                    # the same allocator (docs/2026-10-25-REGIONS-LOOPS-CALLS.md)
                    def build(out,extra):
                        command([ROOT/'fpr','build',ROOT/'tests/base/freshreuse.fpr','--harts','4',
                                 '--with',ROOT/'tests/bench/costprobe.c','--with',ROOT/'tests/bench/workers_clock.c','-o',out],dict(mode,**extra))
                    build(exe,{}); build(tmp/'reuse-cost',NO_REGIONS)
                    def runner(path):
                        def run(case,harts):
                            p=subprocess.run([str(path)]+([case] if case else []),env=dict(mode,FPR_HARTS=str(harts)),capture_output=True,text=True,timeout=90)
                            return p.returncode,p.stdout,p.stderr
                        return run
                    ledger=check_execution(runner(exe),runner(tmp/'reuse-cost'),off=='0')
                    print(f'reuse disabled={off} inline-disabled={no_inline} registers-disabled={no_regs}: {ledger["alloc_requests"]} allocations PASS',flush=True)
        # Exercise the separate executable-run cache, not only unit caching.
        for off in ('1','0','1'):
            mode=dict(env,FPR_NO_REUSE=off,FPR_HARTS='1',**NO_REGIONS)
            mode.pop('FPR_NO_RUN_CACHE',None)
            out=command([ROOT/'fpr','run',ROOT/'tests/base/freshreuse.fpr',
                         '--with',ROOT/'tests/bench/costprobe.c',
                         '--with',ROOT/'tests/bench/workers_clock.c','cost'],mode).stdout
            assert json.loads(out.splitlines()[-1])['alloc_requests']==(20000 if off=='1' else 10000),out
        print('Fresh reuse: native values, alias/child preservation, field failure order, 1/4 harts, allocation ratchet, warm caches and RV64/RV32 typed emission PASS')
if __name__=='__main__': main()
