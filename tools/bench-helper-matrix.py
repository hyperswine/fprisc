#!/usr/bin/env python3
"""Internal-clock helpers factorial; build everything before timing anything."""
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
    ap.add_argument("--compiler", type=Path, default=ROOT / "fpr")
    ap.add_argument("--runs", type=int, default=31)
    ap.add_argument("--placement", action="store_true", help="Also compare costed selection, compaction, and both")
    ap.add_argument("--align", type=int, choices=(0, 16, 32, 64, 128), default=0,
                    help="Benchmark-only alignment of all generated function entries")
    args = ap.parse_args()
    if args.runs < 3:
        ap.error("--runs must be at least 3")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT),
               FPR_HARTS="1", XDG_CACHE_HOME=str(out / "cache"))
    for key in list(env):
        if key.startswith("FPR_NO_") or key in (
            "FPR_FOREIGN", "FPR_CC", "FPR_COST_PROBE", "FPR_A64_FIT_GUARDS",
            "FPR_A64_FRAME_PAIRS",
            "FPR_SELF_LOOPS", "FPR_RETAINED_REGISTERS",
            "FPR_COSTED_REGISTERS", "FPR_COMPACT_FRAMES"):
            env.pop(key)

    def run(cmd, mode=env):
        p = subprocess.run(list(map(str, cmd)), cwd=ROOT, env=mode,
                           capture_output=True, text=True, timeout=300)
        assert p.returncode == 0, (cmd, p.returncode, p.stdout, p.stderr)
        return p.stdout

    definitions = (ROOT / "tests/bench/helpers.fpr").read_text().split("main =", 1)[0]
    source = out / "helpers-clock.fpr"
    source.write_text("unsafe base.\nBench.start : Unit -> Unit .\n"
                      "Bench.elapsed : Unit -> Int .\n" + definitions +
                      "main = _ = Bench.start Unit; value = loop 10000000 0;\n"
                      '  ns = Bench.elapsed Unit; print "{value} {ns}".\n')
    variants = {"off": (0, 0, 0, 0), "loops": (0, 1, 0, 0),
                "registers": (1, 0, 0, 0), "both": (1, 1, 0, 0)}
    if args.placement:
        variants.update(costed=(0, 0, 1, 0), compact=(0, 0, 0, 1), placed=(0, 1, 1, 1))
    executables = {}
    for label, (registers, loops, costed, compact) in variants.items():
        exe = out / label
        mode = dict(env, FPR_RETAINED_REGISTERS=str(registers), FPR_SELF_LOOPS=str(loops),
                    FPR_COSTED_REGISTERS=str(costed), FPR_COMPACT_FRAMES=str(compact))
        if args.align:
            mode.update(FPR_CC=str(ROOT / "tools/bench-cc-layout.py"),
                        FPR_BENCH_ASM_DIR=str(out / ("asm-" + label)),
                        FPR_BENCH_ALIGN=str(args.align), FPR_BENCH_PAIRS="0")
        run([args.compiler.resolve(), "build", source, "--harts", "1",
             "--with", ROOT / "tests/bench/workers_clock.c", "--keep", "-o", exe], mode)
        executables[label] = exe
    samples = {k: [] for k in variants}

    def sample(label, keep):
        value, ns = map(int, run([executables[label]]).split())
        assert value == 1259995281, (label, value)
        if keep:
            samples[label].append(ns)

    for label in variants:
        sample(label, False)
    labels = list(variants)
    # Rotate which variant runs first, and reverse every other block of four.
    for i in range(args.runs):
        order = labels[i % len(labels):] + labels[:i % len(labels)]
        if (i // len(labels)) % 2:
            order.reverse()
        for label in order:
            sample(label, True)
        print(f"round {i + 1}/{args.runs}", flush=True)
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    result = {
        "revision": run(["git", "rev-parse", "HEAD"]).strip(),
        "compiler_sha256": digest(args.compiler.resolve()),
        "source": source.read_text(), "source_sha256": digest(source),
        "platform": platform.platform(),
        "function_alignment": args.align,
        "protocol": {"runs": args.runs, "warmups": 1, "harts": 1,
                     "timer": "internal CLOCK_MONOTONIC, excludes startup/printing",
                     "order": "rotating and reversed blocks",
                     "limits": "Host background work/frequency uncontrolled; no energy measurement"},
        "variants": {k: {"retained_registers": r, "self_loops": l,
                         "costed_registers": c, "compact_frames": f}
                     for k, (r, l, c, f) in variants.items()},
        "samples_ns": samples,
        "medians_ns": {k: statistics.median(v) for k, v in samples.items()},
        "binary_sha256": {k: digest(v) for k, v in executables.items()},
    }
    (out / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result["medians_ns"], indent=2))


if __name__ == "__main__":
    main()
