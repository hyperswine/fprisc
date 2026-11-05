#!/usr/bin/env python3
"""Check nominal sum results against tagged calls, explicit packets and module boundaries."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
from check_product_returns import ROOT, run


def workload(count, explicit=False):
    result = "(True,n) else (False,n+1)" if explicit else "LeftCell n else RightCell (n+1)"
    arms = ("(side,x) -> if side then fold (n - 1) (acc+x) else fold (n - 1) (acc - x)"
            if explicit else "LeftCell x -> fold (n - 1) (acc+x) | RightCell x -> fold (n - 1) (acc - x)")
    return ("unsafe base.\nChoice = Type (LeftCell Int | RightCell Int).\n"
            f"choose n = if n < 0 then choose (0 - n) else if n % 2 == 0 then {result}.\n"
            f"fold n acc = if n <= 0 then acc else case choose n of {arms}.\n"
            f"main = print (fold {count} 0).\n")


DECLARATIONS = """unsafe base.
Packet a = Type (Absent | Single a | Double a Bool).
mark n = _ = print n; n.
packetA n d = if n < 0 then packetB (0 - n) d else if n == 0 then Absent
  else if n == 1 then Single (mark 9) else Double (mark (10 / d)) (mark 8 == 8).
packetB n d = if n == 0 then Single (mark 7) else packetA (n - 1) d.
readPacket n d = case packetA n d of Absent -> 0 | Single x -> x + 1 | Double x flag -> if flag then x+2 else x.
readOther n d = case packetB n d of Single x -> x | Double x _ -> x | Absent -> 5.
wide n = if n < 0 then wide (0 - n) else if n == 0 then Thin 4 else Wide n (n+1) n n n n (n+2).
Width = Type (Thin Int | Wide Int Int Int Int Int Int Int).
readWide n = case wide n of Thin x -> x | Wide x y _ _ _ _ z -> x+y+z.
TooWide = Type (Short Int | Tall Int Int Int Int Int Int Int Int).
beyond n = if n < 0 then beyond (0 - n) else if n==0 then Short 1 else Tall n n n n n n n n.
readBeyond n = case beyond n of Short x -> x | Tall x _ _ _ _ _ _ y -> x+y.
Mixed = Type (Small Int | Textual String).
mixed n = if n < 0 then mixed (0 - n) else if n==0 then Small n else Textual "world".
readMixed n = case mixed n of Small x -> x | Textual s -> strlen s.
Edge = Type (Solo Int | Many Int Int Int).
edge n d = if d < 0 then edge n (0 - d) else if n == 0 then Solo n
  else Many (mark n) (mark (n+1)) (mark (10/d)).
first n d = case edge n d of Solo x -> x | Many x _ _ -> x.
child parent self = n = receive self; send parent (wide n).
"""
MAIN = """main = case Sys.args Unit of
  ["empty"] -> print (readPacket 0 1)
  | ["single"] -> print (readPacket 1 1)
  | ["double"] -> print (readPacket 2 2)
  | ["mutual"] -> print (readPacket (0 - 4) 5)
  | ["other"] -> print (readOther 0 1)
  | ["division"] -> print (readPacket 2 0)
  | ["overflow"] -> print (readPacket (0 - 4611686018427387903 - 1) 1)
  | ["unused-overflow"] -> print (first 4611686018427387903 0)
  | ["unused-division"] -> print (first 7 0)
  | ["max-success"] -> print (first 4611686018427387902 1)
  | ["min-success"] -> print (first (0 - 4611686018427387903 - 1) 2)
  | ["width"] -> print (readWide 3)
  | ["wide-fallback"] -> print (readBeyond 3)
  | ["mixed"] -> print (readMixed 1)
  | ["escape"] -> print (keep (packetA 2 2))
  | ["actor"] -> me = myself 0; a = spawn (child me); _ = send a 4;
       p = receiveFrom me a; print (keep p)
  | _ -> error "unknown case".
