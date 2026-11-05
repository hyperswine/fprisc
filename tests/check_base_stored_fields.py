#!/usr/bin/env python3
"""Differential public-boundary and allocation checks for private aggregate fields."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile

from check_product_returns import ROOT, run

DECL = """unsafe base.
Value = Type (Plus Int | Minus Int).
Tree = Type (Leaf | Branch Tree Value Tree).
"""
TREE = """make d n = if d <= 0 then Leaf else
  left = make (d - 1) (n+1); right = make (d - 1) (n+2);
  v = if n % 2 == 0 then Plus n else Minus n; Branch left v right.
score t = case t of Leaf -> 0 | Branch l v r -> case v of
  Plus x -> score l + x + score r | Minus x -> score l - x + score r.
"""
FLAT = """Flat = Type (End | AddTree Flat Int Flat | SubTree Flat Int Flat).
make d n = if d <= 0 then End else left = make (d - 1) (n+1); right = make (d - 1) (n+2);
  if n % 2 == 0 then AddTree left n right else SubTree left n right.
score t = case t of End -> 0 | AddTree l v r -> score l + v + score r | SubTree l v r -> score l - v + score r.
"""
MAIN = "main = t = make 10 1; _ = print (score t); print (score t + 7).\n"

def oracle(depth, seed):
    if depth == 0:
        return 0
    return oracle(depth-1, seed+1) + (seed if seed % 2 == 0 else -seed) + oracle(depth-1, seed+2)

CASES_SOURCE = """mark x = _ = print x; x.
repeated d = if d <= 0 then Leaf else child = repeated (d - 1); Branch child (Plus d) child.
useShared d = t = repeated d; a = score t; score t + a.
marked n d = l = make (mark 0) n; v = Minus (mark (20 / d)); r = make (mark (n+1)) n; Branch l v r.
useMarked n d = t = marked n d; a = score t; score t + a.
endpoint n = t = Branch Leaf (Plus n) Leaf; score t.
escaping n = t = make 1 n; _ = print (score t); t.
captured n = t = make 1 n; fn u -> t.
sendTree parent self = send parent (escaping (receive self)).
Checked = Type (NoneHere | Both Checked Value Checked).
fallible depth n d = if depth <= 0 then NoneHere else
  left = fallible (depth - 1) n d; _ = mark 7; value = Plus (mark (20 / d));
  k = mark (n+1); right = fallible (depth - 1) k d; Both left value right.
readChecked t = case t of NoneHere -> 0 | Both l v r -> case v of
  Plus x -> readChecked l + x + readChecked r | Minus y -> readChecked l - y + readChecked r.
checkOrder n d = t = fallible 1 n d; a = readChecked t; a + readChecked t.
Payload = Type (Absent | One Int | Two Int Int).
Bundle = Type (Start | Stop | Node String Payload Bundle).
makeBundle n = if n <= 0 then Stop else if n == 1 then Start else
  Node "kept" (if n == 2 then Absent else if n == 3 then One n else Two n (n+1)) (makeBundle (n - 1)).
readBundle t = case t of Start -> 7 | Stop -> 8 | Node s val child ->
  (if s == "kept" then 0 else 999) + (case val of Absent -> 1 | One x -> x | Two x y -> x+y) + readBundle child.
bundles n = b = makeBundle n; a = readBundle b; readBundle b + a.
main = case Sys.args Unit of
  ["shared"] -> print (useShared 10) | ["empty"] -> print (useShared 0)
  | ["ok"] -> print (useMarked 3 2) | ["division"] -> print (useMarked 4611686018427387903 0)
  | ["overflow"] -> print (useMarked 4611686018427387903 1)
  | ["lower"] -> print (useMarked (0 - 4611686018427387903 - 1) 1)
  | ["max"] -> print (endpoint 4611686018427387903) | ["min"] -> print (endpoint (0 - 4611686018427387903 - 1))
  | ["closure"] -> f = captured 1; print (keep (f Unit))
  | ["escape"] -> print (keep (escaping 2))
  | ["actor"] -> me = myself 0; child = spawn (sendTree me); _ = send child 1; print (keep (receiveFrom me child))
  | ["prior"] -> print (checkOrder 4611686018427387903 0) | ["later"] -> print (checkOrder 4611686018427387903 1)
  | ["branch"] -> print (checkOrder 4 2)
  | ["bundle"] -> print (bundles 4) | ["stop"] -> print (bundles 0)
  | _ -> error "bad case".
