#!/usr/bin/env python3
"""Private consuming calls: differential values, ownership, cost and ABI gates."""
from pathlib import Path
import os, subprocess, tempfile, json
ROOT=Path(__file__).resolve().parents[1]
EXPECTED='''{left = 11, right = 10}
{left = 11, right = 10}
{left = 13, right = 12}
{left = 10, right = 11}
({left = 10, right = 11}, {left = 11, right = 10})
({left = 10, right = 11}, {left = 11, right = 10})
([10], [11, 10])
({left = 10, right = 11}, {left = 11, right = 10})
{left = 11, right = 10}
{left = 10, right = 11}
left
right
{left = 2, right = 1}
'''
def check_execution(run,enabled):
    for harts in (1,4):
        code,out,err=run('',harts)
        assert code==0 and out==EXPECTED,(code,out,err)
        code,out,err=run('bad',harts)
        assert code==1 and 'consume failure' in out+err and 'WRONG' not in out+err,(code,out,err)
    code,out,err=run('cost',1)
    assert code==0,(out,err)
    value,ledger=out.splitlines(); ledger=json.loads(ledger)
    assert value=='100020000' and ledger['alloc_requests']==(10000 if enabled else 20000),(value,ledger)
    return ledger

def main():
    with tempfile.TemporaryDirectory(prefix='fpr-consuming-') as td:
        tmp=Path(td);exe=tmp/'probe'
        env=dict(os.environ,FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),FPR_COST_PROBE='1',XDG_CACHE_HOME=str(tmp/'cache'))
        def command(args,mode):
            p=subprocess.run(list(map(str,args)),cwd=ROOT,env=mode,capture_output=True,text=True,timeout=300)
            assert p.returncode==0,(args,p.stdout[-2000:],p.stderr[-2000:])
            return p
        for inline in ('1','0'):
            for regs in ('1','0'):
                for off in ('1','0','1'):
                    mode=dict(env,FPR_NO_REUSE=off,FPR_NO_INLINE=inline,FPR_NO_REGISTERS=regs)
                    command([ROOT/'fpr','build',ROOT/'tests/base/consumingreuse.fpr','--harts','4',
                        '--with',ROOT/'tests/bench/costprobe.c','--with',ROOT/'tests/bench/workers_clock.c','-o',exe],mode)
                    def run(case,harts):
                        p=subprocess.run([str(exe)]+([case] if case else []),env=dict(mode,FPR_HARTS=str(harts)),capture_output=True,text=True,timeout=90)
                        return p.returncode,p.stdout,p.stderr
                    ledger=check_execution(run,off=='0')
                    print(f'consuming reuse off={off} no-inline={inline} no-registers={regs}: {ledger["alloc_requests"]} allocations PASS',flush=True)
        for target in ('a64','rv64','x64','rv32'):
            for off in ('0','1'):
                asm=tmp/'probe.s'
                command([ROOT/'fpr','compile','--target='+target,ROOT/'tests/base/consumingreuse.fpr',asm],dict(env,FPR_NO_REUSE=off,FPR_NO_INLINE='1'))
                text=asm.read_text()
                assert ('# private consuming workers: 0' not in text and '# private consuming workers:' in text)==(off=='0' and target!='rv32'),(target,off)
                assert '# static-pap: $worker.consume.' not in text
        # Public dynamic calls still borrow, even when the library has a
        # private consuming version selected by a different internal caller.
        source=tmp/'module.fpr'
        source.write_text('unsafe base.\nRow={left:Int,right:Int}.\nswap r={left=r.right,right=r.left}.\nentry n=r={left=n,right=n+1}; swap r.\n')
        module=tmp/('reuse.dylib' if os.uname().sysname=='Darwin' else 'reuse.so')
        enabled=dict(env,FPR_NO_REUSE='0',FPR_NO_INLINE='1')
        command([ROOT/'fpr','build',source,'--module','-o',module],enabled)
        host=tmp/'host.fpr'
        host.write_text('''unsafe base.
N=use "std/native".
R=use "std/reload".
Row={left:Int,right:Int}.
ok r=case r of Ok u -> u | Err why -> error why.
main = _=ok (N.attach "MODULE"); swap=R.bindAt 0 "swap"; entry=R.bindAt 0 "entry";
 r={left=10,right=11}; u=swap r; _=print (r,u); print (entry 10).
'''.replace('MODULE',str(module)))
        disabled=dict(env,FPR_NO_REUSE='1')
        command([ROOT/'fpr','build',host,'-o',exe],disabled)
        assert command([exe],disabled).stdout=='({left = 10, right = 11}, {left = 11, right = 10})\n{left = 11, right = 10}\n'
        fallback=tmp/'fallback.fpr'
        fallback.write_text('profile builtin.\nmain = r=(1,2); (a,b)=r; (b,a).\n')
        for flags in ([],['--arc']):
            command([ROOT/'fpr','compile',*flags,fallback,tmp/'fallback.s'],enabled)
            assert '# private consuming workers:' not in (tmp/'fallback.s').read_text()
        print('Consuming workers: aliases, branch joins, retained originals, shared list tails, ordered failures, allocation counts, 1/4 harts and four-target ABI gates PASS')
if __name__=='__main__':main()
