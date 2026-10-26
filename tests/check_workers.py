#!/usr/bin/env python3
"""Worker ABI boundaries, strict effects, exact traps and allocation ratchets."""
from pathlib import Path
import json,os,re,subprocess,tempfile,shutil

ROOT=Path(__file__).resolve().parents[1]
EXPECTED=('scalar 5050; pair 55 10; escaped 55 10; actor (5050, 5150)\n'
          'poly kept 7 True; parity True False\n'
          'bounds 4611686018427387903 0 -3\nfirst\nsecond\nlater\n66\n')
def run(args,env,code=0):
    p=subprocess.run(list(map(str,args)),cwd=ROOT,env=env,capture_output=True,text=True,timeout=240)
    assert p.returncode==code,(args,p.returncode,p.stdout[-2000:],p.stderr[-4000:])
    return p

def main():
    with tempfile.TemporaryDirectory(prefix='fpr-workers-') as td:
        tmp=Path(td)
        env=dict(os.environ,FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),FPR_COST_PROBE='1',XDG_CACHE_HOME=str(tmp/'cache'))
        env.pop('FPR_FOREIGN',None)
        ghc=['cabal','exec','--','runghc'] if shutil.which('cabal') else ['runghc']
        print(run([*ghc,'-w','-icompiler','tests/WorkersCheck.hs'],env).stdout,end='')
        ledgers={}; errors={}
        for no_inline in ('0','1'):
            for no_fields,no_scalar in [('1','1'),('0','1'),('1','0'),('0','0'),('1','1')]:
                mode=dict(env,FPR_NO_FIELD_WORKERS=no_fields,FPR_NO_SCALAR_WORKERS=no_scalar,
                          FPR_NO_INLINE=no_inline,FPR_NO_SPEC='1')
                exe=tmp/'workers'
                run([ROOT/'fpr','build',ROOT/'tests/base/workers.fpr','--harts','4',
                     '--with',ROOT/'tests/bench/costprobe.c','--with',ROOT/'tests/base/workers_probe.c','-o',exe],mode)
                for workers in ('1','4'):
                    local=dict(mode,FPR_HARTS=workers)
                    assert run([exe],local).stdout==EXPECTED
                    assert run([exe,'bad-int'],local).stdout=='True\n'
                    assert run([exe,'arithmetic'],local).stdout=='True\n'
                    assert run([exe,'boolean'],local).stdout=='True\n'
                    assert run([exe,'stack'],local).stdout=='10000\n'
                    assert run([exe,'managed'],local).stdout=='gammadelta alphabeta\n'
                for case in ('scalar-cost','pair-cost','combined-cost','record-cost'):
                    lines=run([exe,case],dict(mode,FPR_HARTS='1')).stdout.splitlines()
                    ledger=json.loads(lines[-1]); n=ledger['alloc_requests']
                    if case=='scalar-cost': assert n==0,ledger
                    elif no_fields=='0': assert n<=(0 if case=='combined-cost' else 1),(no_inline,no_fields,no_scalar,case,ledger)
                    else: assert n>=10000,ledger
                    ledgers[f'{no_inline}:{no_fields}:{no_scalar}:{case}']=ledger
                for case in ('add-overflow','sub-overflow','mul-overflow','div-overflow','division-zero','field-panic','bad-pair'):
                    p=run([exe,case],dict(mode,FPR_HARTS='1'),1)
                    output=p.stdout+p.stderr
                    assert 'WRONG' not in output and 'second\n' not in output,(case,output)
                    # Ignore stack addresses/tracebacks; preserve the actual
                    # runtime panic reason, including integer operands.
                    reason=next((line[6:].strip() for line in output.splitlines() if line.startswith('[ERR] ')),None)
                    assert reason,(case,output)
                    if case in errors: assert errors[case]==reason,(case,errors[case],reason)
                    errors[case]=reason
        print('Workers: native 1/4-worker differential, independent switches/inliner, warm caches, dynamic entry and exact failure reasons PASS')
        print(json.dumps({'allocations':ledgers,'panic_reasons':errors},sort_keys=True))
        for target in ('rv64','a64','x64','rv32'):
            out=tmp/(target+'.s')
            source=ROOT/'tests/base/workers.fpr'
            if target=='rv32':
                source=tmp/'workers32.fpr'
                source.write_text((ROOT/'tests/base/workers.fpr').read_text().replace('4611686018427387903','1073741823').replace('1099511627776','1048576'))
            run([ROOT/'fpr','compile','--no-inline','--target='+target,source,out],
                dict(env,FPR_NO_FIELD_WORKERS='0',FPR_NO_SCALAR_WORKERS='0',
                     **({'FPR_TYPED_IR_BACKEND':'mixed'} if target=='a64' else {})))
            asm=out.read_text()
            present='# fn $worker.' in asm
            assert present==(target!='rv32'),target
            assert '# static-pap: $worker.' not in asm,target
            assert '# fn $worker.scalar.poly' not in asm,target
            assert '# fn $worker.fields.escapeLoop' not in asm,target
            assert not re.search(r'# native-insns-v1: \$worker\..*segmax=UNBOUNDED',asm),target
        print('Workers: A64/RV64/x64 emission, RV32 fallback, private entries and bounded fuel segments PASS')
        builtin=tmp/'builtin.fpr'; out=tmp/'builtin.s'
        builtin.write_text('profile builtin.\nloop n a = if n == 0 then a else loop (n - 1) (a + n).\nmain = loop 100 0.\n')
        run([ROOT/'fpr','compile','--target=rv64',builtin,out],env)
        assert '# fn $worker.' not in out.read_text()
        # A module containing private workers remains callable by a host
        # compiled with both optimizations disabled, through normal values.
        source=tmp/'module.fpr'
        fixture=(ROOT/'tests/base/workers.fpr').read_text()
        source.write_text('unsafe base.\n'+fixture[fixture.index('scalar :'):fixture.index('managedLoop :')])
        module=tmp/('workers.dylib' if os.uname().sysname=='Darwin' else 'workers.so')
        enabled=dict(env,FPR_NO_SCALAR_WORKERS='0',FPR_NO_FIELD_WORKERS='0')
        run([ROOT/'fpr','build',source,'--module','-o',module],enabled)
        host=tmp/'host.fpr'
        host.write_text('''unsafe base.
N = use "std/native".
R = use "std/reload".
ok r = case r of Ok u -> u | Err why -> error why.
main =
  _ = ok (N.attach "MODULE");
  sum = R.bindAt 0 "scalar"; pair = R.bindAt 0 "pairLoop";
  (a,b) = pair 10 (0,0);
  print "{sum 100 0} {a} {b}".
'''.replace('MODULE',str(module)))
        exe=tmp/'host'
        disabled=dict(env,FPR_NO_SCALAR_WORKERS='1',FPR_NO_FIELD_WORKERS='1')
        run([ROOT/'fpr','build',host,'-o',exe],disabled)
        assert run([exe],disabled).stdout=='5050 55 10\n'
        print('Workers: optimized shared module called by general-ABI host PASS')

if __name__=='__main__': main()
