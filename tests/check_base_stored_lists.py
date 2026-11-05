#!/usr/bin/env python3
"""Check persistent scalar list layouts, their tagged fallbacks and runtime walkers."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile

from check_product_returns import ROOT, run

BASELINE = ROOT / "bench/2026-11-05-base-persistent-storage-before.json"
SYSTEM = ROOT / "tests/base/stored_spine.c"
SOURCE = """unsafe base.
Step = Type (NothingHere | Add Int | Move Int Int Bool).
mark n = _ = print n; n.
buildSteps n d = if n <= 0 then [] else
  (if n == 1 then NothingHere else if n == 2 then Add (mark 3) else Move (mark n) (mark (10/d)) True) :: buildSteps (n - 1) d.
totalSteps xs acc = case xs of [] -> acc | h :: rest -> case h of NothingHere -> totalSteps rest (acc+1)
  | Add x -> totalSteps rest (acc+x) | Move x y b -> totalSteps rest (if b then acc+x+y else acc).
shared n d = xs = buildSteps n d; a = totalSteps xs 1; totalSteps xs a.
escape n = xs = buildSteps n 2; _ = print (totalSteps xs 0); xs.
closure n = xs = buildSteps n 2; fn x -> if x then xs else [].
Edge = Type (LeftEdge Int | RightEdge Int).
extreme n d = if n <= 0 then [] else RightEdge (mark (d+1)) :: extreme (n - 1) d.
sumEdge xs acc = case xs of [] -> acc | h :: tail -> case h of LeftEdge x -> sumEdge tail (acc - x) | RightEdge x -> sumEdge tail (acc+x).
edge d = xs = extreme 1 d; sumEdge xs 0.
Wide = Type (Short Int | Long Int Int Int Int Int Int Int).
wide n = if n <= 0 then [] else (if n == 1 then Short n else Long n n n n n n (n+1)) :: wide (n - 1).
readWide xs acc = case xs of [] -> acc | h :: rest -> case h of Short x -> readWide rest (acc+x) | Long a _ _ _ _ _ z -> readWide rest (acc+a+z).
sharedWide n = xs = wide n; a = readWide xs 0; readWide xs a.
Eight = Type (Eight Int Int Int Int Int Int Int Int).
eight n = if n <= 0 then [] else Eight n (n+1) n n n n n (n+2) :: eight (n - 1).
sum8 xs acc = case xs of [] -> acc | h :: rest -> case h of Eight a b _ _ _ _ _ z -> sum8 rest (acc+a+b+z).
full n = xs = eight n; a = sum8 xs 0; sum8 xs a.
Over = Type (Little Int | Large Int Int Int Int Int Int Int Int).
over n = if n <= 0 then [] else Large n n n n n n n n :: over (n - 1).
sumOver xs acc = case xs of [] -> acc | h :: rest -> case h of Little x -> sumOver rest (acc+x) | Large x _ _ _ _ _ _ y -> sumOver rest (acc+x+y).
outOfRange n = xs = over n; sumOver xs 0.
Heap = Type (Number Int | Message String).
heap n = if n <= 0 then [] else Number n :: heap (n - 1).
readHeap xs acc = case xs of [] -> acc | h :: rest -> case h of Number x -> readHeap rest (acc+x) | Message s -> readHeap rest (acc+strlen s).
boxed n = xs = heap n; readHeap xs 0.
child parent self = n = receive self; send parent (escape n).
"""
MAIN = """main = case Sys.args Unit of
  ["shared"] -> print (shared 3 2) | ["empty"] -> print (shared 0 0)
  | ["division"] -> print (shared 3 0)
  | ["overflow"] -> print (edge 4611686018427387903)
  | ["min"] -> print (edge (0 - 4611686018427387903 - 1))
  | ["max"] -> print (edge 4611686018427387902)
  | ["escape"] -> print (keep (escape 3))
  | ["closure"] -> f = closure 3; print (keep (f True))
  | ["actor"] -> me = myself 0; a = spawn (child me); _ = send a 3; print (keep (receiveFrom me a))
  | ["eight"] -> print (full 3) | ["over"] -> print (outOfRange 3)
  | ["wide"] -> print (sharedWide 4)
  | ["heap"] -> print (boxed 3)
  | _ -> error "case".