"""
CASES = {
    "prior": ("7\n", "division by zero"), "later": ("7\n20\n", "Int overflow"),
    "branch": ("7\n10\n5\n20\n", None),
    "shared": ("4072\n", None), "empty": ("0\n", None), "ok": ("0\n10\n4\n-28\n", None),
    "division": ("0\n", "division by zero"), "overflow": ("0\n20\n", "Int overflow"),
    "lower": ("0\n20\n-4611686018427387903\n-40\n", None), "bundle": ("40\n", None),
    "stop": ("16\n", None), "escape": ("2\nBranch Leaf (Plus 2) Leaf\n", None),
    "max": ("4611686018427387903\n", None), "min": ("-4611686018427387904\n", None),
    "closure": ("Branch Leaf (Minus 1) Leaf\n", None), "actor": ("-1\nBranch Leaf (Minus 1) Leaf\n", None),
}

REGIONAL = """unsafe base.
Stored.payload : Int -> Int .
Stored.valid : Int -> Int .
Stored.opens : Unit -> Int .
Val = Type (A Int | B Int).
Tree = Type (Leaf | Branch Tree Val Tree).
make d = if d <= 0 then Leaf else l = make (d - 1); r = make (d - 1);
  Branch l (if d % 2 == 0 then A (Stored.payload d) else B (Stored.payload d)) r.
count t = case t of Leaf -> 0 | Branch l value r -> case value of
  A x -> count l + Stored.valid x + count r | B y -> count l + Stored.valid y + count r.
main = before = Stored.opens Unit; t = make 13; a = count t; b = count t;
  _ = if Stored.opens Unit > before then Unit else error "no call region opened"; print (a+b).
"""

def check(target, record):
    rows = []
    with tempfile.TemporaryDirectory(prefix="fpr-private-fields-") as directory:
        tmp = Path(directory)
        env = {k:v for k,v in os.environ.items() if not k.startswith("FPR_")}
        env.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=str(tmp/"cache"))
        answer = oracle(10, 1)
        for name, source in [("tree", DECL+TREE+MAIN), ("explicit", DECL+FLAT+MAIN),
                             ("semantics", DECL+TREE+CASES_SOURCE), ("regional", REGIONAL)]:
            src = tmp/(name+".fpr")
            src.write_text(source)
            for inline in (True, False):
                for enabled in (True, False):
                    flags = dict(env, FPR_NO_TYPE_SPEC=str(int(not enabled)), FPR_NO_INLINE=str(int(not inline)))
                    if name in ("tree","explicit"):
                        flags.update(FPR_NO_CALL_REGIONS="1", FPR_NO_LOOP_REGIONS="1", FPR_COST_PROBE="1", FPR_COST_REPORT="1")
                    exe = tmp/(name+".exe")
                    cmd = [ROOT/"fpr", "build", src, "--keep", "--harts", "4", "-o", exe]
                    if name=="regional":
                        flags.update(FPR_NO_LOOP_REGIONS="1", FPR_LAYOUT_CHECK="1")
                        cmd.extend(["--with", ROOT/"tests/base/stored_spine.c"])
                    if target:
                        cmd.append("--target="+target)
                    compiled = run(cmd, flags)
                    assert compiled.returncode==0, compiled.stderr
                    assembly, = (tmp/"cache/fpr/build").glob(name+"-*.s")
                    code = assembly.read_text()
                    assembly.unlink()
                    builder = "repeated" if name=="semantics" else "make"
                    selected = "# fn $worker.storage.aggregate."+builder+" " in code
                    assert selected==(enabled and name!="explicit"), (name, inline, enabled, builder)
                    if name=="semantics":
                        for producer in ["fallible","makeBundle"]:
                            assert ("# fn $worker.storage.aggregate."+producer+" " in code)==enabled, (name, inline, producer)
                    binary_hash = hashlib.sha256(exe.read_bytes()).hexdigest()
                    cases = CASES if name=="semantics" else {"allocation":(f"{answer}\n{answer+7}\n", None)}
                    if name=="regional":
                        cases={"active-region":("16382\n",None)}
                    for case,(stdout,trap) in cases.items():
                        for harts in (1,4):
                            q = run([exe, *([case] if name=="semantics" else [])], dict(flags, FPR_HARTS=str(harts)))
                            assert q.stdout==stdout and bool(q.returncode)==bool(trap), (name, case, inline, enabled, q)
                            if trap:
                                assert trap in q.stderr, (case, q)
                            row = dict(program=name, case=case, inline=inline, enabled=enabled, harts=harts,
                                       stdout=stdout, trap=trap, binary_sha256=binary_hash)
                            if name in ("tree","explicit"):
                                cost=json.loads(re.search(r'\[fpr cost\] (\{.*\})', q.stderr)[1])
                                actual=(cost["alloc_requests"], cost["alloc_bytes"])
                                assert actual==((1023,49104) if enabled or name=="explicit" else (2046,81840)), (row, actual)
                                row.update(allocations=actual[0], allocated_bytes=actual[1])
                            rows.append(row)
    if record:
        record.write_text(json.dumps(dict(compiler_sha256=hashlib.sha256((ROOT/"fpr").read_bytes()).hexdigest(),rows=rows),indent=2)+"\n")
    print(len(rows), "aggregate storage allocation, shared-child, public-boundary and trap checks passed")

if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=["macos-x86_64"])
    parser.add_argument("--record", type=Path)
    args=parser.parse_args()
    check(args.target, args.record)