"""
CASES = {
    "empty": ("0\n", None), "single": ("9\n10\n", None),
    "double": ("5\n8\n7\n", None), "mutual": ("2\n8\n4\n", None),
    "other": ("7\n7\n", None), "division": ("", "division by zero"),
    "overflow": ("", "Int overflow"), "width": ("12\n", None),
    "unused-overflow": ("4611686018427387903\n","Int overflow"),
    "unused-division": ("7\n8\n","division by zero"),
    "max-success": ("4611686018427387902\n4611686018427387903\n10\n4611686018427387902\n",None),
    "min-success": ("-4611686018427387904\n-4611686018427387903\n5\n-4611686018427387904\n",None),
    "wide-fallback": ("6\n", None), "mixed": ("5\n", None),
    "escape": ("5\n8\nDouble 5 True\n", None), "actor": ("Wide 4 5 4 4 4 4 6\n", None),
}


REGION = """unsafe base.
Variant.payload : Int -> Int .
Variant.check : Int -> Int .
Carrier = Type (Plain Int | Cloaked Int).
boundary n = if n < 0 then boundary (0 - n) else if n == 0 then Plain 1 else Cloaked (Variant.payload n).
observe n = case boundary n of Plain x -> x | Cloaked x -> Variant.check x.
main = print (observe 1).
"""

def check(target, record):
    rows = []
    with tempfile.TemporaryDirectory(prefix="fpr-base-variant-") as directory:
        tmp = Path(directory)
        env = {k: v for k, v in os.environ.items() if not k.startswith("FPR_")}
        env.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=str(tmp/"cache"))
        options = ["--target="+target] if target else []

        def build(name, code, mode, module=False, hal=None):
            path = tmp/(name+".fpr")
            path.write_text(code)
            exe = tmp/(name+(".dylib" if os.uname().sysname=="Darwin" else ".so") if module else name+".exe")
            q = run([ROOT/"fpr", "build", path, "--keep", *options, "-o", exe,
                     *(["--module"] if module else ["--harts", "4"]), *(["--with", hal] if hal else [])], mode)
            assert q.returncode == 0, (q.stdout[-2000:], q.stderr[-2000:])
            asm, = (tmp/"cache/fpr/build").glob(name+"-*.s")
            workers = re.findall(r"^# fn (\$worker\.ret\d+\.\$variant\.\S+)", asm.read_text(), re.M)
            asm.unlink()
            return exe, workers

        for inline in (True, False):
            reference = {}
            for switch in ("default", "FPR_NO_TYPE_SPEC", "FPR_NO_PAIR_RETURNS", "default"):
                mode = dict(env, FPR_NO_INLINE=str(int(not inline)))
                enabled = switch=="default"
                if not enabled:
                    mode[switch] = "1"
                probe = dict(mode, FPR_COST_PROBE="1", FPR_COST_REPORT="1", FPR_NO_CALL_REGIONS="1", FPR_NO_LOOP_REGIONS="1")
                exe, workers = build("allocation", workload(1000), probe)
                assert ("$worker.ret2.$variant.choose" in workers) == enabled, workers
                for harts in ("1","4"):
                    q = run([exe], dict(probe,FPR_HARTS=harts))
                    assert q.returncode == 0 and q.stdout == "0\n", q
                    cost = json.loads(re.search(r'\[fpr cost\] (\{.*\})', q.stderr)[1])["alloc_requests"]
                    assert cost == (0 if enabled else 1000), (inline,enabled,cost,workers)
                    rows.append(dict(case="allocation",inline=inline,switch=switch,harts=harts,allocations=cost))
                exe, workers = build("cases", DECLARATIONS+MAIN, mode)
                for name in ("packetA","packetB","wide","edge"):
                    assert any(w.endswith("."+name) for w in workers)==enabled, (inline,name,workers)
                assert not any(w.endswith((".beyond",".mixed")) for w in workers), workers
                for harts in ("1","4"):
                    for case,(output,trap) in CASES.items():
                        q = run([exe,case],dict(mode,FPR_HARTS=harts))
                        assert (q.returncode!=0)==bool(trap) and q.stdout==output,(case,q)
                        assert trap in q.stderr if trap else not q.stderr,(case,q)
                        outcome = (q.returncode,q.stdout,q.stderr)
                        assert reference.setdefault((harts,case),outcome)==outcome,(case,q)
                        rows.append(dict(case=case,harts=harts,inline=inline,switch=switch,stdout=q.stdout,exit=q.returncode))
        for enabled in (False,True):
            regional = dict(env, FPR_NO_INLINE="1", FPR_NO_TYPE_SPEC=str(int(not enabled)))
            exe,workers=build("regional",REGION,regional,hal=ROOT/"tests/base/variant_region.c")
            assert bool(workers)==enabled,workers
            for harts in ("1","4"):
                q=run([exe],dict(regional,FPR_HARTS=harts))
                assert q.returncode==0 and q.stdout=="1\n",(enabled,q)
                rows.append(dict(case="active-region",enabled=enabled,harts=harts,stdout=q.stdout))
        for enabled in (False,True):
            owner,workers = build("owner",DECLARATIONS+"inspect p = case p of Thin x -> (0,x,x,x,x,x,x,x) | Wide a b c d e f g -> (1,a,b,c,d,e,f,g).\n",dict(env,FPR_NO_TYPE_SPEC=str(int(not enabled))),module=True)
            assert any(w.endswith(".wide") for w in workers)==enabled,workers
            caller = f'''unsafe base.
N = use "std/native".
R = use "std/reload".
unwrap r = case r of Ok u -> u | Err e -> error e.
main = _ = unwrap (N.attach "{owner}"); make = R.bindAt 0 "wide"; local = R.bindAt 0 "readWide";
  inspect = R.bindAt 0 "inspect"; p = keep (make 3); _ = print (inspect p); print (local 3).
'''
            exe,_=build("caller",caller,dict(env,FPR_NO_TYPE_SPEC=str(int(enabled))))
            for harts in ("1","4"):
                q=run([exe],dict(env,FPR_HARTS=harts))
                assert q.returncode==0 and q.stdout=="(1, 3, 4, 3, 3, 3, 3, 5)\n12\n",q
                rows.append(dict(case="module",enabled=enabled,harts=harts,stdout=q.stdout))
    if record:
        record.write_text(json.dumps(dict(compiler_sha256=hashlib.sha256((ROOT/"fpr").read_bytes()).hexdigest(),
                                         rows=rows),indent=2)+"\n")
    print(f"{len(rows)} variant return allocation, boundary, cache, and semantic checks passed")


if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target",choices=["macos-x86_64"])
    parser.add_argument("--record",type=Path)
    args=parser.parse_args()
    check(args.target,args.record)
