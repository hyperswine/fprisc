#!/usr/bin/env python3
"""Check the private scalar representation at a separately emitted wrapper definition."""
import argparse
import json
import os
from pathlib import Path
import re
import tempfile

from check_product_returns import ROOT, run
import check_base_carrier as local

MODULE=ROOT/"tests/base/carrier_meters.fpr"
LIB=MODULE.read_text()
def bundled(source):
    return source.replace('use "carrier_meters"', 'use "tests/base/carrier_meters"')


HEADER = 'unsafe base.\nMap = use "std/map".\nM = use "carrier_meters".\n'
MAIN = 'main = print (check 512).\n'

def workload(form):
    body=local.workload(form=="explicit").removeprefix(local.HEADER)
    if form=="api":
        body=body.replace("Meters n","M.pack n").replace("case value of Meters x -> a + x","a + M.value value")
    elif form=="constructor":
        body=body.replace("Meters n","M.Meters n").replace("Meters x ->","M.Meters x ->")
    return HEADER+body

CONTROL=workload("api")+"""put n d m = if n <= 0 then m else put (n - 1) d (Map.insert n (M.packChecked n d) m).
readSum a k v = a + M.readChecked v.
checked n d = m = put n d Map.ints; Map.fold readSum 0 m.
readSeen a k v = a + M.observe v.
showAll n = m = fill n Map.ints; Map.fold readSeen 0 m.
addEdge a k v = a + M.value v.
edgeBuild n m = if n > 0 then Map.insert 1 (M.pack n) m else Map.insert 2 (M.pack n) m.
edge n = m = edgeBuild n Map.ints; Map.fold addEdge 0 m.
give n = fill n Map.ints.
child parent self = n = receive self; send parent (give n).
main = case Sys.args Unit of
  ["effects"] -> print (checked 3 2)
  | ["divide"] -> print (checked 3 0)
  | ["observes"] -> print (showAll 2)
  | ["max"] -> print (edge 4611686018427387903)
  | ["min"] -> print (edge (0 - 4611686018427387903 - 1))
  | ["overflow"] -> print (checked 4611686018427387903 1)
  | ["actor"] -> p = myself 0; a = spawn (child p); _ = send a 2; m = receiveFrom p a; print (Map.getOr (M.pack 0) 2 m)
  | _ -> print (check 3).
"""
CASES={"effects":("3\n2\n1\n6\n7\n8\n21\n",None),"divide":("3\n","division by zero"),
       "observes":("Meters 1\nMeters 2\n3\n",None),"max":("4611686018427387903\n",None),
       "min":("-4611686018427387904\n",None),"overflow":("4611686018427387903\n","Int overflow"),
       "actor":("Meters 2\n",None),"ordinary":("12\n",None)}
REGIONAL=local.REGIONAL.replace(local.HEADER,HEADER).replace("Meters (Carrier.payload n)","M.pack (Carrier.payload n)").replace("case value of Meters x ->","x = M.value value;")
HAL=ROOT/"tests/base/carrier_region.c"
BASELINE=ROOT/"bench/2026-11-05-map-imported-wrapper-before.json"

