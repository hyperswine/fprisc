#!/usr/bin/env python3
"""Differential fixed-width accumulator checks, reusable on physical targets."""
from pathlib import Path
import json, os, re, subprocess, tempfile

ROOT = Path(__file__).resolve().parents[1]
WIDTHS = (3, 4, 8, 16, 63, 64)

def fixture():
    source = '''unsafe base.
Cost.begin : Unit -> Unit .
Cost.report : Unit -> String .
Bench.start : Unit -> Unit .
Bench.elapsed : Unit -> Int .
apply2 f x y = f x y.
'''
    cases = []
    for width in WIDTHS:
        names = [f'a{k}' for k in range(width)]
        tup = lambda xs: '(' + ','.join(xs) + ')'
        rec = lambda xs: '{' + ','.join(f'{k} = {v}' for k, v in zip(names,xs)) + '}'
        for kind, product, pattern, typ in (
            ('tuple', tup, tup(names), tup(['Int']*width)),
            ('record', rec, '{'+','.join(names)+'}', '{'+','.join(f'{n} : Int' for n in names)+'}')):
            name = f'{kind}{width}'
            source += f'''{name} : unsafe Int -> {typ} -> {typ} .
{name} n {pattern} = if n == 0 then {product(names)}
  else {name} (n - 1) {product([f'{n} + {i+1}' for i,n in enumerate(names)])}.
'''
            result = (' + '.join(names) if kind == 'tuple' else ' + '.join(f'r.{n}' for n in names))
            bind = (tup(names) if kind == 'tuple' else 'r')
            for prefix, count, call in [('cost',10000,name),('dynamic',101,'apply2 '+name),('bench',1000000,name)]:
                before = 'Cost.begin' if prefix == 'cost' else 'Bench.start'
                after = 'Cost.report' if prefix == 'cost' else 'Bench.elapsed'
                cases.append(f'''["{prefix}-{name}"] ->
      _ = {before} Unit; {bind} = {call} {count} {product(['0']*width)};
      stats = {after} Unit; _ = print ({result}); print stats''')
    source += '''managed : unsafe Int -> (String,String,String,String,String,String,String,String) -> (String,String,String,String,String,String,String,String) .
managed n (a,b,c,d,e,f,g,h) = if n == 0 then (a,b,c,d,e,f,g,h)
  else managed (n - 1) (b,c,d,e,f,g,h,a).
stack n (a,b,c,d,e,f,g,h) = if n == 0 then a+b+c+d+e+f+g+h
  else 1 + stack (n - 1) (b,c,d,e,f,g,h,a).
effects n (a,b,c,d,e,f,g,h) later = if n == 0 then a+b+c+d+e+f+g+h+later
  else effects (n - 1) (a,b,c,d,e,f,g,h) later.
mark n = _ = print n; n.
boom = error "wide field panic".
wrong = _ = print "WRONG"; 0.
actor parent self =
  value = managed 10001 ("a"+"A","b"+"B","c"+"C","d"+"D","e"+"E","f"+"F","g"+"G","h"+"H");
  _ = send parent value; Unit.
'''
    cases.extend(['''["managed"] ->
      (a,b,c,d,e,f,g,h) = apply2 managed 10001 ("a"+"A","b"+"B","c"+"C","d"+"D","e"+"E","f"+"F","g"+"G","h"+"H");
      print "{a} {b} {c} {d} {e} {f} {g} {h}"''',
      '''["actor"] ->
      me = myself 0; child = spawn (actor me); msg = receiveFrom me child; saved = keep msg;
      (a,b,c,d,e,f,g,h) = saved; print "{a} {b} {c} {d} {e} {f} {g} {h}"''',
      '["stack"] -> print (stack 10000 (1,1,1,1,1,1,1,1))',
      '["effects"] -> print (effects (mark 0) (mark 1,mark 2,mark 3,mark 4,mark 5,mark 6,mark 7,mark 8) (mark 9))',
      '["panic"] -> print (effects (mark 0) (mark 1,mark 2,mark 3,mark 4,mark 5,mark 6,boom,wrong) wrong)',
      '_ -> print "wide workers"'])
    return source + 'main = case Sys.args Unit of\n    ' + '\n  | '.join(cases) + '.\n'

def check_execution(run, fields):
    """run(case,harts) returns (status,stdout,stderr); works over SSH too."""
    ledgers = {}
    for harts in (1,4):
        for width in WIDTHS:
            for kind in ('tuple','record'):
                name = f'{kind}{width}'
                for prefix,count in [('cost',10000),('dynamic',101)]:
                    code,out,err = run(f'{prefix}-{name}',harts)
                    assert code == 0, (name,code,out,err)
                    lines = out.splitlines()
                    assert int(lines[0]) == count*width*(width+1)//2, (name,lines)
                    if prefix == 'cost':
                        ledger=json.loads(lines[1]); n=ledger['alloc_requests']
                        if fields and width<=63: assert n<=1,(name,ledger)
                        else: assert n>=10000,(name,ledger)
                        ledgers[f'{name}:{harts}']=ledger
        for case,want in [('managed','bB cC dD eE fF gG hH aA\n'),
                          ('actor','bB cC dD eE fF gG hH aA\n'),
                          ('stack','10008\n'),
                          ('effects','0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n45\n')]:
            code,out,err=run(case,harts)
            assert code==0 and out==want,(case,harts,code,out,err)
        code,out,err=run('panic',harts)
        assert code==1 and 'WRONG' not in out+err,(code,out,err)
        assert out.startswith('0\n1\n2\n3\n4\n5\n6\n'),out
        reason=next(line[6:].strip() for line in (out+err).splitlines() if line.startswith('[ERR] '))
        assert reason=='wide field panic',reason
    return ledgers

