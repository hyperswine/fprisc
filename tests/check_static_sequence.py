#!/usr/bin/env python3
"""Execute finite multi-entry applications and check shared arena admission and refusals."""

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from unittest.mock import patch

from check_static_arena import gate, trace, refuse, ROOT

PREV = {"previous": True}
BODY = """profile builtin.
seed : Word -> Word.
seed n = n.
advance : Word -> Word -> Word.
advance state n = Word.add state n.
choose : Bool -> Word -> Word -> Word.
choose b x y = if b then x else y.
keepInt : Int -> Int.
keepInt n = n.
keepBool : Bool -> Bool.
keepBool b = b.
chooseBool : Bool -> Bool -> Bool.
chooseBool b x = if b then x else False.
keepUnit : Unit -> Unit.
keepUnit u = u.
failLater : Int -> Int.
failLater n = n + 1.
"""


def spec(*calls):
    return {
        "schema": "static-builtin-sequence-v1",
        "steps": [{"entry": name, "arguments": args} for name, args in calls],
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--require-execution", action="store_true")
    ap.add_argument("--record", type=Path)
    args = ap.parse_args()
    missing = [
        name
        for name in ("riscv64-unknown-elf-gcc", "qemu-system-riscv64")
        if not shutil.which(name)
    ]
    if missing:
        if args.require_execution:
            raise SystemExit(f"Missing {missing}")
        print("Static sequence execution skipped:", missing)
        return
    with tempfile.TemporaryDirectory(prefix="fpr-static-sequence-") as tmp:
        tmp = Path(tmp)
        source = tmp / "app.fpr"
        source.write_text(BODY)
        image = tmp / "app.elf"
        sidecar = Path(str(image) + ".admission.json")
        data = {"cases": [], "refusals": []}

        def build(schedule, heap, stack):
            return gate.build(
                source, None, [], heap, stack, image, True, sequence=schedule
            )

        word = spec(
            ("seed", [7]),
            ("advance", [PREV, 3]),
            ("advance", [PREV, 2**64 - 1]),
            ("choose", [1, PREV, 0]),
        )
        repeated = spec(("seed", [0]), *(("advance", [PREV, i]) for i in range(1, 33)))
        longer = spec(("seed", [0]), *(("advance", [PREV, i]) for i in range(1, 257)))
        for name, schedule, heap, wanted in [
            ("state", word, 624, 9),
            ("many", repeated, 624, 528),
            ("long", longer, 624, 32896),
            (
                "int",
                spec(("keepInt", [-(2**62)]), ("keepInt", [PREV])),
                0,
                2**64 - 2**62,
            ),
            ("bool", spec(("keepBool", [1]), ("keepBool", [PREV])), 0, 1),
            ("unit", spec(("keepUnit", [0]), ("keepUnit", [PREV])), 0, 0),
        ]:
            receipt = build(schedule, heap, 4096)
            peak = receipt["linked_stack"]["entries"][0]["peak_bytes"]
            receipt = build(schedule, heap, peak)
            assert receipt["image"]["image_sha256"] == gate.sha(
                image.read_bytes()
            ) and receipt == json.loads(sidecar.read_text())
            assert (
                receipt["execution"]["result_bits"] == wanted
                and receipt["heap"]["required_arena_bytes"] == heap
            )
            assert receipt["linked_stack"]["entries"][0]["peak_bytes"] == peak
            observed = trace(image, receipt) if name == "state" else None
            if name == "state":
                assert (
                    receipt["heap"]["requests"] == 11
                    and receipt["heap"]["requested_bytes"] == 264
                )
            if name == "long":
                assert (
                    receipt["heap"]["requests"] == 770
                    and len(receipt["signature"]) == 2
                )
            if name == "many":
                assert (
                    receipt["heap"]["requests"] == 98 and len(receipt["signature"]) == 2
                )
            saved = (image.read_bytes(), sidecar.read_bytes())
            refuse(lambda: build(schedule, heap, peak - 16), "needs")
            assert saved == (image.read_bytes(), sidecar.read_bytes())
            data["cases"].append(dict(name=name, receipt=receipt, trace=observed))
            print(
                name,
                len(schedule["steps"]),
                "steps, heap",
                heap,
                "stack",
                peak,
                "PASS",
                flush=True,
            )
        # Exercise bit 63 and every intervening previous-result argument in
        # the fixed dispatch table. Compute the independent heap requirement
        # first, then execute at that exact value and linked stack peak.
        parameters = [f"x{i}" for i in range(64)]
        source.write_text(
            BODY
            + "wide : "
            + " -> ".join(["Word"] * 65)
            + ".\nwide "
            + " ".join(parameters)
            + " = Word.add x0 x63.\n"
        )
        wide = spec(("seed", [7]), ("wide", [PREV] * 64))
        upper = build(wide, 16384, 8192)
        exact_heap = upper["heap"]["required_arena_bytes"]
        exact_stack = upper["linked_stack"]["entries"][0]["peak_bytes"]
        bounded = build(wide, exact_heap, exact_stack)
        assert (
            bounded["execution"]["result_bits"] == 14
            and len(bounded["signature"]["wide"]["parameters"]) == 64
        )
        data["cases"].append(
            dict(name="wide-previous-mask", receipt=bounded, trace=None)
        )
        source.write_text(BODY)
        build(word, 624, 4096)
        saved = (image.read_bytes(), sidecar.read_bytes())
        for bad, heap, why in [
            (word, 608, "needs 624"),
            (spec(("keepInt", [PREV])), 624, "first step"),
            (spec(("seed", [7]), ("keepInt", [PREV])), 624, "kind differs"),
            (spec(("keepUnit", [0]), ("keepBool", [PREV])), 624, "kind differs"),
            (spec(("seed", [7]), ("advance", [PREV])), 624, "argument count"),
            (spec(("seed", [-1])), 624, "outside KWord"),
            (spec(("keepBool", [2])), 624, "outside KBool"),
            (spec(("seed", [7]), ("failLater", [1])), 624, "UNPROVED"),
            (spec(("seed", [False])), 624, "sequence argument"),
            (spec(("seed", [{"previous": 1}])), 624, "sequence argument"),
            (spec(("x;evil", [])), 624, "invalid source entry name"),
            (spec(), 624, "at least one step"),
            ({"schema": "wrong", "steps": []}, 624, "invalid static sequence schema"),
        ]:
            data["refusals"].append(refuse(lambda: build(bad, heap, 4096), why))
            assert saved == (image.read_bytes(), sidecar.read_bytes())
        # This corruption would be hidden by the next heap initialization if
        # the hand-off failed to check complete reclamation before that reset.
        with patch.object(
            gate, "CHECKPOINT", "(void)fpr_alloc(16);\n" + gate.CHECKPOINT
        ):
            data["refusals"].append(
                refuse(lambda: build(word, 624, 4096), "STATIC_ARENA_FAIL")
            )
        assert saved == (image.read_bytes(), sidecar.read_bytes())
        # Measure from ABI entry to the captured return address on an
        # uninstrumented CPU trace. Both arms and repeated calls count.
        schedule=spec(("keepBool",[1]),("chooseBool",[PREV,1]),("chooseBool",[0,1]),("keepBool",[PREV]))
        def bounded(limit):
            return gate.build(source,None,[],0,1024,image,True,sequence=schedule,callback_instructions=limit)
        first=bounded(10000)
        total=first["callback_work"]["required"]
        exact=bounded(total)
        observed=trace(image,exact)["callback_trace"]
        names=[s["entry"] for s in schedule["steps"]]
        assert [s["entry"] for s in observed]==names
        assert total==sum(exact["callback_work"]["per_entry"][n] for n in names)
        assert all(0<s["instructions"]<=exact["callback_work"]["per_entry"][s["entry"]] for s in observed)
        assert any(s["instructions"]==exact["callback_work"]["per_entry"][s["entry"]] for s in observed)
        saved=(image.read_bytes(),sidecar.read_bytes())
        short=refuse(lambda:bounded(total-1),"instructions, limit")
        assert saved==(image.read_bytes(),sidecar.read_bytes())
        heap_store=refuse(lambda:gate.build(source,None,[],624,4096,image,False,sequence=word,callback_instructions=100000),"outside proved frame")
        assert saved==(image.read_bytes(),sidecar.read_bytes())
        data["callback_work"]=dict(receipt=exact,trace=observed,short_refusal=short,heap_store_refusal=heap_store)
        print("Linked callback instructions:",total,"across",len(names),"calls; traced",observed,flush=True)
        cfg = tmp / "sequence.json"
        cfg.write_text(json.dumps(word))
        cmd = [
            sys.executable,
            str(ROOT / "tools/build_static_arena.py"),
            str(source),
            "--sequence",
            str(cfg),
            "--heap-bytes",
            "624",
            "--stack-bytes",
            "4096",
            "--image",
            str(image),
            "--execute",
        ]
        p = subprocess.run(cmd, capture_output=True, text=True)
        assert p.returncode == 0, p.stderr
        assert json.loads(sidecar.read_text())["execution"]["result_bits"] == 9
        p = subprocess.run(cmd + ["--arguments", "[]"], capture_output=True, text=True)
        assert p.returncode != 0 and "belongs to a single entry" in p.stderr, p
        cfg.write_text(json.dumps(schedule))
        scalar_cmd=[*cmd,"--callback-instructions",str(total)]
        scalar_cmd[scalar_cmd.index("--heap-bytes")+1]="0"
        p=subprocess.run(scalar_cmd,capture_output=True,text=True)
        assert p.returncode==0 and json.loads(sidecar.read_text())["callback_work"]["required"]==total,p.stderr
        saved=(image.read_bytes(),sidecar.read_bytes())
        p=subprocess.run([*scalar_cmd[:-1],str(total-1)],capture_output=True,text=True)
        assert p.returncode!=0 and "instructions, limit" in p.stderr
        assert saved==(image.read_bytes(),sidecar.read_bytes())
        print(
            "Typed scalar handoffs, short arenas, late unproved entry, pre-reset leak and publication preservation PASS"
        )
        if args.record:
            args.record.write_text(json.dumps(data, indent=2) + "\n")


if __name__ == "__main__":
    main()
