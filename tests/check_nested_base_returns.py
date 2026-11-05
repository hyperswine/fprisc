#!/usr/bin/env python3
"""Check nested Base result packets, strict fields and tagged fallbacks at runtime."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile

from check_product_returns import ROOT, run

COUNT = 1000


def fixture(count=COUNT):
    return f"""unsafe base.
Cell a = Type (Cell a).
makePair n = if n < 0 then makePair (0 - n) else ((n,n + 1),(n + 2,n + 3)).
makeCell n = if n < 0 then makeCell (0 - n) else Cell (Cell n).
consumePair n acc = if n <= 0 then acc else case makePair n of (left,right) ->
  case left of (w,x) -> case right of (y,z) -> consumePair (n - 1) (acc + w + x + y + z).
consumeCell n acc = if n <= 0 then acc else case makeCell n of Cell inner ->
  case inner of Cell x -> consumeCell (n - 1) (acc + x).
make8 n = if n < 0 then make8 (0 - n) else ((n,n + 1,n + 2,n + 3),(n + 4,n + 5,n + 6,n + 7)).
make9 n = if n < 0 then make9 (0 - n) else ((n,n + 1,n + 2),(n + 3,n + 4,n + 5),(n + 6,n + 7,n + 8)).
read8 n = case make8 n of (a,b) -> case a of (p,q,r,s) -> case b of (t,u,v,w) -> p+w.
read9 n = case make9 n of (a,b,c) -> case a of (p,q,r) -> case b of (s,t,u) -> case c of (v,w,x) -> p+t+x.
mark n = _ = print n; n.
marked n d = if n < 0 then marked (0 - n) d else ((mark 1,mark n),(mark (10 / d),mark (n + 1))).
readMarks n d = case marked n d of (a,b) -> case a of (p,q) -> case b of (r,s) -> p.
escapeInner n = case makePair n of (a,b) -> a.
outer n = makePair n.
listPayload n = if n < 0 then listPayload (0 - n) else [n,n + 1].
heapPayload n = if n < 0 then heapPayload (0 - n) else
  xs = listPayload n; ((xs,n),(xs,n + 2)).
sumTwo xs = case xs of [u,v] -> u + v | _ -> error "lost heap payload".
churn n acc = if n <= 0 then acc else case heapPayload n of (a,b) ->
  case a of (xs,p) -> case b of (ys,q) -> churn (n - 1) (acc + p + q + sumTwo xs + sumTwo ys).
hold n = case heapPayload n of (a,b) -> case a of (xs,p) -> case b of (ys,q) ->
  noise = churn 80 0; (xs,ys,p + q + noise).
adder n x = n + x.
funPacket n = if n < 0 then funPacket (0 - n) else f = adder n; ((f,n),(f,n + 2)).
funRead n = case funPacket n of (a,b) -> case a of (f,x) -> case b of (g,y) ->
  noise = churn 80 0; f x + g y + noise.
child parent self = n = receive self; send parent (hold n).
main = case Sys.args Unit of
  ["pairs"] -> print (consumePair {count} 0)
  | ["cells"] -> print (consumeCell {count} 0)
  | ["eight"] -> print (read8 9)
  | ["nine"] -> print (read9 9)
  | ["effect"] -> print (readMarks 3 2)
  | ["division"] -> print (readMarks 4611686018427387903 0)
  | ["overflow"] -> print (readMarks 4611686018427387903 1)
  | ["endpoint"] -> print (readMarks 4611686018427387902 1)
  | ["underflow"] -> print (readMarks (0 - 4611686018427387903 - 1) 1)
  | ["inner"] -> print (escapeInner 7)
  | ["outer"] -> print (outer 7)
  | ["closure"] -> print (funRead 7)
  | ["actor"] -> me = myself 0; a = spawn (child me); b = spawn (child me); _ = send a 7; _ = send b 17;
      x = receiveFrom me a; y = receiveFrom me b; _ = print (keep x); print (keep y)
  | _ -> error "unknown case".
