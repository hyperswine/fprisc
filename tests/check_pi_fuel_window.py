#!/usr/bin/env python3
"""Compare linked entry-to-handoff bounds against single-stepping an isolated Pi child."""

import argparse
import hashlib
import io
import json
from pathlib import Path
import shlex
import subprocess
import sys
import tarfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from check_aarch64_fuel import Image, admit


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def qualify(executable, entry, tracer, host, directory, kind):
    directory.mkdir(parents=True, exist_ok=False)
    image = Image(executable.read_bytes())
    grow = image.symbol("fpr_stack_grow")
    exhaust = image.symbol("fpr_fuel_exhausted")
    root = image.symbol(entry)
    # Read the deployed runtime's fuelQuantum result (a tagged Int), rather
    # than treating a policy constant from this checkout as image evidence.
    quantum_pc = image.symbol("g_fuel_quantum")
    mov = image.word(quantum_pc)
    assert mov & 0xFFE0001F == 0x52800000 and image.word(quantum_pc + 4) == 0xD65F03C0
    tagged = (mov >> 5) & 65535
    assert tagged & 1 and tagged > 7
    quantum = tagged >> 1
    limit = 32768
    examples = {0: 1, 2: 3} if kind == "add" else {}
    plans = {
        n: admit(image, entry, n, limit, arguments=examples) for n in (1, 2, 3, quantum)
    }
    room = plans[3]["stack_window_bytes"]
    assert room >= 16 and room % 16 == 0
    other = image.symbol("fpr_prim_fn__x2b") if kind == "add" else 0
    record = dict(
        image_sha256=image.digest,
        entry=entry,
        fixture=kind,
        tracer_sha256=digest(tracer),
        trace_source_sha256=digest(ROOT / "tests/base/pi_fuel_trace.c"),
        quantum=quantum,
        quantum_accessor=[quantum_pc, mov, image.word(quantum_pc + 4)],
        analyzer_sha256=digest(ROOT / "tools/check_aarch64_fuel.py"),
        plans=plans,
        rows=[],
    )
    ssh = [
        "ssh",
        "-T",
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        "ConnectTimeout=6",
        "root@" + host,
    ]

    def remote(cmd, **kwargs):
        return subprocess.run(
            ssh + [cmd], check=True, timeout=60, capture_output=True, **kwargs
        ).stdout

    desktop = "set -e; cat /var/run/qosp/state; p=$(cat /var/run/qosp/ready); sha256sum /usr/bin/qosp /proc/$p/exe"
    record["device"] = remote("cat /proc/device-tree/model; uname -a").decode().strip()
    record["desktop_before"] = remote(desktop).decode()
    work = "/tmp/fpr-fuel-window-" + str(time.time_ns())
    record.update(host=host, remote_dir=work)

    def save(name):
        (directory / name).write_text(json.dumps(record, indent=2) + "\n")

    save("progress.json")
    payload = io.BytesIO()
    with tarfile.open(fileobj=payload, mode="w") as t:
        for path, name in [(executable, "app"), (tracer, "trace")]:
            t.add(path, arcname=name)
    prefix = "cd " + shlex.quote(work) + " && "
    remote(
        "mkdir -m 700 " + shlex.quote(work) + " && " + prefix + "tar xf -",
        input=payload.getvalue(),
    )
    hashes = remote(prefix + "sha256sum app trace").decode().splitlines()
    assert hashes[0].split()[0] == image.digest and hashes[1].split()[0] == digest(
        tracer
    )
    if kind != "loop":
        record["ordinary_stdout"] = remote(prefix + "FPR_HARTS=1 ./app").decode()
        assert record["ordinary_stdout"] == "262656\n"
    args_mode = "add" if kind == "add" else "ordinary"
    cases = [("live", "live", args_mode)]
    cases.extend(
        (plans[f]["stack_window_bytes"], f, args_mode) for f in (1, 2, 3, quantum)
    )
    cases.extend(
        [(room - 1, 3, args_mode), (plans[1]["stack_window_bytes"] - 16, 1, args_mode)]
    )
    if kind == "add":
        cases.append((room, quantum, "overflow"))
    for window, budget, mode in cases:
        extend = kind == "loop" and (window, budget) == ("live", "live")
        switch = image.symbol("fpr_ctx_switch") if extend else 0
        queue = image.symbol("backlog_add") if extend else 0
        args = [
            "./trace",
            "./app",
            hex(root),
            hex(grow),
            hex(exhaust),
            str(window),
            str(budget),
            mode,
            hex(other),
            hex(switch),
            hex(queue),
        ]
        result = json.loads(remote(prefix + shlex.join(args)))
        if extend:
            assert (
                result["observed_scheduler_instructions"] > 0
                and result["queue_entries"] == 1
            ), result
        result.update(window_case=window, fuel_case=budget, argument_mode=mode)
        record["rows"].append(result)
        save("progress.json")
        raw = {i: result["x" + str(i)] for i in (0, 2)} if kind == "add" else {}
        try:
            proof = admit(
                image,
                entry,
                result["incoming_fuel"],
                limit,
                room=result["window_bytes"],
                writable=result["live_window_bytes"],
                arguments=raw,
            )
        except ValueError as e:
            if mode == "overflow":
                assert (
                    "unproved call" in str(e)
                    and "fpr_prim_fn__x2b" in str(e)
                    and result["outcome"] == "other_runtime"
                )
            else:
                assert (
                    "stack-window low bound" in str(e)
                    and result["outcome"] == "grow_runtime"
                )
                assert result["ticks"] == (
                    1 if kind == "add" and window == room - 1 else 0
                )
            result["refusal"] = str(e)
            continue
        assert mode != "overflow" and set(proof["outcomes"]) == {result["outcome"]}, (
            result
        )
        bound = proof["outcomes"][result["outcome"]]
        assert (result["instructions"], result["stack_bytes"], result["ticks"]) == (
            bound["max_instructions"],
            bound["writable_stack_bytes"],
            bound["max_ticks"],
        ), result
    record["desktop_after"] = remote(desktop).decode()
    assert record["desktop_after"] == record["desktop_before"]
    record["status"] = "PASS"
    save("complete.json")
    print(
        "Pi single-step qualification passed", len(record["rows"]), "stack/fuel cases"
    )


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    for opt in ("image", "tracer", "output"):
        ap.add_argument("--" + opt, required=True, type=Path)
    ap.add_argument("--entry", required=True)
    ap.add_argument("--kind", choices=["pack", "add", "loop"], required=True)
    ap.add_argument("--host", required=True)
    a = ap.parse_args()
    qualify(a.image, a.entry, a.tracer, a.host, a.output, a.kind)
