#!/usr/bin/env python3
"""Verify result-size facts before composing source resource equations."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
STRINGS = '''make : Int -> String | size make <= {size}.
make n = substr "abcdefgh" 0 n.
combine : Int -> String{bound}.
combine n = strcat (make n) (make n).
main = print (strlen (combine 8)).
'''
DUPLICATE = '''duplicate : (xs : List Int | measure xs) -> List Int | size duplicate <= len xs.
duplicate xs = case xs of [] -> [] | x :: r -> x :: x :: duplicate r.
copy : (xs : List Int | measure xs) -> List Int.
copy xs = case xs of [] -> [] | x :: r -> x :: copy r.
combine : (xs : List Int) -> List Int | alloc combine <= 72 * len xs + 72.
combine xs = copy (duplicate xs).
main = combine [1,2,3].
'''
LIBRARY = '''L = use "std/list".
main =
  _ = print (L.length (L.repeat (-3) 7));
  _ = print (L.length (L.range 4 2));
  _ = print (L.length (L.range 4611686018427387903 4611686018427387903));
  _ = print (L.length (L.map (fn x -> x + 1) [1,2,3]));
  _ = print (L.length (L.zip [1,2,3] [4,5]));
  _ = print (L.length (L.unique [1,2,1,3,2]));
  print (L.length (L.append [1,2] [3,4,5])).
'''


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--baseline', type=Path)
    ap.add_argument('--record', type=Path)
    args = ap.parse_args()
    rows = []
    with tempfile.TemporaryDirectory(prefix='fpr-result-sizes-') as directory:
        tmp = Path(directory)
        base = {k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
        base.update(FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),XDG_CACHE_HOME=str(tmp/'cache'),
                    FPR_NO_CALL_REGIONS='1',FPR_NO_LOOP_REGIONS='1')
        def build(name, source, *, compiler=None, probe=False):
            src,exe=tmp/(name+'.fpr'),tmp/name
            src.write_text(source)
            env=dict(base)
            if probe:
                env.update(FPR_COST_PROBE='1',FPR_COST_REPORT='1')
            p=subprocess.run([compiler or ROOT/'fpr','build','--cost',src,'--harts','4','-o',exe],
                             cwd=ROOT,env=env,capture_output=True,text=True,timeout=240)
            return p,exe,env
        def diagnostic(p):
            return [line.strip() for line in p.stdout.splitlines() if ': declared ' in line]
        def run(name,exe,env,expected):
            for harts in (1,4):
                p=subprocess.run([exe],env=dict(env,FPR_HARTS=str(harts)),capture_output=True,text=True,timeout=30)
                assert p.returncode==0 and p.stdout==expected,(name,harts,p)
                row=dict(case=name,harts=harts,stdout=p.stdout)
                probe=re.search(r'\[fpr cost\] (\{.*\})',p.stderr)
                if probe:
                    row['allocation_counters']=json.loads(probe[1])
                    assert row['allocation_counters']['alloc_requests']==3 and row['allocation_counters']['alloc_bytes']==112,(name,row)
                rows.append(row)

        for name,source in [
            ('forged-string-size',STRINGS.format(size=0,bound=' | alloc combine <= 64')),
            ('false-recursive-invariant',DUPLICATE),
        ]:
            p,_,_=build(name,source)
            assert p.returncode!=0 and 'COST: ERRORS' in p.stdout,(name,p.stdout[-6000:],p.stderr)
            rows.append(dict(case=name,result='refused',diagnostics=diagnostic(p)))
            if args.baseline:
                p,old_exe,old_env=build(name+'-old',source,compiler=args.baseline,probe=(name=='forged-string-size'))
                assert p.returncode==0,(name,p.stdout[-6000:],p.stderr)
                rows.append(dict(case=name,result='incorrectly-accepted-by-baseline',diagnostics=diagnostic(p)))
                if name=='forged-string-size':
                    run('baseline-underbudget-execution',old_exe,old_env,'16\n')
        print('Forged size annotation and false recursive size invariant refused PASS',flush=True)

        for label,size in [('false-annotation',0),('correct-annotation',8)]:
            p,exe,env=build(label,STRINGS.format(size=size,bound=' | alloc combine <= 80'),probe=True)
            assert p.returncode==0,(p.stdout[-6000:],p.stderr)
            assert re.search(r'combine: declared alloc <= 80\s+derived 80\s+PROVEN',p.stdout),p.stdout
            assert re.search(r'make: declared size <= '+str(size)+r'\s+verified size <= 8',p.stdout),p.stdout
            run(label,exe,env,'16\n')
            rows.append(dict(case=label,diagnostics=diagnostic(p)))
        print('Actual substring upper bounds compose independently of annotation text on 1/4 harts PASS',flush=True)

        p,exe,env=build('library',LIBRARY)
        assert p.returncode==0,(p.stdout[-7000:],p.stderr)
        for name in ['range','repeat','reverse','append','map','indexedMap','filter','filterMap','take','drop','zip','zipWith',
                     'unique','sortWith','sortBy']:
            line=next((line for line in p.stdout.splitlines() if re.search(r'^  '+name+r'@[^:]+: declared size',line)),None)
            assert line and line.endswith('PROVEN'),(name,line,p.stdout[-7000:])
            rows.append(dict(case='library-size-proof',name=name,diagnostic=line.strip()))
        run('library',exe,env,'0\n0\n1\n3\n2\n3\n5\n')
        print('Standard list size proofs, including unique and sorting, and signed endpoints PASS',flush=True)

        source='literal = "éλ🙂\\x00\\xff".\nmain = print (strlen literal).\n'
        p,exe,env=build('byte-string',source)
        assert p.returncode==0,(p.stdout[-3000:],p.stderr)
        run('byte-string',exe,env,'10\n')
        if args.baseline:
            p,exe,env=build('byte-string-old',source,compiler=args.baseline)
            assert p.returncode==0,(p.stdout[-3000:],p.stderr)
            run('byte-string-baseline',exe,env,'10\n')
        print('UTF-8 and raw byte payload lengths preserve native outputs PASS',flush=True)
        trap='L = use "std/list".\nmain = _ = print "before"; print (L.length (L.range (0 - 4611686018427387903 - 1) (0 - 4611686018427387903 - 1))).\n'
        compilers=[('current',None)]+([('baseline',args.baseline)] if args.baseline else [])
        for label,compiler in compilers:
            p,exe,env=build('minimum-trap-'+label,trap,compiler=compiler)
            assert p.returncode==0,(p.stdout[-4000:],p.stderr)
            for harts in (1,4):
                r=subprocess.run([exe],env=dict(env,FPR_HARTS=str(harts)),capture_output=True,text=True,timeout=30)
                assert r.returncode!=0 and r.stdout=='before\n' and 'overflow' in (r.stdout+r.stderr).lower(),(label,harts,r)
                rows.append(dict(case='minimum-range-trap',compiler=label,harts=harts,stdout=r.stdout,result='overflow'))
        print('Partial-correctness size lemmas preserve endpoint overflow and its effect prefix PASS',flush=True)

    if args.record:
        sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
        args.record.write_text(json.dumps(dict(schema='verified-result-sizes-v1',compiler_sha256=sha(ROOT/'fpr'),
            baseline_sha256=sha(args.baseline) if args.baseline else None,
            sources={p:sha(ROOT/p) for p in ['compiler/Cost.hs','compiler/Resource/ResultSize.hs','compiler/Compile.hs',
                'std/list.fpr','tests/ResourceCosts.hs','tests/TypedProgram.hs','tests/check_result_sizes.py']},rows=rows,
            limits=['Result-size lemmas bound successful returns; they do not prove termination or total work.',
                    'Unproved annotations are not used; nested-container totals and unknown callback sizes remain unsupported.',
                    'Source requested-byte bounds are not physical arena/stack admission or hardware timing.']),indent=2)+'\n')

if __name__=='__main__':
    main()
