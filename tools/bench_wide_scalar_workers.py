#!/usr/bin/env python3
"""Compare wide tuple loops with explicit argument lists on the hosted runtime."""

import argparse
import hashlib
import json
import sys
import tempfile
from pathlib import Path
from bench_hosted_worker_admission import ROOT, measure, time_families

sys.path.insert(0, str(ROOT / "tests"))
from check_wide_scalar_workers import answer, call_arguments, definition, lanes


def source(width, count, aggregate):
    body = definition(width, aggregate=aggregate, increment=True)
    inputs = call_arguments(width, 1, aggregate)
    return f"unsafe base.\n{body}\nmain = print (wide{width} {count} {inputs}).\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--before", type=Path, required=True)
    ap.add_argument("--count", type=int, default=1_000_000)
    ap.add_argument("--record", type=Path, required=True)
    args = ap.parse_args()
    before = args.before.resolve()
    after = ROOT / "fpr"
    families = []
    costs = []
    for width in (9, 16, 64):
        high = source(width, args.count, True)
        explicit = source(width, args.count, False)
        expected = answer(width, args.count, 1) + args.count * sum(
            i for i in range(1, width) if i not in lanes(width)
        )
        families.append(
            (f"width{width}", high, explicit, expected, "FPR_NO_SCALAR_WORKERS")
        )
        for form, compiler, program, switches in [
            ("before", before, high, {}),
            ("after", after, high, {}),
            ("explicit", after, explicit, {}),
            ("rollback", after, high, {"FPR_NO_SCALAR_WORKERS": "1"}),
        ]:
            with tempfile.TemporaryDirectory(prefix="fpr-wide-scalar-cost-") as tmp:
                row = measure(compiler, width, Path(tmp), program, switches)
                row.pop(
                    "workers"
                )  # This metric in the recursive-group benchmark counts f0, f1, ...
                costs.append(dict(form=form, **row))
    with tempfile.TemporaryDirectory(prefix="fpr-wide-scalar-timing-") as tmp:
        timings = time_families(before, after, Path(tmp), families)
    # Retain every observation even if a shape misses its representation gate.
    args.record.write_text(
        json.dumps(
            dict(
                count=args.count,
                tool_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                harness_sha256=hashlib.sha256(
                    (ROOT / "tools/bench_hosted_worker_admission.py").read_bytes()
                ).hexdigest(),
                compile_cost=costs,
                throughput=timings,
            ),
            indent=2,
        )
        + "\n"
    )
    for row in timings:
        width = int(row["family"][5:])
        expected = (
            "$worker.scalar.wide"
            if row["form"] == "explicit"
            else "$worker.scalar.$worker.fields.wide"
        ) + str(width)
        assert (expected in row["root_workers"]) == (
            row["form"] in ("after", "explicit")
        ), row["root_workers"]


if __name__ == "__main__":
    main()
