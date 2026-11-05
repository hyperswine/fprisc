#!/usr/bin/env python3
"""Multiple/nested checked Base parameters: allocations, strictness and boundaries."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from check_base_products import chain

ROOT = Path(__file__).resolve().parents[1]
HEADER = 'unsafe base.\nCell a = Type (Cell a).\n'
NUMERIC = {
    'multiple': ('bump a b = case a of Cell x -> case b of Cell y -> '+chain('x + y')+'.\n',
                 'bump (Cell x) (Cell 0)', 1000, 0),
    'nested': ('bump a = case a of Cell inner -> case inner of Cell x -> '+chain()+'.\n',
               'bump (Cell (Cell x))', 1000, 0),
    'mixed': ('bump a b = case a of Cell innerA -> case innerA of Cell x -> '
             'case b of Cell innerB -> case innerB of Cell y -> '+chain('x + y')+'.\n',
              'bump (Cell (Cell x)) (Cell (Cell 0))', 3000, 0),
    'four-parameters': ('bump a b c d = case a of Cell w -> case b of Cell x -> '
                        'case c of Cell y -> case d of Cell z -> '+chain('w + x + y + z')+'.\n',
                        'bump (Cell x) (Cell 0) (Cell 0) (Cell 0)', 3000, 0),
    'tuple-tree': ('bump p = case p of ((a,b),(c,d)) -> '+chain('a + b + c + d')+'.\n',
                   'bump ((x,0),(0,0))', 2000, 0),
    'record-tree': ('bump : unsafe {inner : {left : Int, right : Int}, tag : Int} -> Int.\n'
                    'bump p = '+chain('p.inner.left + p.inner.right + p.tag')+'.\n',
                    'bump {inner = {left = x, right = 0}, tag = 0}', 1000, 0),
    # The former four-round cutoff left one box here. Finite structural
    # progress now admits the fifth step while retaining the public fallback.
    'depth-limit': ('bump a = case a of Cell b -> case b of Cell c -> case c of Cell d -> '
                    'case d of Cell e -> case e of Cell x -> '+chain()+'.\n',
                    'bump (Cell (Cell (Cell (Cell (Cell x)))))', 4000, 0),
}


def numeric_source(kind, count=1000):
    definition, call, _, _ = NUMERIC[kind]
    return HEADER+definition+f'go n x = if n <= 0 then x else go (n - 1) ({call}).\nmain = print (go {count} 0).\n'


def explicit_source(kind, count=1000):
    if kind in ('multiple', 'mixed'):
        params, value, call = 'x y', 'x + y', 'bump x 0'
    elif kind in ('four-parameters', 'tuple-tree'):
        params, value, call = 'w x y z', 'w + x + y + z', 'bump x 0 0 0'
    elif kind == 'record-tree':
        params, value, call = 'x y z', 'x + y + z', 'bump x 0 0'
    else:
        params, value, call = 'x', 'x', 'bump x'
    return ('unsafe base.\nbump '+params+' = '+chain(value)+'.\n'
            f'go n x = if n <= 0 then x else go (n - 1) ({call}).\nmain = print (go {count} 0).\n')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--compiler', type=Path, default=ROOT/'fpr')
    ap.add_argument('--old', action='store_true')
    ap.add_argument('--record', type=Path)
    args = ap.parse_args()
    compiler = args.compiler.resolve()
    rows = []
    with tempfile.TemporaryDirectory(prefix='fpr-base-product-trees-') as directory:
        tmp = Path(directory)
        base = {k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
        base.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=str(tmp/'cache'))

        def build(name, source, switches=None, isolated=False, probe=False):
            env = dict(base, **(switches or {}))
            if isolated:
                env.update(FPR_NO_LOOP_REGIONS='1', FPR_NO_CALL_REGIONS='1')
            if probe:
                env.update(FPR_COST_PROBE='1', FPR_COST_REPORT='1')
            src, exe = tmp/(name+'.fpr'), tmp/name
            src.write_text(source)
            p = subprocess.run([compiler,'build',src,'--harts','4','-o',exe], cwd=ROOT, env=env,
                               text=True,capture_output=True,timeout=180)
            assert p.returncode == 0, (name,p.stdout[-2000:],p.stderr[-5000:])
            return exe,env

        def execute(built, harts=1):
            exe,env = built
            return subprocess.run([exe],env=dict(env,FPR_HARTS=str(harts)),text=True,capture_output=True,timeout=60)

        def check(name, source, expected, before, after):
            expected_cost = before if args.old else after
            counts = {}
            for label,switches in [('default',{}),('boxed',{'FPR_NO_FIELD_WORKERS':'1'})]:
                built = build(name+'-'+label,source,switches,True,True)
                for harts in (1,4):
                    p = execute(built,harts)
                    assert p.returncode==0 and p.stdout==expected,(name,label,harts,p)
                    cost=json.loads(re.search(r'\[fpr cost\] (\{.*\})',p.stderr)[1])
                    if label=='default':
                        assert cost['alloc_requests']==expected_cost,(name,cost,expected_cost)
                    counts[label]=cost['alloc_requests']
                    rows.append(dict(case=name,mode=label,harts=harts,cost=cost,stdout=p.stdout))
                normal=build(name+'-regions-'+label,source,switches)
                for harts in (1,4):
                    p=execute(normal,harts)
                    assert p.returncode==0 and p.stdout==expected and not p.stderr,(name,label,harts,p)
                    rows.append(dict(case=name,mode=label,harts=harts,regions='normal',stdout=p.stdout))
            assert counts['boxed']>=counts['default'],(name,counts)
            print(f'{name}: {counts}, normal regions and 1/4 harts PASS',flush=True)

        for name,(_,_,before,after) in NUMERIC.items():
            check(name,numeric_source(name),'32000\n',before,after)
        generic=(HEADER+'retainCells a b = case a of Cell x -> case b of Cell n -> '+
                 chain('n','if y31 >= 0 then x else error "negative"')+'.\n'
                 'go n x = if n <= 0 then x else go (n - 1) (retainCells (Cell x) (Cell n)).\n')
        check('generic-string',generic+'main = print (go 1000 "retained").\n','retained\n',1000,0)
        check('generic-list',generic+'main = print (go 1000 [7,8]).\n','[7, 8]\n',1002,2)
        (tmp/'module.fpr').write_text(numeric_source('mixed').split('main =')[0])
        check('owning-module','unsafe base.\nM = use "./module".\nmain = print (M.go 1000 0).\n','32000\n',3000,0)

        # An outer tag match must not turn an invalid inner value into an
        # unchecked projection. The public entry keeps both pattern fallbacks.
        nested=(HEADER+'bump a = case a of Cell inner -> (case inner of Cell x -> '+chain()+
                ' | _ -> 88) | _ -> 99.\n')
        receiver=(nested+'receiver parent self = x = receive self; send parent (bump x).\n'
                  'main = _ = print (bump (Cell (Cell 0))); me = myself 0; '
                  'a = spawnOn 0 (receiver me); _ = send a (Cell 7); print (receiveFrom me a).\n')
        for label,switches in [('default',{}),('boxed',{'FPR_NO_FIELD_WORKERS':'1'})]:
            built=build('inner-fallback-'+label,receiver,switches)
            for harts in (1,4):
                p=execute(built,harts)
                assert p.returncode==0 and p.stdout=='32\n88\n' and not p.stderr,p
                rows.append(dict(case='inner-message-fallback',mode=label,harts=harts,stdout=p.stdout))
        print('Wrong inner actor payload preserves the original fallback PASS',flush=True)

        multi=HEADER+NUMERIC['multiple'][0]
        maxint=4611686018427387903
        cases={
            'multiple-effects':(multi+'main = print (bump (Cell (print "left" >> 1)) (Cell (print "right" >> 2))).\n',
                                'left\nright\n35\n',None),
            'nested-effects':(nested+'main = print (bump (Cell (print "outer" >> (Cell (print "inner" >> 1))))).\n',
                              'outer\ninner\n33\n',None),
            'let-before-call':(multi+'main = a = Cell (print "left" >> 1); _ = print "between"; '
                               'print (bump a (Cell (print "right" >> 2))).\n','left\nbetween\nright\n35\n',None),
            'later-argument-trap':(multi+'main = print (bump (Cell (print "left" >> 1)) (Cell (print "right" >> (1 / 0)))).\n',
                                   'left\nright\n','division by zero'),
            'first-trap':(multi+f'main = print (bump (Cell (print "left" >> ({maxint} + 1))) '
                          '(Cell (print "WRONG" >> (1 / 0)))).\n','left\n','overflow'),
            'minimum':(multi+f'main = print (bump (Cell (print "left" >> (0 - {maxint} - 1))) '
                       '(Cell (print "right" >> (0 - 1)))).\n','left\nright\n','overflow'),
            'bounds':(nested+f'main = print (bump (Cell (Cell ({maxint} - 32)))) >> '
                      f'print (bump (Cell (Cell (0 - {maxint} - 1)))).\n',f'{maxint}\n{-maxint-1+32}\n',None),
        }
        for name,(source,expected,reason) in cases.items():
            outcomes=[]
            for label,switches in [('default',{}),('boxed',{'FPR_NO_FIELD_WORKERS':'1'}),
                                   ('tuple-off',{'FPR_NO_TUPLE_SCALARS':'1'}),('no-inline',{'FPR_NO_INLINE':'1'})]:
                p=execute(build(name+'-'+label,source,switches))
                assert p.stdout==expected,(name,label,p)
                assert (p.returncode!=0 and reason in p.stderr) if reason else (p.returncode==0 and not p.stderr),(name,label,p)
                outcomes.append((p.returncode,p.stdout,p.stderr))
            assert len(set(outcomes))==1,(name,outcomes)
            rows.append(dict(case=name,modes=4,returncode=outcomes[0][0],stdout=outcomes[0][1],stderr=outcomes[0][2]))
            print(name+': exact four-mode effects/traps PASS',flush=True)
        if args.record:
            digest=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
            args.record.write_text(json.dumps(dict(compiler_sha256=digest(compiler),test_sha256=digest(Path(__file__)),
                fixture_sha256=digest(ROOT/'tests/check_base_products.py'),old=args.old,cases=rows),indent=2)+'\n')


if __name__=='__main__':
    main()