"""
CASES = {"shared":("3\n5\n3\n25\n",None),"empty":("1\n",None),"division":("3\n","division by zero"),
         "overflow":("","Int overflow"),"min":("-4611686018427387903\n-4611686018427387903\n",None),
         "max":("4611686018427387903\n4611686018427387903\n",None),
         "escape":("3\n5\n3\n12\n[Move 3 5 True, Add 3, NothingHere]\n",None),
         "closure":("3\n5\n3\n[Move 3 5 True, Add 3, NothingHere]\n",None),
         "actor":("3\n5\n3\n12\n[Move 3 5 True, Add 3, NothingHere]\n",None),
         "wide":("44\n",None),"eight":("54\n",None),"over":("12\n",None),"heap":("6\n",None)}
REGIONAL = """unsafe base.
Stored.payload : Int -> Int .
Stored.valid : Int -> Int .
Stored.opens : Unit -> Int .
T = Type (A Int | B Int).
make n = if n <= 0 then [] else (if n % 2 == 0 then A (Stored.payload n) else B (Stored.payload n)) :: make (n - 1).
count xs a = case xs of [] -> a | h :: tail -> case h of A x -> count tail (a+Stored.valid x) | B y -> count tail (a+Stored.valid y).
main = before = Stored.opens Unit; xs = make 6000; a = count xs 0; b = count xs a;
  _ = if Stored.opens Unit > before then Unit else error "no call region opened"; print b.
"""
WALKERS = """unsafe base.
Stored.make : Int -> Int -> a .
Stored.verify : a -> Int -> Int -> Int .
child parent self = (v,n,w) = receive self; copied = keep v;
  _ = if Stored.verify copied n w == 1 then Unit else error "lost payload on receive";
  send parent copied.
check n w = me = myself 0; a = spawn (child me); v = Sys.arena (fn u -> Stored.make n w);
  _ = send a (v,n,w); c = receiveFrom me a; Stored.verify c n w.
main = case Sys.args Unit of ["deep"] -> print (check 16000 1)
  | _ -> print (check 4500 1 + check 4500 2 + check 4500 7 + check 4500 8).
