#!/usr/bin/env python3
"""Compile-time budget: the compiler's own allocation on fixed programs.

Each program is compiled cold (a fresh cache) with the existing ./fpr, which
reports GHC's runtime statistics (+RTS -t). Allocation is deterministic for a
given compiler binary and GHC, so it is the gated number; peak residency is
gated with a wider margin; wall time is reported and never gated (runners
differ). Baselines are kept per GHC version and architecture in
tests/compile_budget.json, because a different GHC allocates differently.

  check_compile_budget.py              compare with this environment's baseline
  check_compile_budget.py --record     write this environment's baseline
  check_compile_budget.py --require-baseline   fail when there is none

A program over budget fails the check. A program well under it passes and
says so: record the new baseline in the same commit as the improvement.
The suite does not rebuild ./fpr (like check_pos_core.py).
"""
import argparse
import ast
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
FPR = ROOT / "fpr"
BASELINE = ROOT / "tests" / "compile_budget.json"
ALLOCATION_MARGIN = 0.10
RESIDENCY_MARGIN = 0.25
TIMEOUT = 900

# (name, source text or None, file): small, one std module, the POS app
PROGRAMS = [
    ("hello", "profile base.\nmain = print 42.\n", None),
    ("std-live", 'profile base.\nLive = use "std/live".\nmain = print 42.\n', None),
    ("pos1", None, ROOT / "examples" / "pos1.fpr"),
]


def environment():
    """The baseline key: the GHC that built ./fpr and the machine."""
    out = subprocess.run([FPR, "+RTS", "--info", "-RTS"], capture_output=True,
                         text=True, timeout=60).stdout
    info = dict(ast.literal_eval(out.strip()))
    return f"ghc-{info['GHC version']} {info['Host platform']}"


def measure(name, text, path, tmp):
    source = path
    if text is not None:
        source = tmp / f"{name}.fpr"
        source.write_text(text)
    stats = tmp / f"{name}.rts"
    env = {**os.environ, "XDG_CACHE_HOME": str(tmp / f"cache-{name}"),
           "FPR_HOME": os.environ.get("FPR_HOME", str(ROOT))}
    env.pop("GHCRTS", None)
    start = time.monotonic()
    p = subprocess.run([FPR, "compile", "--system=posix", source, tmp / f"{name}.s",
                        "+RTS", f"-t{stats}", "--machine-readable", "-RTS"],
                       cwd=ROOT, env=env, capture_output=True, text=True, timeout=TIMEOUT)
    wall = time.monotonic() - start
    assert p.returncode == 0, f"{name}: exit {p.returncode}\n{p.stdout[-2000:]}\n{p.stderr[-2000:]}"
    rts = dict(ast.literal_eval(stats.read_text().split("\n", 1)[1]))
    return {"allocated_bytes": int(rts["bytes allocated"]),
            "max_bytes_used": int(rts["max_bytes_used"]),
            "wall_seconds": round(wall, 1)}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--record", action="store_true", help="write this environment's baseline")
    ap.add_argument("--require-baseline", action="store_true", help="fail without a baseline")
    ap.add_argument("--only", help="one program by name")
    args = ap.parse_args()

    key = environment()
    baselines = json.loads(BASELINE.read_text()) if BASELINE.is_file() else {}
    base = baselines.get(key, {})
    programs = [p for p in PROGRAMS if not args.only or p[0] == args.only]
    assert programs, f"no program named {args.only}"

    results, failures = {}, []
    with tempfile.TemporaryDirectory(prefix="fpr-compile-budget-") as d:
        for name, text, path in programs:
            got = measure(name, text, path, Path(d))
            results[name] = got
            line = (f"{name}: {got['allocated_bytes'] / 1e9:.2f} GB allocated, "
                    f"{got['max_bytes_used'] / 1e6:.0f} MB peak live, {got['wall_seconds']} s")
            want = base.get(name)
            if want:
                alloc = got["allocated_bytes"] / want["allocated_bytes"]
                resid = got["max_bytes_used"] / want["max_bytes_used"]
                line += f" ({alloc - 1:+.1%} allocation, {resid - 1:+.1%} peak vs baseline)"
                if alloc > 1 + ALLOCATION_MARGIN:
                    failures.append(f"{name}: allocation {alloc - 1:+.1%} is over the {ALLOCATION_MARGIN:.0%} margin")
                if resid > 1 + RESIDENCY_MARGIN:
                    failures.append(f"{name}: peak residency {resid - 1:+.1%} is over the {RESIDENCY_MARGIN:.0%} margin")
                if alloc < 1 - ALLOCATION_MARGIN and not args.record:
                    line += " -- under budget: record the new baseline (--record)"
            print(line, flush=True)

    if args.record:
        merged = {**base, **{n: {k: v for k, v in r.items() if k != "wall_seconds"}
                             for n, r in results.items()}}
        baselines[key] = dict(sorted(merged.items()))
        BASELINE.write_text(json.dumps(dict(sorted(baselines.items())), indent=2) + "\n")
        print(f"compile budget: recorded {key} in {BASELINE.relative_to(ROOT)}")
        return
    missing = [n for n in results if n not in base]
    if missing:
        msg = f"compile budget: no baseline for {', '.join(missing)} on {key}"
        if args.require_baseline:
            raise SystemExit(msg)
        print(msg + " (measured above; --record writes it)")
        print("compile budget: exact measurements " + json.dumps(
            {n: {k: v for k, v in results[n].items() if k != "wall_seconds"} for n in missing}, sort_keys=True))
    if failures:
        raise SystemExit("compile budget FAILED:\n  " + "\n  ".join(failures))
    print(f"compile budget: {key} within budget")


if __name__ == "__main__":
    main()