"""


def answers():
    noise = sum(6 * n + 4 for n in range(1, 81))

    def payload(n):
        return f"([{n}, {n + 1}], [{n}, {n + 1}], {2 * n + 2 + noise})\n"

    return {
        "pairs": str(2 * COUNT * (COUNT + 1) + 6 * COUNT) + "\n",
        "cells": str(COUNT * (COUNT + 1) // 2) + "\n",
        "eight": "25\n",
        "nine": "39\n",
        "inner": "(7, 8)\n",
        "outer": "((7, 8), (9, 10))\n",
        "actor": payload(7) + payload(17),
        "closure": str(noise + 30) + "\n",
        "effect": "1\n3\n5\n4\n1\n",
        "endpoint": "1\n4611686018427387902\n10\n4611686018427387903\n1\n",
        "division": "1\n4611686018427387903\n",
        "overflow": "1\n4611686018427387903\n10\n",
        "underflow": "",
    }


def module_boundary(compiler, tmp, options, base):
    # Owner-local calls may use the flat packet, but an independently built
    # caller receives the nominal nested objects and checks their tags.
    owner = tmp / "owner.fpr"
    owner.write_text(
        "unsafe base.\nmakePair n = if n < 0 then makePair (0 - n) else ((n,n + 1),(n + 2,n + 3)).\nlocal n = case makePair n of (a,b) -> case a of (w,x) -> case b of (y,z) -> w+x+y+z.\n"
        "loopLocal n acc = if n <= 0 then acc else case makePair n of (a,b) -> case a of (w,x) -> case b of (y,z) -> loopLocal (n - 1) (acc+w+x+y+z).\n"
    )
    rows = []
    for enabled in (False, True):
        mode = dict(
            base, FPR_NO_INLINE="1", FPR_NO_PAIR_RETURNS="0" if enabled else "1"
        )
        module = tmp / (
            "owner-"
            + str(enabled)
            + (".dylib" if os.uname().sysname == "Darwin" else ".so")
        )
        result = run(
            [compiler, "build", owner, "--module", "--keep", *options, "-o", module],
            mode,
        )
        assert result.returncode == 0, result.stderr[-3000:]
        (asm,) = list((tmp / "cache/fpr/build").glob("owner-*.s"))
        private = "$nested.result.makePair" in asm.read_text()
        asm.unlink()
        caller = tmp / "caller.fpr"
        caller.write_text(
            'unsafe base.\nN = use "std/native".\nR = use "std/reload".\nok r = case r of Ok u -> u | Err why -> error why.\n'
            + f'main = _ = ok (N.attach "{module}"); make = R.bindAt 0 "makePair"; readLocal = R.bindAt 0 "local"; '
            + 'foldLocal = R.bindAt 0 "loopLocal"; p = make 7; _ = print (keep p); _ = print (readLocal 7); print (foldLocal 7 0).\n'
        )
        exe = tmp / f"caller-{enabled}"
        opposite = dict(base, FPR_NO_PAIR_RETURNS="1" if enabled else "0")
        result = run(
            [compiler, "build", caller, "--harts", "4", *options, "-o", exe], opposite
        )
        assert result.returncode == 0, result.stderr[-3000:]
        for harts in (1, 4):
            result = run([exe], dict(opposite, FPR_HARTS=str(harts)))
            assert (
                result.returncode == 0
                and result.stdout == "((7, 8), (9, 10))\n34\n154\n"
                and not result.stderr
            ), result
            rows.append(
                dict(
                    case="module",
                    enabled=enabled,
                    harts=harts,
                    private=private,
                    stdout=result.stdout,
                )
            )
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", type=Path, default=ROOT / "fpr")
    parser.add_argument("--before", action="store_true")
    parser.add_argument("--target", choices=["macos-x86_64"])
    parser.add_argument("--record", type=Path)
    args = parser.parse_args()
    compiler = args.compiler.resolve()
    rows = []
    expected = answers()
    with tempfile.TemporaryDirectory(prefix="fpr-nested-returns-") as tmp:
        tmp = Path(tmp)
        src = tmp / "nested.fpr"
        src.write_text(fixture())
        env = {k: v for k, v in os.environ.items() if not k.startswith("FPR_")}
        env.update(
            FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=str(tmp / "cache")
        )
        for inline in (False, True):
            outcomes = {}
            for isolated in (False, True):
                for enabled in (False, True):
                    mode = dict(env)
                    exe = tmp / f"nested-{inline}-{isolated}-{enabled}"
                    if not inline:
                        mode["FPR_NO_INLINE"] = "1"
                    if not enabled:
                        mode["FPR_NO_PAIR_RETURNS"] = "1"
                    if isolated:
                        mode.update(
                            FPR_NO_LOOP_REGIONS="1",
                            FPR_NO_CALL_REGIONS="1",
                            FPR_COST_PROBE="1",
                            FPR_COST_REPORT="1",
                        )
                    built = run(
                        [
                            compiler,
                            "build",
                            src,
                            "--harts",
                            "4",
                            "--keep",
                            *(["--target=" + args.target] if args.target else []),
                            "-o",
                            exe,
                        ],
                        mode,
                    )
                    assert built.returncode == 0, built.stderr[-3500:]
                    (assembly,) = list((tmp / "cache/fpr/build").glob("nested-*.s"))
                    text = assembly.read_text()
                    assembly.unlink()
                    workers = re.findall(
                        r"^# fn (\$worker\.ret[1-8]\.\$nested\.\S+) ", text, re.M
                    )
                    assert bool(workers) == (enabled and not args.before), (
                        enabled,
                        inline,
                        workers,
                    )
                    if enabled and not args.before:
                        assert any(w.endswith(".heapPayload") for w in workers), workers
                        assert any(w.endswith(".funPacket") for w in workers), workers
                    assert not any(w.endswith(".make9") for w in workers), workers
                    for harts in (1, 4):
                        for case, wanted in expected.items():
                            result = run([exe, case], dict(mode, FPR_HARTS=str(harts)))
                            assert result.stdout == wanted, (case, wanted, result)
                            diagnostics = [
                                l
                                for l in result.stderr.splitlines()
                                if not l.startswith("[fpr cost] ")
                            ]
                            fail = case in ("division", "overflow", "underflow")
                            assert (result.returncode != 0) == fail, (case, result)
                            if fail:
                                assert (
                                    "division by zero"
                                    if case == "division"
                                    else "Int overflow"
                                ) in result.stderr, (case, result)
                            else:
                                assert not diagnostics, (case, result)
                            outcome = (result.returncode, result.stdout, diagnostics)
                            key = harts, case
                            if key in outcomes:
                                assert outcome == outcomes[key], (
                                    key,
                                    outcome,
                                    outcomes[key],
                                )
                            outcomes[key] = outcome
                            row = dict(
                                inline=inline,
                                isolated=isolated,
                                enabled=enabled,
                                harts=harts,
                                case=case,
                                stdout=result.stdout,
                                exit=result.returncode,
                                diagnostics=diagnostics,
                            )
                            if isolated and not fail:
                                match = re.search(
                                    r"\[fpr cost\] (\{.*\})", result.stderr
                                )
                                row["allocations"] = json.loads(match[1])[
                                    "alloc_requests"
                                ]
                            rows.append(row)
                    print(
                        "Nested returns",
                        inline,
                        isolated,
                        enabled,
                        "1/4 workers PASS",
                        flush=True,
                    )
                if isolated:
                    for case, removed, prior in [
                        ("pairs", 3 * COUNT, COUNT),
                        ("cells", 2 * COUNT, COUNT),
                        ("eight", 3, 1),
                        ("nine", 1, 1),
                    ]:
                        for harts in (1, 4):
                            counts = [
                                r["allocations"]
                                for r in rows
                                if r["inline"] == inline
                                and r["case"] == case
                                and r["isolated"]
                                and r["harts"] == harts
                            ]
                            assert counts[0] - counts[1] == (
                                prior if args.before else removed
                            ), (case, counts)
        modules = module_boundary(
            compiler, tmp, ["--target=" + args.target] if args.target else [], env
        )
        assert all(
            row["private"] == (row["enabled"] and not args.before) for row in modules
        ), modules
        rows.extend(modules)
    if args.record:
        args.record.write_text(
            json.dumps(
                dict(
                    compiler_sha256=hashlib.sha256(compiler.read_bytes()).hexdigest(),
                    test_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                    source_sha256=hashlib.sha256(fixture().encode()).hexdigest(),
                    target=args.target or "host",
                    rows=rows,
                ),
                indent=2,
            )
            + "\n"
        )


if __name__ == "__main__":
    main()