def check(target,record):
    rows=[]
    baseline=json.loads(BASELINE.read_text())["rows"]
    with tempfile.TemporaryDirectory(prefix="fpr-imported-carriers-") as folder:
        tmp=Path(folder)
        env={k:v for k,v in os.environ.items() if not k.startswith("FPR_")}
        env.update(FPR_HOME=str(ROOT), FPR_PATH=os.pathsep.join([str(tmp),str(ROOT)]), XDG_CACHE_HOME=str(tmp/"cache"))
        lib=tmp/"carrier_meters.fpr"
        lib.write_text(LIB)
        def build(name,src,flags,hal=None,module=False):
            path=tmp/(name+".fpr")
            path.write_text(src)
            exe=tmp/(name+(".dylib" if os.uname().sysname=="Darwin" else ".so") if module else name+".exe")
            command=[ROOT/"fpr","build",path,"--keep","-o",exe,*(["--module"] if module else ["--harts","4"])]
            if target: command.append("--target="+target)
            if hal: command.extend(["--with",hal])
            q=run(command,dict(env,**flags))
            assert q.returncode==0,q.stderr
            assembly,=(tmp/"cache/fpr/build").glob(name+"-*.s")
            units=Path(str(assembly)+".units").read_text().splitlines()
            workers=[re.findall(r"^# fn (\$carrier\.\S+) ",p.read_text(),re.M) for p in [assembly,*map(Path,units)]]
            assembly.unlink()
            return exe,workers
        def execute(exe,case,stdout,trap=None,argv=(),expected_cost=None,**metadata):
            for h in (1,4):
                q=run([exe,*argv],dict(env,FPR_HARTS=str(h),FPR_COST_REPORT="1"))
                assert q.stdout==stdout and bool(q.returncode)==bool(trap),(case,q)
                row=dict(case=case,harts=h,binary_sha256=local.digest(exe),stdout=stdout,trap=trap,**metadata)
                if trap: assert trap in q.stderr,(case,q)
                if expected_cost:
                    cost=json.loads(re.search(r'\[fpr cost\] (\{.*\})',q.stderr)[1])
                    actual=(cost["alloc_requests"],cost["alloc_bytes"])
                    assert actual==expected_cost,(row,actual,expected_cost)
                    row.update(allocations=actual[0],allocated_bytes=actual[1])
                rows.append(row)
        for inline in (False,True):
            for enabled in (False,True):
                flags=dict(FPR_NO_INLINE=str(int(not inline)),FPR_NO_TYPE_SPEC=str(int(not enabled)),
                           FPR_COST_PROBE="1",FPR_NO_LOOP_REGIONS="1",FPR_NO_CALL_REGIONS="1")
                for form in ("explicit","constructor","api"):
                    exe,(root,*_)=build("map",workload(form)+MAIN,flags)
                    selected=enabled and form!="explicit"
                    assert any(".$at.root." in w for w in root)==selected,(form,root)
                    original=next(r["cost"] for r in baseline if r["inline"]==inline and r["form"]==("explicit" if selected else form))
                    execute(exe,form,"262656\n",expected_cost=(original["alloc_requests"],original["alloc_bytes"]),
                            inline=inline,enabled=enabled)
        for enabled in (False,True):
            flags={"FPR_NO_TYPE_SPEC":str(int(not enabled))}
            exe,(root,*_)=build("control",CONTROL,flags)
            assert not any(".observe@" in w for w in root),root
            for n in ("packChecked","readChecked"):
                assert any("."+n+"@" in w for w in root)==enabled,(n,root)
            for case,(stdout,trap) in CASES.items():
                execute(exe,case,stdout,trap,[case],enabled=enabled)
            exe,(root,*_)=build("copy",REGIONAL,dict(flags,FPR_LAYOUT_CHECK="1"),hal=HAL)
            assert any(".pack@" in w for w in root)==enabled
            execute(exe,"arena","1\n",enabled=enabled)
        for name,extra in [("one",1),("two",2)]:
            (tmp/(name+".fpr")).write_text(workload("api")+f"answer n = check n + {extra}.\n")
        multi=workload("api")+'A = use "one".\nB = use "two".\nmain = print (check 3 + A.answer 3 + B.answer 3).\n'
        # Rebuild from a warm unit cache; all three callers need a home for
        # the same imported adapter and the original defining module stays public.
        for mode in ("enabled","rollback","restored"):
            exe,units=build("multi",multi,{"FPR_NO_PAIR_RETURNS":str(int(mode=="rollback")),"FPR_NO_INLINE":"1"})
            owners=[w for unit in units for w in unit if ".pack@" in w and ".$at." in w]
            assert len(set(owners))==len(owners)==(0 if mode=="rollback" else 3),(mode,owners)
            execute(exe,"three-units","39\n",mode=mode,homes=sorted(owners))
        # A same-name source edit must invalidate the representation.
        for observes in (False,True,False):
            lib.write_text(LIB.replace("value (Meters x) = x.","value v = _ = print v; case v of Meters x -> x.") if observes else LIB)
            exe,(root,*_)=build("edited",workload("api")+"main = print (check 2).\n",{})
            assert any(".pack@" in w for w in root)==(not observes),root
            execute(exe,"edited",("Meters 1\nMeters 2\n"*2 if observes else "")+"6\n",observes=observes)
        lib.write_text("Carrier.inspect : a -> Int .\n"+LIB.replace("value (Meters x) = x.","value v = Carrier.inspect v."))
        exe,(root,*_)=build("opaque",workload("api")+"main = print (check 2).\n",{},hal=ROOT/"tests/base/imported_carrier_observer.c")
        assert not any(".$at.root." in w for w in root),root
        execute(exe,"foreign","6\n")
        lib.write_text(LIB)
        owner,units=build("owner",CONTROL[:CONTROL.index("main =")],{},module=True)
        assert not any(units),units
        client=f'''unsafe base. N = use "std/native". R = use "std/reload".
Map = use "std/map".
unwrap r = case r of Ok x -> x | Err e -> error e.
main = _ = unwrap (N.attach "{owner}"); make = R.bindAt 0 "give"; add = R.bindAt 0 "addValue";
  m = keep (make 3); print (Map.fold add 0 m).
'''
        exe,_=build("client",client,{"FPR_NO_TYPE_SPEC":"1"})
        execute(exe,"dynamic-module","6\n")
        (tmp/"vault.fpr").write_text(local.LIBRARY+"guardValue v = v.\n")
        budget_src=local.CLIENT.replace("W = Type (W Int).",'M = use "carrier_meters".').replace(
            "(W x)","(M.pack x)").replace("case v of W x -> a+x","a + M.value v")
        for limit in (55,56):
            path=tmp/"budget.fpr"
            path.write_text(budget_src.replace("private x =",f"private : Int -> Int | alloc private <= {limit} .\nprivate x ="))
            for enabled in (True,False):
                q=run([ROOT/"fpr","compile","--cost","--system=posix","--target=rv64",path,tmp/"budget.s"],
                      dict(env,FPR_NO_TYPE_SPEC=str(int(not enabled))))
                assert (q.returncode==0)==(limit==56) and f"declared alloc <= {limit}   derived 56" in q.stdout+q.stderr,q.stderr
                rows.append(dict(case="public-bound",limit=limit,enabled=enabled,derived=56,exit=q.returncode))
    if record: record.write_text(json.dumps(dict(compiler_sha256=local.digest(ROOT/"fpr"),rows=rows),indent=2)+"\n")
    print(len(rows),"imported constructor, adapter, public observation, ownership and home checks passed")

if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target",choices=["macos-x86_64"])
    parser.add_argument("--record",type=Path)
    a=parser.parse_args()
    check(a.target,a.record)
