#!/usr/bin/env python3
"""Check type-directed Base transport, strict argument order and the tagged ABI."""
import argparse
import json
import os
from pathlib import Path
import re
import tempfile

from check_product_returns import ROOT, run

HEADER = """unsafe base.
Cell a = Type (Cell a).
walk n x = if n <= 0 then x else walk (n - 1) x.
"""
FOLDS = """
foldCell n a = if n <= 0 then a else case walk 3 (Cell n) of Cell x -> foldCell (n - 1) (a + x).
foldPair n a = if n <= 0 then a else case walk 3 (n,n + 1) of (x,y) -> foldPair (n - 1) (a + x + y).
"""
CONTROL = """
mark n = _ = print n; n.
check n = _ = print n; n <= 0.
through count payload last = if check count then payload else through (count - 1) payload last.
read d = case through (mark 2) (mark 11,mark (10 / d)) (mark (4611686018427387903 + d)) of
  (x,_) -> x.
readSafe v = case through (mark 2) (mark 11,mark v) (mark 22) of (x,_) -> x.
observe p n = _ = print p; n <= 0.
watch n p = if observe p n then p else watch (n - 1) p.
foreignRead n = case watch 1 (n,n + 1) of (x,y) -> x + y.
pick n x y = if n <= 0 then y else if n == 1 then x else pick (n - 1) x y.
swapped n = case pick 2 (n,1) (n,2) of (x,y) -> x+y.
heap n = if n <= 0 then [] else n :: heap (n - 1).
carry n = case walk 81 (heap n, heap (n+1)) of (xs,ys) ->
  extra = heap (n+2); (xs,ys,extra).
child parent self = n = receive self; send parent (carry n).
main = case Sys.args Unit of
  ["ok"] -> print (readSafe 7)
  | ["division"] -> print (read 0)
  | ["overflow"] -> print (read 1)
  | ["observe"] -> print (foreignRead 4)
  | ["other"] -> print (swapped 9)
  | ["actor"] -> me = myself 0; a = spawn (child me); _ = send a 2; print (keep (receiveFrom me a))
  | _ -> error "unknown".
"""
CASES = {
    "ok": ("2\n11\n7\n22\n2\n1\n0\n11\n", None),
    "division": ("2\n11\n", "division"),
    "overflow": ("2\n11\n10\n", "overflow"),
    "observe": ("(4, 5)\n(4, 5)\n9\n", None),
    "other": ("10\n", None),
    "actor": ("([2, 1], [3, 2, 1], [4, 3, 2, 1])\n", None),
}


def check(target):
    with tempfile.TemporaryDirectory(prefix="fpr-transport-") as directory:
        tmp = Path(directory)
        env = {k: v for k, v in os.environ.items() if not k.startswith("FPR_")}
        env.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=str(tmp / "cache"))
        options = ["--target=" + target] if target else []

        def build(name, source, mode, module=False):
            path = tmp / (name + ".fpr")
            path.write_text(source)
            suffix = ".dylib" if os.uname().sysname == "Darwin" else ".so"
            output = tmp / (name + (suffix if module else ".exe"))
            command = [ROOT / "fpr", "build", path, "--keep", *options, "-o", output]
            built = run(command + (["--module"] if module else ["--harts", "4"]), mode)
            assert built.returncode == 0, built.stderr[-2500:]
            assembly, = (tmp / "cache/fpr/build").glob(name + "-*.s")
            names = set(re.findall(r"^# fn (\S+)", assembly.read_text(), re.M))
            assembly.unlink()
            return output, names

        # Reuse the cache across default / rollback / default builds.
        for inline in (True, False):
            for enabled in (True, False, True):
                mode = dict(env, FPR_NO_TYPE_SPEC=str(int(not enabled)), FPR_NO_INLINE=str(int(not inline)))
                counted = dict(mode, FPR_NO_LOOP_REGIONS="1", FPR_NO_CALL_REGIONS="1",
                               FPR_COST_PROBE="1", FPR_COST_REPORT="1")
                exe, names = build("allocation", HEADER + FOLDS +
                    "main = print (foldCell 1000 0 + foldPair 1000 0 + walk 3 11).\n", counted)
                instances = [n for n in names if n.startswith("walk$typespec$type$")]
                assert len(instances) == int(enabled), names
                assert "walk" in names
                for harts in ("1", "4"):
                    q = run([exe], dict(counted, FPR_HARTS=harts))
                    assert q.returncode == 0 and q.stdout == "1502511\n", q
                    cost = json.loads(re.search(r'\[fpr cost\] (\{.*\})', q.stderr)[1])
                    assert cost["alloc_requests"] == (0 if enabled else 2000), cost
                exe, names = build("control", HEADER + CONTROL, mode)
                assert any(n.startswith("through$typespec$") for n in names) == enabled, names
                assert not any(n.startswith(("watch$typespec$", "pick$typespec$")) for n in names)
                for harts in ("1", "4"):
                    for case, (output, failure) in CASES.items():
                        q = run([exe, case], dict(mode, FPR_HARTS=harts))
                        assert q.stdout == output, (case, q)
                        if failure:
                            assert q.returncode and failure in q.stderr.lower(), (case, q)
                        else:
                            assert q.returncode == 0, (case, q)

        # Remarks explain the selected clone and the two different generic
        # helpers. Diagnostics must survive a warm cache and preserve code.
        src = tmp / "control.fpr"
        asm = tmp / "remarks.s"
        args = [ROOT / "fpr", "compile", "--system=posix", src, asm]
        assert run(args, env).returncode == 0
        plain = asm.read_bytes()
        remarks = run([*args, "--remarks=json"], env)
        assert remarks.returncode == 0, remarks.stderr
        assert run([*args, "--remarks=json"], env).stderr == remarks.stderr
        assert asm.read_bytes() == plain
        records = [json.loads(line) for line in remarks.stderr.splitlines() if line.startswith("{")]
        decisions = [r for r in records if r.get("kind") == "type-spec"]
        assert any(r["owner"] == "through" and r["outcome"] == "applied" for r in decisions), decisions
        for owner in ("foreignRead", "swapped"):
            assert any(r["owner"] == owner and r["outcome"] == "declined" for r in decisions), decisions

        for enabled in (False, True):
            mode = dict(env, FPR_NO_INLINE="1", FPR_NO_TYPE_SPEC=str(int(not enabled)))
            module, names = build("owner", HEADER + FOLDS, mode, module=True)
            assert "walk" in names
            assert any(n.startswith("walk$typespec$") for n in names) == enabled
            caller = f'''unsafe base.
N = use "std/native".
R = use "std/reload".
ok r = case r of Ok u -> u | Err why -> error why.
main = _ = ok (N.attach "{module}"); f = R.bindAt 0 "walk"; g = R.bindAt 0 "foldCell";
  p = f 3 (11,12); _ = print (keep p); print (g 10 0).
'''
            opposite = dict(env, FPR_NO_TYPE_SPEC=str(int(enabled)))
            exe, _ = build("caller", caller, opposite)
            for harts in ("1", "4"):
                q = run([exe], dict(opposite, FPR_HARTS=harts))
                assert q.returncode == 0 and q.stdout == "(11, 12)\n55\n", q
    print("Base forwarding passed allocation, evaluation order, heap payload, fallback, warm cache and module checks")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=["macos-x86_64"])
    check(parser.parse_args().target)
