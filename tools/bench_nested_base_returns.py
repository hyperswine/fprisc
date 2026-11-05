#!/usr/bin/env python3
"""Measure nested Base return costs against an explicit flat result and rollback."""

import argparse
import hashlib
import json
from pathlib import Path
import sys
import tempfile
from bench_hosted_worker_admission import ROOT, measure, time_families

sys.path.insert(0, str(ROOT / "tests"))
from check_product_returns import fixture as flat_fixture, expected
from check_nested_returns_rv import source as nested_fixture


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--before", type=Path, required=True)
    ap.add_argument("--count", type=int, default=5_000_000)
    ap.add_argument("--record", type=Path, required=True)
    args = ap.parse_args()
    before = args.before.resolve()
    after = ROOT / "fpr"
    if args.count <= 0:
        ap.error("count must be positive")
    families = []
    costs = []
    for width in (1, 4, 8):
        source = nested_fixture(width).replace("loop 100 0", f"loop {args.count} 0")
        flat = (
            flat_fixture(width, args.count)
            if width > 1
            else "unsafe base.\nmake n = if n < 0 then make (0 - n) else n.\nloop n acc = if n == 0 then acc else loop (n - 1) (acc + make n).\n"
            + f"main = print (loop {args.count} 0).\n"
        )
        families.append(
            (
                f"nested{width}",
                source,
                flat,
                expected(width, args.count),
                "FPR_NO_PAIR_RETURNS",
            )
        )
        for form, compiler, src, switches in [
            ("before", before, source, {}),
            ("after", after, source, {}),
            ("explicit", after, flat, {}),
            ("rollback", after, source, {"FPR_NO_PAIR_RETURNS": "1"}),
        ]:
            with tempfile.TemporaryDirectory(prefix="fpr-nested-return-cost-") as tmp:
                row = measure(compiler, width, Path(tmp), src, switches)
                row.pop("workers")
                costs.append(dict(form=form, **row))
    with tempfile.TemporaryDirectory(prefix="fpr-nested-return-timing-") as tmp:
        timings = time_families(before, after, Path(tmp), families)
    args.record.write_text(
        json.dumps(
            dict(
                count=args.count,
                tool_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                harness_sha256=hashlib.sha256(
                    (ROOT / "tools/bench_hosted_worker_admission.py").read_bytes()
                ).hexdigest(),
                costs=costs,
                throughput=timings,
            ),
            indent=2,
        )
        + "\n"
    )
    for row in timings:
        assert any(".$nested.result.make" in name for name in row["root_workers"]) == (
            row["form"] == "after"
        ), row["root_workers"]
        allocations = row["cost"]["alloc_requests"]
        if row["form"] in ("after", "explicit"):
            assert allocations == 0, (row["family"], row["form"], allocations)
        else:
            assert allocations >= args.count, (row["family"], row["form"], allocations)


if __name__ == "__main__":
    main()
