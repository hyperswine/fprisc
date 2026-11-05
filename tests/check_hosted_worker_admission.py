#!/usr/bin/env python3
"""Exercise large hosted return bodies and recursive scalar groups across the public ABI."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile

from check_product_returns import ROOT, run


DEPTH = 300
GROUP = 131
COUNT = 1000


def fixture():
    additions = "; ".join(
        f"v{i} = {'n' if i == 0 else 'v' + str(i - 1)} + 1" for i in range(DEPTH)
    )
    functions = "\n".join(
        f"step{i} n acc = if n <= 0 then acc else step{(i + 1) % GROUP} (n - 1) (acc + 1)."
        for i in range(GROUP)
    )
    return f"""unsafe base.
Cell = Type (Cell Int).
produce n = {additions}; Cell v{DEPTH - 1}.
observe n = case produce n of Cell x -> x.
consume n acc = if n <= 0 then acc else consume (n - 1) (acc + observe n).
{functions}
main = case Sys.args Unit of
  ["overflow"] -> _ = print 71; print (observe 4611686018427387903)
  | ["escape"] -> print (produce 7)
  | _ -> _ = print (consume {COUNT} 0); print (step0 {GROUP * 2 + 1} 9).
"""


def check(compiler, before, temp):
    source = temp / "main.fpr"
    source.write_text(fixture())
    base = {
        key: value for key, value in os.environ.items() if not key.startswith("FPR_")
    }
    base.update(
        FPR_HOME=str(ROOT),
        FPR_PATH=str(ROOT),
        XDG_CACHE_HOME=str(temp / "cache"),
        FPR_NO_INLINE="1",
        FPR_NO_LOOP_REGIONS="1",
        FPR_NO_CALL_REGIONS="1",
    )
    rows = []
    outcomes = {}
    for enabled in (False, True):
        env = dict(base)
        if not enabled:
            env.update(FPR_NO_SCALAR_WORKERS="1", FPR_NO_PAIR_RETURNS="1")
        assembly = temp / f"unit-{enabled}.s"
        result = run(
            [compiler, "compile", "--system=posix", "--target=rv64", source, assembly],
            env,
        )
        assert result.returncode == 0, result.stderr
        text = assembly.read_text()
        scalar_workers = len(
            re.findall(r"^# fn \$worker\.scalar\.step\d+\b", text, re.M)
        )
        payload_worker = (
            "# fn $worker.ret1.produce " in text
            or "# fn $worker.ret1.produce\n" in text
        )
        expected_workers = enabled and not before
        assert scalar_workers == (GROUP if expected_workers else 0), (
            enabled,
            scalar_workers,
        )
        assert payload_worker == expected_workers, (enabled, payload_worker)
        exe = temp / f"worker-{enabled}"
        cost_env = dict(env, FPR_COST_PROBE="1", FPR_COST_REPORT="1")
        result = run([compiler, "build", source, "--harts", "4", "-o", exe], cost_env)
        assert result.returncode == 0, result.stderr
        for harts in (1, 4):
            for mode in ("normal", "escape", "overflow"):
                args = [] if mode == "normal" else [mode]
                result = run([exe, *args], dict(cost_env, FPR_HARTS=str(harts)))
                traces = [
                    line
                    for line in result.stderr.splitlines()
                    if not line.startswith("[fpr cost] ")
                ]
                outcome = (result.returncode, result.stdout, traces)
                if mode == "normal":
                    assert (
                        result.returncode == 0
                        and result.stdout
                        == f"{COUNT * (COUNT + 1) // 2 + COUNT * DEPTH}\n{GROUP * 2 + 10}\n"
                    ), outcome
                elif mode == "escape":
                    assert result.returncode == 0 and result.stdout == f"Cell {7 + DEPTH}\n", (
                        outcome
                    )
                else:
                    assert (
                        result.returncode != 0
                        and result.stdout == "71\n"
                        and "overflow" in (result.stdout + result.stderr).lower()
                    ), outcome
                if enabled:
                    assert outcome == outcomes[harts, mode], (
                        outcome,
                        outcomes[harts, mode],
                    )
                else:
                    outcomes[harts, mode] = outcome
                row = dict(
                    enabled=enabled,
                    harts=harts,
                    mode=mode,
                    scalar_workers=scalar_workers,
                    payload_worker=payload_worker,
                    stdout=result.stdout,
                    exit=result.returncode,
                    diagnostic=traces,
                )
                if mode == "normal":
                    match = re.search(r"\[fpr cost\] (\{.*\})", result.stderr)
                    row["allocations"] = json.loads(match[1])["alloc_requests"]
                rows.append(row)
    for harts in (1, 4):
        off, on = [
            row["allocations"]
            for row in rows
            if row["mode"] == "normal" and row["harts"] == harts
        ]
        assert off - on == (0 if before else COUNT), (off, on)
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", type=Path, default=ROOT / "fpr")
    parser.add_argument(
        "--before",
        action="store_true",
        help="verify the saved compiler with fixed admission cutoffs",
    )
    parser.add_argument("--record", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="fpr-hosted-admission-") as tmp:
        rows = check(args.compiler.resolve(), args.before, Path(tmp))
    if args.record:
        record = dict(
            compiler_sha256=hashlib.sha256(args.compiler.read_bytes()).hexdigest(),
            before=args.before,
            fixture_sha256=hashlib.sha256(fixture().encode()).hexdigest(),
            rows=rows,
        )
        args.record.write_text(json.dumps(record, indent=2) + "\n")
    print(
        "Large return body and recursive scalar group: emission, allocations, escape and ordered overflow PASS"
    )


if __name__ == "__main__":
    main()
