#!/usr/bin/env python3
"""Check wrapper storage across separately compiled parametric libraries."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile

from check_product_returns import ROOT, run

HEADER = 'unsafe base.\nMap = use "std/map".\nMeters = Type (Meters Int).\n'
WRITER = 'fill n m = if n <= 0 then m else fill (n - 1) (Map.insert n (Meters n) m).\n'
READER = 'addValue a key value = case value of Meters x -> a + x.\n'
FOLD = 'check n = m = fill n Map.ints; a = Map.fold addValue 0 m; Map.fold addValue a m.\n'
MAIN = 'main = case Sys.args Unit of ["large"] -> print (check 512) | _ -> print (check 128).\n'

def workload(explicit=False):
    writer = WRITER.replace("(Meters n)", "n") if explicit else WRITER
    reader = 'addValue a key value = a + value.\n' if explicit else READER
    return HEADER + writer + reader + FOLD

CONTROL = HEADER+WRITER+READER+FOLD+'''observe a k value = _ = print value; a+1.
showMap n = m = fill n Map.ints; Map.fold observe 0 m.
escaped n = fill n Map.ints.
next a k v = case v of Meters x -> _ = print k; if x == 2 then a / (x - 2) else a+x.
trap n = m = fill n Map.ints; Map.fold next 0 m.
mark x = _ = print x; x.
up n d m = if n <= 0 then m else up (n - 1) d (Map.insert n (Meters (mark (d+n))) m).
edge n d = m = up n d Map.ints; Map.fold addValue 0 m.
matchOnly a k v = case v of Meters 1 -> a+1 | Meters _ -> error "no matching meter".
partial n = m = fill n Map.ints; Map.fold matchOnly 0 m.
child p self = count = receive self; send p (escaped count).
main = case Sys.args Unit of
  ["order"] -> print (showMap 3)
  | ["trap"] -> print (trap 3)
  | ["overflow"] -> print (edge 2 4611686018427387902)
  | ["max"] -> print (edge 1 4611686018427387902)
  | ["min"] -> print (edge 1 (0 - 4611686018427387903 - 1))
  | ["partial"] -> print (partial 2)
  | ["actor"] -> p = myself 0; a = spawn (child p); _ = send a 3; m = receiveFrom p a; print (Map.getOr (Meters 0) 3 m)
  | _ -> print (check 3).
'''
CASES = {"order": ("Meters 1\nMeters 2\nMeters 3\n3\n", None),
         "trap": ("1\n2\n","division by zero"), "overflow": ("","Int overflow"),
         "max": ("4611686018427387903\n4611686018427387903\n",None),
         "min": ("-4611686018427387903\n-4611686018427387903\n",None),
         "partial": ("","no matching meter"), "actor": ("Meters 3\n",None), "ordinary": ("12\n",None)}
REGIONAL = HEADER+"""Carrier.payload : Int -> Int .
Carrier.valid : Int -> Int .
Carrier.promoted : Int -> Int .
fillLive n m = if n <= 0 then m else fillLive (n - 1) (Map.insert n (Meters (Carrier.payload n)) m).
pick a k value = case value of Meters x -> if Carrier.valid x == 1 then (if k == 1 then x else a) else error "lost map value".
extract n = m = fillLive n Map.ints; Map.fold pick 0 m.
main = saved = Sys.arena (fn u -> extract 2048); print (Carrier.promoted saved).
"""
LIBRARY = """Vault a = Type (Single a).
store v = Single (guardValue v).
readValue f z (Single v) = f z v.
"""
CLIENT = """unsafe base.
V = use "vault".
W = Type (W Int).
build x = V.store (W x).
useValue a v = case v of W x -> a+x.
private x = container = build x; V.readValue useValue 1 container.
main = print (private 7).
"""

def digest(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def check(target, record):
    rows=[]
    with tempfile.TemporaryDirectory(prefix="fpr-carrier-") as directory:
        tmp=Path(directory)
        env={k:v for k,v in os.environ.items() if not k.startswith("FPR_")}
        env.update(FPR_HOME=str(ROOT), FPR_PATH=os.pathsep.join([str(tmp),str(ROOT)]), XDG_CACHE_HOME=str(tmp/"cache"))
        def build(name,source,flags,module=False,hal=None):
            src=tmp/(name+".fpr")
            src.write_text(source)
            exe=tmp/(name+(".dylib" if os.uname().sysname=="Darwin" else ".so") if module else name+".exe")
            cmd=[ROOT/"fpr","build",src,"--keep",*(["--module"] if module else ["--harts","4"]),"-o",exe]
            if hal:
                cmd.extend(["--with",hal])
            if target:
                cmd.append("--target="+target)
            q=run(cmd,dict(env,**flags))
            assert q.returncode==0,q.stderr
            asm,=(tmp/"cache/fpr/build").glob(name+"-*.s")
            workers=set(re.findall(r"^# fn (\$carrier\.\S+) ",asm.read_text(),re.M))
            asm.unlink()
            return exe,workers
        def execute(exe,flags,args,stdout,trap,**metadata):
            for harts in (1,4):
                q=run([exe,*args],dict(env,FPR_HARTS=str(harts),**flags))
                assert stdout==q.stdout and bool(trap)==bool(q.returncode),(args,q)
                if trap:
                    assert trap in q.stderr,(args,q)
                row=dict(**metadata,harts=harts,stdout=q.stdout,exit=q.returncode,binary_sha256=digest(exe))
                if flags.get("FPR_COST_REPORT")=="1":
                    m=re.search(r'\[fpr cost\] (\{.*\})',q.stderr)
                    cost=json.loads(m[1])
                    row.update(allocations=cost["alloc_requests"],allocated_bytes=cost["alloc_bytes"])
                if trap:
                    row["diagnostic"]=next(line for line in q.stderr.splitlines() if line.startswith("[ERR]"))
                rows.append(row)
        for inline in (True,False):
            for form in ("explicit","enabled","rollback","explicit-pair","pair-rollback","restored"):
                flags=dict(FPR_NO_INLINE=str(int(not inline)),FPR_NO_TYPE_SPEC=str(int(form=="rollback")),
                           FPR_NO_PAIR_RETURNS=str(int(form in ("pair-rollback","explicit-pair"))),FPR_NO_CALL_REGIONS="1",
                           FPR_NO_LOOP_REGIONS="1",FPR_COST_PROBE="1",FPR_COST_REPORT="1")
                exe,workers=build("mapvalue",workload(form.startswith("explicit"))+MAIN,flags)
                assert ("$carrier.6.Meters.fill" in workers)==(form in ("enabled","restored")),(form,workers)
                for count,argv in [(128,[]),(512,["large"])]:
                    execute(exe,flags,argv,f"{count*(count+1)}\n",None,case="allocation",count=count,form=form,inline=inline)
            for count in (128,512):
                same=[r for r in rows if r["inline"]==inline and r["count"]==count]
                for r in same:
                    baseline="explicit-pair" if r["form"] in ("explicit-pair","pair-rollback") else "explicit"
                    base=next(x for x in same if x["form"]==baseline)
                    delta=count if "rollback" in r["form"] else 0
                    assert (r["allocations"],r["allocated_bytes"])==(base["allocations"]+delta,base["allocated_bytes"]+32*delta),r
        for enabled in (True,False):
            flags=dict(FPR_NO_TYPE_SPEC=str(int(not enabled)))
            exe,workers=build("controls",CONTROL,flags)
            for name in ("fill","up","next"):
                assert ("$carrier.6.Meters."+name in workers)==enabled,(workers,name)
            assert "$carrier.6.Meters.observe" not in workers
            for case,(stdout,trap) in CASES.items():
                execute(exe,flags,[case],stdout,trap,case=case,enabled=enabled)
        assert len({r["diagnostic"] for r in rows if r["case"]=="partial"})==1
        for enabled in (True,False):
            flags=dict(FPR_NO_TYPE_SPEC=str(int(not enabled)),FPR_NO_LOOP_REGIONS="1",FPR_LAYOUT_CHECK="1")
            exe,workers=build("live",REGIONAL,flags,hal=ROOT/"tests/base/carrier_region.c")
            assert ("$carrier.6.Meters.fillLive" in workers)==enabled
            execute(exe,flags,[],"1\n",None,case="arena-copy",enabled=enabled)
        owner,workers=build("owner",CONTROL[:CONTROL.index("main =")],{},module=True)
        assert not workers,workers
        client=f'''unsafe base. N = use "std/native". R = use "std/reload".
Map = use "std/map".
unwrap r = case r of Ok x -> x | Err e -> error e.
main = _ = unwrap (N.attach "{owner}"); make = R.bindAt 0 "escaped"; output = R.bindAt 0 "addValue";
  m = keep (make 3); print (Map.fold output 0 m).
'''
        exe,_=build("client",client,{"FPR_NO_TYPE_SPEC":"1"})
        execute(exe,{},[],"6\n",None,case="module")
        # Reuse the same import spelling and build cache. A private body
        # change under a recursive dependency must invalidate admission.
        for observes in (False,True,False):
            guard="log v = _ = print v; v.\n" if observes else "log v = v.\n"
            (tmp/"vault.fpr").write_text(LIBRARY+guard+"step n v = if n <= 0 then log v else step (n - 1) v.\nguardValue v = step 2 v.\n")
            exe,workers=build("userlib",CLIENT,{})
            assert ("$carrier.1.W.build" in workers)==(not observes),(observes,workers)
            execute(exe,{},[],("W 7\n" if observes else "")+"8\n",None,case="library",observes=observes)
        (tmp/"vault.fpr").write_text(LIBRARY+"guardValue v = v.\n")
        for limit in (55,56):
            bounded=CLIENT.replace("private x =",f"private : Int -> Int | alloc private <= {limit} .\nprivate x =")
            path=tmp/"bounded.fpr"
            path.write_text(bounded)
            for enabled in (True,False):
                q=run([ROOT/"fpr","compile","--cost","--system=posix","--target=rv64",path,tmp/"bounded.s"],
                      dict(env,FPR_NO_TYPE_SPEC=str(int(not enabled))))
                assert (q.returncode==0)==(limit==56) and f"declared alloc <= {limit}   derived 56" in q.stdout+q.stderr
                rows.append(dict(case="public-bound",limit=limit,enabled=enabled,derived=56,exit=q.returncode))
    if record:
        record.write_text(json.dumps(dict(compiler_sha256=digest(ROOT/"fpr"),rows=rows),indent=2)+"\n")
    print(len(rows),"parametric carrier allocation, fallback, trap and cache checks passed")

if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target",choices=["macos-x86_64"])
    parser.add_argument("--record",type=Path)
    a=parser.parse_args()
    check(a.target,a.record)
