#!/usr/bin/env python3
"""Finite Base field expansion beyond former depth/count/body budgets."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HEADER = 'unsafe base.\nCell a = Type (Cell a).\n'


def chain(value='x', length=32):
    return '; '.join(f'z{i} = '+(value if i == 0 else f'z{i-1}')+' + 1' for i in range(length))+f'; z{length-1}'


def nested(value, depth):
    for _ in range(depth):
        value = f'(Cell {value})'
    return value


def definition(depth, fallback=False):
    body = chain(f'x{depth-1}')
    for i in reversed(range(depth)):
        body = f'(case '+('c' if i == 0 else f'x{i-1}')+f' of Cell x{i} -> {body}'+(f' | _ -> {80+i}' if fallback else '')+')'
    return 'bump c = '+body+'.\n'


def fixture(kind, amount, count=1000, explicit=False):
    if kind == 'returns':
        source,answer=fixture('parameters',amount,count,explicit)
        helper=source.split('go n x =')[0].replace('; z31.','; (z31,z31).')
        call=('bump x'+' 0'*(amount-1)) if explicit else ('bump (Cell x)'+' (Cell 0)'*(amount-1))
        return helper+f'go n x = if n <= 0 then x else (case {call} of (a,b) -> go (n - 1) a).\nmain = print (go {count} 0).\n',answer
    if kind == 'depth':
        helper, call, step = definition(amount), 'bump '+nested('x',amount), 32
        if explicit:helper,call='bump x = '+chain()+'.\n','bump x'
    elif kind == 'parameters':
        value=' + '.join(f'x{i}' for i in range(amount))
        body=chain(value)
        for i in reversed(range(amount)):
            body=f'case c{i} of Cell x{i} -> '+body
        helper='bump '+' '.join(f'c{i}' for i in range(amount))+' = '+body+'.\n'
        call='bump (Cell x)'+' (Cell 0)'*(amount-1)
        step=32
        if explicit:
            helper='bump '+' '.join(f'x{i}' for i in range(amount))+' = '+chain(value)+'.\n'
            call='bump x'+' 0'*(amount-1)
    elif kind == 'body':
        helper='bump c = case c of Cell x -> '+chain(length=amount)+'.\n'
        call,step='bump (Cell x)',amount
        if explicit:helper,call='bump x = '+chain(length=amount)+'.\n','bump x'
    else:
        helper=''.join(f'bump{i} c = case c of Cell x -> '+chain(f'x + {i}')+'.\n' for i in range(amount))
        calls=' + '.join(f'bump{i} (Cell 0)' for i in range(amount))
        if explicit:
            helper=''.join(f'bump{i} x = '+chain(f'x + {i}')+'.\n' for i in range(amount))
            calls=' + '.join(f'bump{i} 0' for i in range(amount))
        return HEADER+helper+'main = print ('+calls+').\n',amount*(amount-1)//2+amount*32
    return HEADER+helper+f'go n x = if n <= 0 then x else go (n - 1) ({call}).\nmain = print (go {count} 0).\n',count*step


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--compiler',type=Path,default=ROOT/'fpr')
    ap.add_argument('--old',action='store_true')
    ap.add_argument('--record',type=Path)
    args=ap.parse_args();compiler=args.compiler.resolve();rows=[]
    with tempfile.TemporaryDirectory(prefix='fpr-finite-fields-') as directory:
        tmp=Path(directory)
        base={k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
        base.update(FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),XDG_CACHE_HOME=str(tmp/'cache'))

        def build(name,source,switches=None,cost=False):
            src=tmp/(name+'.fpr');src.write_text(source);exe=tmp/name
            env=dict(base,**(switches or {}))
            if cost:
                env.update(FPR_NO_CALL_REGIONS='1',FPR_NO_LOOP_REGIONS='1',FPR_COST_PROBE='1',FPR_COST_REPORT='1')
            p=subprocess.run([compiler,'build',src,'--harts','4','-o',exe],cwd=ROOT,env=env,text=True,capture_output=True,timeout=240)
            assert p.returncode==0,(name,p.stdout[-1000:],p.stderr[-5000:])
            assert 'declined round without decreasing' not in p.stdout,(name,p.stdout[-5000:])
            return exe,env

        def run(built,harts=1):
            exe,env=built
            return subprocess.run([exe],env=dict(env,FPR_HARTS=str(harts)),text=True,capture_output=True,timeout=60)

        for kind,amount in [('depth',5),('depth',8),('depth',16),('parameters',8),('parameters',16),
                            ('parameters',32),('parameters',64),('returns',8),('helpers',129),('body',256),('body',2048)]:
            name=f'{kind}-{amount}';source,answer=fixture(kind,amount)
            costs={}
            for mode,switches in [('default',{}),('boxed',{'FPR_NO_FIELD_WORKERS':'1'}),('explicit',{})]:
                text=fixture(kind,amount,explicit=True)[0] if mode=='explicit' else source
                built=build(name+'-'+mode,text,switches,True)
                for harts in (1,4):
                    p=run(built,harts);assert p.returncode==0 and p.stdout==f'{answer}\n',(name,mode,harts,p)
                    cost=json.loads(re.search(r'\[fpr cost\] (\{.*\})',p.stderr)[1]);costs[mode]=cost['alloc_requests']
                    rows.append(dict(case=name,mode=mode,harts=harts,cost=cost,stdout=p.stdout))
                built=build(name+'-regions-'+mode,text,switches)
                for harts in (1,4):
                    p=run(built,harts);assert p.returncode==0 and p.stdout==f'{answer}\n' and not p.stderr,(name,mode,harts,p)
            assert costs['default']>0 if args.old else costs['default']==0,(name,costs)
            assert costs['explicit']==0,(name,costs)
            assert costs['boxed']>=costs['default'] and costs['boxed']>0,(name,costs)
            print(f'{name}: {costs}, normal regions and 1/4 harts PASS',flush=True)

        # x64's allocator scratches (r10, r11) are the inline bump's own slab
        # and hart registers. A cell whose destination is spilled must be
        # built in a borrowed register: with 16 boxed parameters one is, and
        # the fast path used to overwrite its slab with the cell (a fault on
        # macOS, a hang on Linux). Compile-only, so every host checks it.
        source,_=fixture('parameters',16);src=tmp/'bump-spill.fpr';src.write_text(source);asm=tmp/'bump-spill.s'
        p=subprocess.run([compiler,'compile','--system=posix','--target=x64',f'--prelude={ROOT}/core/prelude.fpr',src,asm],
                         cwd=ROOT,env=dict(base,FPR_NO_FIELD_WORKERS='1'),text=True,capture_output=True,timeout=240)
        assert p.returncode==0,(p.stdout[-1000:],p.stderr[-3000:])
        text=asm.read_text()
        assert not re.search(r'\(%r10\), %r1[01]\n\s+addq \$\d+, %r1[01]\n',text),'x64 inline bump builds a cell in its own scratch'
        borrowed=len(re.findall(r'pushq %rax\n\s+movq \d+\(%r11\), %r10\n',text))
        assert borrowed>=1,'the fixture no longer spills a bump destination on x64; pick one that does'
        print(f'x64 inline bump: {borrowed} spilled cell destination(s) built in a borrowed register PASS',flush=True)

        depth=8;maxint=4611686018427387903
        effects=nested('(print "payload" >> 7)',depth)
        cases={
          'let-order':('v = '+effects+'; _ = print "between"; print (bump v)','payload\nbetween\n39\n',None),
          'max-success':('print (bump '+nested(f'({maxint} - 32)',depth)+')',f'{maxint}\n',None),
          'min-success':('print (bump '+nested(f'(0 - {maxint} - 1)',depth)+')',f'{-maxint-1+32}\n',None),
          'overflow':('print (bump '+nested(f'(print "before" >> {maxint})',depth)+') >> print "WRONG"','before\n','overflow'),
          'minimum-underflow':('print (bump '+nested(f'(print "before" >> (0 - {maxint} - 1 - 1))',depth)+') >> print "WRONG"','before\n','overflow'),
          'division-first':('print (bump '+nested('(print "before" >> (1 / 0))',depth)+') >> print "WRONG"','before\n','division by zero'),
        }
        cases['wide-argument-order']=('print (bump (Cell (print "first" >> 1)) (Cell (print "second" >> (1 / 0))) (Cell (print "WRONG" >> 3))'+' (Cell 0)'*5+')','first\nsecond\n','division by zero')
        for name,(main,expected,error) in cases.items():
            helper=fixture('parameters',8)[0].split('go n x =')[0] if name=='wide-argument-order' else HEADER+definition(depth)
            source=helper+'main = '+main+'.\n';outcomes=[]
            for mode,switches in [('default',{}),('boxed',{'FPR_NO_FIELD_WORKERS':'1'}),
                                   ('tuple-off',{'FPR_NO_TUPLE_SCALARS':'1'}),('no-inline',{'FPR_NO_INLINE':'1'})]:
                p=run(build(name+'-'+mode,source,switches))
                assert p.stdout==expected,(name,mode,p)
                assert (p.returncode!=0 and error in p.stderr) if error else (p.returncode==0 and not p.stderr),(name,mode,p)
                outcomes.append((p.returncode,p.stdout,p.stderr))
            assert len(set(outcomes))==1,(name,outcomes)
            rows.append(dict(case=name,modes=4,returncode=outcomes[0][0],stdout=outcomes[0][1],stderr=outcomes[0][2]))
            print(name+': exact four-mode effects/traps PASS',flush=True)
        source=(HEADER+definition(depth,True).replace('bump c =','bump c = _ = print "entry";')+'receiver parent self = v = receive self; send parent (bump v).\n'
                'main = _ = print (bump '+nested('7',depth)+'); me = myself 0; a = spawnOn 0 (receiver me); '
                '_ = send a '+nested('7',5)+'; print (receiveFrom me a).\n')
        for mode,switches in [('default',{}),('boxed',{'FPR_NO_FIELD_WORKERS':'1'})]:
            built=build('dynamic-'+mode,source,switches)
            for harts in (1,4):
                p=run(built,harts);assert p.returncode==0 and p.stdout=='entry\n39\nentry\n85\n' and not p.stderr,(mode,harts,p)
                rows.append(dict(case='inner-message-fallback',mode=mode,harts=harts,stdout=p.stdout))
        print('Deep dynamic payload retains the original inner fallback PASS',flush=True)
        if args.record:
            sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
            args.record.write_text(json.dumps(dict(compiler_sha256=sha(compiler),test_sha256=sha(Path(__file__)),old=args.old,rows=rows),indent=2)+'\n')


if __name__=='__main__':main()