def command(args,env):
    p=subprocess.run(list(map(str,args)),cwd=ROOT,env=env,text=True,capture_output=True,timeout=300)
    assert p.returncode==0,(args,p.stdout[-2000:],p.stderr[-4000:])
    return p

def main():
    with tempfile.TemporaryDirectory(prefix='fpr-wide-workers-') as td:
        tmp=Path(td); source=tmp/'wide.fpr';source.write_text(fixture())
        base=dict(os.environ,FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),FPR_COST_PROBE='1',FPR_NO_SPEC='1',XDG_CACHE_HOME=os.environ.get('XDG_CACHE_HOME', str(tmp/'cache')))
        base.pop('FPR_FOREIGN',None)
        results={}
        for inline in ('0','1'):
            for fields,scalar in [('1','1'),('0','1'),('1','0'),('0','0'),('1','1')]:
                env=dict(base,FPR_NO_INLINE=inline,FPR_NO_FIELD_WORKERS=fields,FPR_NO_SCALAR_WORKERS=scalar)
                exe=tmp/'wide'
                command([ROOT/'fpr','build',source,'--harts','4','--with',ROOT/'tests/bench/costprobe.c','--with',ROOT/'tests/bench/workers_clock.c','-o',exe],env)
                def run(case,harts):
                    p=subprocess.run([str(exe),case],env=dict(env,FPR_HARTS=str(harts)),capture_output=True,text=True,timeout=60)
                    return p.returncode,p.stdout,p.stderr
                results[f'{inline}:{fields}:{scalar}']=check_execution(run,fields=='0')
                print(f'wide workers inline-disabled={inline} fields-disabled={fields} scalar-disabled={scalar}: PASS',flush=True)
        for target in ('rv64','a64','x64','rv32'):
            out=tmp/(target+'.s')
            command([ROOT/'fpr','compile','--no-inline','--target='+target,source,out],dict(base,FPR_NO_FIELD_WORKERS='0',FPR_NO_SCALAR_WORKERS='0',
                **({'FPR_TYPED_IR_BACKEND':'mixed'} if target=='a64' else {})))
            asm=out.read_text()
            for kind in ('tuple','record'):
                for width in WIDTHS:
                    selected=f'# fn $worker.fields.{kind}{width} ' in asm
                    assert selected==(target!='rv32' and width<64),(target,kind,width)
            assert '# static-pap: $worker.' not in asm
            assert not re.search(r'# wcet: \$worker\..*segmax=UNBOUNDED',asm)
        enabled=dict(base,FPR_NO_FIELD_WORKERS='0',FPR_NO_SCALAR_WORKERS='0')
        module_source=tmp/'module.fpr'
        module_source.write_text(fixture().split('managed :')[0])
        module=tmp/('wide.dylib' if os.uname().sysname=='Darwin' else 'wide.so')
        command([ROOT/'fpr','build',module_source,'--module','-o',module],enabled)
        host=tmp/'host.fpr'
        host.write_text('''unsafe base.
N = use "std/native".
R = use "std/reload".
ok r = case r of Ok u -> u | Err why -> error why.
main =
  _ = ok (N.attach "MODULE");
  tuple = R.bindAt 0 "tuple8"; record = R.bindAt 0 "record4";
  (a,b,c,d,e,f,g,h) = tuple 1 (0,0,0,0,0,0,0,0);
  r = record 1 {a0 = 0, a1 = 0, a2 = 0, a3 = 0};
  print "{a+b+c+d+e+f+g+h} {r.a0+r.a1+r.a2+r.a3}".
'''.replace('MODULE',str(module)))
        disabled=dict(base,FPR_NO_FIELD_WORKERS='1',FPR_NO_SCALAR_WORKERS='1')
        host_exe=tmp/'host'
        command([ROOT/'fpr','build',host,'-o',host_exe],disabled)
        assert command([host_exe],disabled).stdout=='36 10\n'
        print('wide workers optimized shared module called by general ABI host: PASS')
        arc=tmp/'arc.s'
        arc_source=tmp/'arc.fpr'
        arc_source.write_text('profile builtin.\nloop n (a,b,c,d) = if n == 0 then (a,b,c,d) else loop (n - 1) (a+1,b+2,c+3,d+4).\nmain = loop 100 (0,0,0,0).\n')
        command([ROOT/'fpr','compile','--arc',arc_source,arc],enabled)
        assert '# fn $worker.' not in arc.read_text()
        print('wide workers native differential, allocation, effects, actor ownership, stack, 64-argument boundary and four-target emission: PASS')
        print(json.dumps(results,sort_keys=True))

if __name__=='__main__': main()
