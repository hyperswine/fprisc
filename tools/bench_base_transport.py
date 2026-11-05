#!/usr/bin/env python3
"""Compare checked Base transport with the tagged helper and explicit loops."""
import argparse
import hashlib
import json
import sys
import tempfile
from pathlib import Path
from bench_hosted_worker_admission import ROOT, measure, time_families

sys.path.insert(0, str(ROOT / "tests"))
from check_base_transport import HEADER, FOLDS
from check_base_variant_returns import workload as variant_workload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--count", type=int, default=1_000_000)
    parser.add_argument("--family", choices=["transport", "variant"], default="transport")
    parser.add_argument("--record", type=Path, required=True)
    args = parser.parse_args()
    count = args.count
    if count <= 0:
        parser.error("count must be positive")
    entry = f"main = print (foldCell {count} 0 + foldPair {count} 0 + walk 3 11).\n"
    high = HEADER + FOLDS + entry
    flat = HEADER + """
flatWalk n x y = if n <= 0 then (x,y) else flatWalk (n - 1) x y.
foldCell n a = if n <= 0 then a else foldCell (n - 1) (a + walk 3 n).
foldPair n a = if n <= 0 then a else case flatWalk 3 n (n + 1) of (x,y) -> foldPair (n - 1) (a + x + y).
""" + entry
    if args.family == "variant":
        high = variant_workload(count)
        flat = variant_workload(count, explicit=True)
        expected = -(count+1) if count % 2 else 0
        family = "scalar-variant"
        minimum_boxed = count
    else:
        expected = 3 * count * (count + 1) // 2 + count + 11
        family = "wrapper-and-pair"
        minimum_boxed = 2 * count
    before = args.before.resolve()
    after = ROOT / "fpr"
    costs = []
    for form, compiler, source, flags in [
            ("before", before, high, {}), ("after", after, high, {}),
            ("explicit", after, flat, {}), ("rollback", after, high, {"FPR_NO_TYPE_SPEC": "1"})]:
        with tempfile.TemporaryDirectory(prefix="fpr-transport-cost-") as tmp:
            row = measure(compiler, count, Path(tmp), source, flags)
            row.pop("workers")
            costs.append(dict(form=form, **row))
    with tempfile.TemporaryDirectory(prefix="fpr-transport-timing-") as tmp:
        timings = time_families(before, after, Path(tmp),
            [(family, high, flat, expected, "FPR_NO_TYPE_SPEC")])
    digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
    args.record.write_text(json.dumps(dict(count=count, before_sha256=digest(before),
        after_sha256=digest(after), costs=costs, throughput=timings), indent=2) + "\n")
    for row in timings:
        allocations = row["cost"]["alloc_requests"]
        if row["form"] in ("after", "explicit"):
            assert allocations == 0, row
        else:
            # Normal regions may also copy live state at a slab boundary.
            assert allocations >= minimum_boxed, row


if __name__ == "__main__":
    main()