"""


def forms():
    return {r["form"]:r["source"] for r in json.loads(BASELINE.read_text())["rows"]}


def check(target, record):
    rows = []
    with tempfile.TemporaryDirectory(prefix="fpr-stored-list-") as directory:
        tmp=Path(directory)
        base={k:v for k,v in os.environ.items() if not k.startswith("FPR_")}
        base.update(FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),XDG_CACHE_HOME=str(tmp/"cache"))
        targets=["--target="+target] if target else []
        linked = {}
        def build(name,code,options,hal=None,module=False):
            path=tmp/(name+".fpr")
            path.write_text(code)
            exe=tmp/(name+(".dylib" if os.uname().sysname=="Darwin" else ".so") if module else name+".exe")
            q=run([ROOT/"fpr","build",path,"--keep",*targets,"-o",exe,
                   *(["--module"] if module else ["--harts","4"]),*(["--with",hal] if hal else [])],options)
            assert q.returncode==0,(q.stderr[-2200:],q.stdout[-1000:])
            assembly,=(tmp/"cache/fpr/build").glob(name+"-*.s")
            workers=re.findall(r"^# fn (\$worker\.storage\.[^ ]+)",assembly.read_text(),re.M)
            assembly.unlink()
            linked[exe] = hashlib.sha256(exe.read_bytes()).hexdigest()
            return exe,workers

        def execute(exe,mode,case,output,trap=None,allocations=None):
            for harts in ("1","4"):
                q=run([exe,*([case] if case else [])],dict(mode,FPR_HARTS=harts))
                assert (q.returncode!=0)==bool(trap) and q.stdout==output,(case,harts,q)
                if trap: assert trap in q.stderr,(case,q)
                row=dict(source=exe.name,binary_sha256=linked[exe],case=case,harts=harts,stdout=q.stdout,exit=q.returncode,
                         switches={k:v for k,v in mode.items() if k.startswith("FPR_") and k not in ("FPR_PATH","FPR_HOME")})
                if allocations is not None:
                    cost=json.loads(re.search(r'\[fpr cost\] (\{.*\})',q.stderr)[1])
                    assert cost["alloc_requests"]==allocations and cost["alloc_bytes"]==32*allocations,cost
                    row.update(allocations=allocations,alloc_bytes=cost["alloc_bytes"])
                rows.append(row)

        for inline in (True,False):
            for enabled in (True,False):
                mode=dict(base,FPR_NO_INLINE=str(int(not inline)),FPR_NO_TYPE_SPEC=str(int(not enabled)))
                probe=dict(mode,FPR_COST_PROBE="1",FPR_COST_REPORT="1",FPR_NO_CALL_REGIONS="1",FPR_NO_LOOP_REGIONS="1")
                for name,src in forms().items():
                    explicit=name.endswith("explicit")
                    exe,workers=build("alloc-"+name,src,probe)
                    assert ("$worker.storage.list.build" in workers)==(enabled and not explicit),(name,workers)
                    execute(exe,probe,"","500511\n500517\n" if name.startswith("scalar") else "511\n517\n",
                            allocations=1000 if enabled or explicit else 2000)
                exe,workers=build("cases",SOURCE+MAIN,mode)
                for n in ("buildSteps","wide","extreme","eight"):
                    assert ("$worker.storage.list."+n in workers)==enabled,(inline,enabled,n,workers)
                assert not any(w in workers for w in ("$worker.storage.list.heap","$worker.storage.list.over"))
                for case,(out,trap) in CASES.items(): execute(exe,mode,case,out,trap)
        for switch in (None, "FPR_NO_TYPE_SPEC", "FPR_NO_PAIR_RETURNS", None):
            mode=dict(base,FPR_COST_PROBE="1",FPR_COST_REPORT="1",FPR_NO_LOOP_REGIONS="1",FPR_NO_CALL_REGIONS="1")
            if switch: mode[switch]="1"
            exe,workers=build("warm",forms()["variant-list"],mode)
            assert bool(workers)==(switch is None),workers
            execute(exe,mode,"","511\n517\n",allocations=2000 if switch else 1000)
        # Exercise the non-bump native allocator with live discriminants and
        # all payload slots. Reuse the cache on a rollback/default transition.
        for disabled in (True,False):
            mode=dict(base,FPR_NO_BUMP_ALLOC="1",FPR_NO_INLINE="1",FPR_NO_TYPE_SPEC=str(int(disabled)))
            exe,workers=build("cases",SOURCE+MAIN,mode)
            assert ("$worker.storage.list.wide" in workers)==(not disabled)
            for case in ("shared","wide","eight","over","max"):
                execute(exe,mode,case,*CASES[case])
        for legacy in (False,True):
            # Exercise the debug extent oracle and the legacy preheader.
            mode=dict(base,FPR_COMPACT_CELLS=str(int(not legacy)),FPR_LAYOUT_CHECK="1")
            exe,_=build("walkers",WALKERS,mode,SYSTEM)
            execute(exe,mode,"deep","1\n")
            execute(exe,mode,"widths","4\n")
        for enabled in (True,False):
            mode=dict(base,FPR_NO_TYPE_SPEC=str(int(not enabled)),FPR_NO_INLINE="1",FPR_NO_LOOP_REGIONS="1")
            exe,workers=build("region",REGIONAL,mode,SYSTEM)
            assert ("$worker.storage.list.make" in workers)==enabled, workers
            execute(exe,mode,"","12000\n")
        owner,workers=build("owner",SOURCE,base,module=True)
        assert "$worker.storage.list.buildSteps" in workers
        client=f'''unsafe base. N = use "std/native". R = use "std/reload".
unwrap r = case r of Ok x -> x | Err e -> error e.
main = _ = unwrap (N.attach "{owner}"); make = R.bindAt 0 "buildSteps"; read = R.bindAt 0 "totalSteps";
  xs = keep (make 3 2); _ = print (read xs 0); print (read xs 17).
'''
        exe,_=build("client",client,dict(base,FPR_NO_TYPE_SPEC="1"))
        execute(exe,base,"","3\n5\n3\n12\n29\n")
    if record: record.write_text(json.dumps(dict(compiler_sha256=hashlib.sha256((ROOT/"fpr").read_bytes()).hexdigest(),
                                                rows=rows),indent=2)+"\n")
    print(len(rows),"persistent storage allocation, effects, trap, escape, module and walker cases passed")


if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target",choices=["macos-x86_64"])
    parser.add_argument("--record",type=Path)
    args=parser.parse_args()
    check(args.target,args.record)
