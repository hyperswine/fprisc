#!/usr/bin/env python3
"""Isolate A64 frame-link pairing, with an independently aligned comparison."""
import argparse
import hashlib
import json
import os
import platform
import statistics
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--output", type=Path, required=True)
    ap.add_argument("--runs", type=int, default=31)
    args = ap.parse_args()
    if platform.machine() not in ("arm64", "aarch64"):
        ap.error("requires a native A64 host")
    if args.runs < 3:
        ap.error("--runs must be at least 3")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    env = {k: v for k, v in os.environ.items() if not k.startswith("FPR_")}
    env.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), FPR_HARTS="1",
               XDG_CACHE_HOME=str(out / "cache"), FPR_CC=str(ROOT / "tools/bench-cc-layout.py"))
    source = out / "fib-clock.fpr"
    source.write_text("""unsafe base.
Bench.start : Unit -> Unit .
Bench.elapsed : Unit -> Int .
fib : unsafe Int -> Int .
fib n = if n < 2 then n else fib (n - 1) + fib (n - 2).
main = _ = Bench.start Unit; value = fib 35;
  ns = Bench.elapsed Unit; print "{value} {ns}".
""")

    def run(cmd, mode=env):
        p = subprocess.run(list(map(str, cmd)), cwd=ROOT, env=mode,
                           text=True, capture_output=True, timeout=300)
        assert p.returncode == 0, (cmd, p.returncode, p.stdout, p.stderr)
        return p.stdout

    variants = {"ordinary": (0, 0), "paired": (1, 0),
                "aligned": (0, 64), "aligned-paired": (1, 64)}
    for label, (paired, alignment) in variants.items():
        mode = dict(env, FPR_BENCH_ASM_DIR=str(out / ("asm-" + label)),
                    FPR_BENCH_PAIRS=str(paired), FPR_BENCH_ALIGN=str(alignment))
        run([ROOT / "fpr", "build", source, "--harts", "1", "--keep",
             "--with", ROOT / "tests/bench/workers_clock.c", "-o", out / label], mode)
        records = [r for p in (out / ("asm-" + label)).glob("link-*.json")
                   for r in json.loads(p.read_text())]
        if paired:
            assert sum(r["paired_saves"] for r in records) > 0
            assert sum(r["paired_restores"] for r in records) > 0
    samples = {k: [] for k in variants}
    labels = list(variants)
    for i in range(-1, args.runs):
        order = labels[i % 4:] + labels[:i % 4]
        if (i // 4) % 2:
            order.reverse()
        for label in order:
            value, ns = map(int, run([out / label]).split())
            assert value == 9227465, (label, value)
            if i >= 0:
                samples[label].append(ns)
        print(f"round {i + 1}/{args.runs}", flush=True)
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    result = {
        "revision": run(["git", "rev-parse", "HEAD"]).strip(),
        "compiler_sha256": digest(ROOT / "fpr"), "source": source.read_text(),
        "source_sha256": digest(source), "platform": platform.platform(),
        "protocol": {"runs": args.runs, "warmups": 1, "harts": 1,
                     "timer": "internal CLOCK_MONOTONIC", "order": "rotating/reversing",
                     "limits": "Benchmark-only assembly edits; no production or scheduler acceptance. Host activity/frequency uncontrolled."},
        "variants": {k: {"pairs": p, "function_alignment": a} for k, (p, a) in variants.items()},
        "samples_ns": samples,
        "medians_ns": {k: statistics.median(v) for k, v in samples.items()},
        "binary_sha256": {k: digest(out / k) for k in variants},
    }
    (out / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result["medians_ns"], indent=2))


if __name__ == "__main__":
    main()
