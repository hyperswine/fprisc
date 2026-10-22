#!/usr/bin/env python3
"""The M3 investment review's paired measurements (docs/2026-10-21-TYPED-IR-M3.md,
docs/2026-10-20-TYPED-NATIVE-IR-PLAN.md "M3 investment review").

Variants cover the typed backend's entry, frame-link and allocation settings.
Historical legacy comparisons are reproducible from the pre-retirement revision;
this AArch64-only driver no longer requests that retired backend.
"""
import argparse
import hashlib
import json
import os
import platform
import random
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

VARIANTS = {
    "typed-ir": {"FPR_TYPED_IR_BACKEND": "mixed"},
    "typed-ir-forward": {"FPR_TYPED_IR_BACKEND": "mixed", "FPR_TYPED_IR_FORWARD_PARAMS": "1"},
    "typed-ir-entry": {"FPR_TYPED_IR_BACKEND": "mixed", "FPR_TYPED_IR_FORWARD_PARAMS": "1", "FPR_TYPED_IR_SHALLOW_STACK": "1"},
    "typed-ir-shallow": {"FPR_TYPED_IR_BACKEND": "mixed", "FPR_TYPED_IR_SHALLOW_STACK": "1"},
    "typed-ir-noloop": {"FPR_TYPED_IR_BACKEND": "mixed", "FPR_TYPED_IR_SELF_LOOPS": "0"},
    # the fib experiments (docs/2026-10-22-TYPED-IR-FIB.md): each alone, then cumulative
    "typed-ir-nopairs": {"FPR_TYPED_IR_BACKEND": "mixed", "FPR_TYPED_IR_LINK_PAIRS": "0"},
    "typed-ir-args": {"FPR_TYPED_IR_BACKEND": "mixed", "FPR_TYPED_IR_ENTRY_ARGS": "1"},
    "typed-ir-args-split": {"FPR_TYPED_IR_BACKEND": "mixed", "FPR_TYPED_IR_ENTRY_ARGS": "1", "FPR_TYPED_IR_SPLIT_ENTRY": "1"},
    "typed-ir-args-split-wrap": {"FPR_TYPED_IR_BACKEND": "mixed", "FPR_TYPED_IR_ENTRY_ARGS": "1", "FPR_TYPED_IR_SPLIT_ENTRY": "1", "FPR_TYPED_IR_SHRINK_WRAP": "1"},
    "typed-ir-all": {"FPR_TYPED_IR_BACKEND": "mixed", "FPR_TYPED_IR_ENTRY_ARGS": "1", "FPR_TYPED_IR_SPLIT_ENTRY": "1", "FPR_TYPED_IR_SHRINK_WRAP": "1", "FPR_TYPED_IR_LINK_PAIRS": "1"},
}
INTERNAL = {
    "fib": ("fib : unsafe Int -> Int .\nfib n = if n < 2 then n else fib (n - 1) + fib (n - 2).\n", "fib 35", 9227465),
    "sum": ("loop : unsafe Int -> Int -> Int .\nloop n a = if n == 0 then a else loop (n - 1) (a + n).\n", "loop 10000000 0", 50000005000000),
    "pipeline": ("inc x = x + 1.\nabove x = x > 500000.\nweighted a x = a + 2 * x.\n", "0", 750000500007),
}
# Reuse the independently checked record workload, excluding hosted main.
INTERNAL["records"] = ((ROOT / "tests/typed_ir/record_kernels.fpr").read_text()
    .split("main =")[0].replace("unsafe base.\n", ""), "0",
    7 + sum(2*(10*i+45)+3 for i in range(100000) if 10*i+45 > 400))
WALL = ["helpers", "sha", "floatcmp", "nbody"]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--output", type=Path, required=True)
    ap.add_argument("--runs", type=int, default=31)
    ap.add_argument("--compiler", type=Path, default=ROOT / "fpr")
    ap.add_argument("--variants", default=",".join(VARIANTS), help="comma-separated subset")
    ap.add_argument("--workloads", default=",".join(list(INTERNAL) + WALL))
    args = ap.parse_args()
    if args.runs < 3:
        ap.error("--runs must be at least 3")
    if platform.machine() not in ("arm64", "aarch64"):
        ap.error("this experiment requires native AArch64 (the typed-IR backend's host target here)")
    variants = [v for v in args.variants.split(",") if v]
    unknown = set(variants) - VARIANTS.keys()
    if unknown:
        ap.error("unknown or retired variants: " + ", ".join(sorted(unknown)))
    workloads = [w for w in args.workloads.split(",") if w]
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    compiler = args.compiler.resolve()
    base = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), FPR_HARTS="1")
    for key in list(base):
        if key.startswith("FPR_NO_") or key.startswith("FPR_TYPED_IR") or key in (
                "FPR_FOREIGN", "FPR_CC", "FPR_COST_PROBE",
                "FPR_SELF_LOOPS", "FPR_RETAINED_REGISTERS", "FPR_COSTED_REGISTERS", "FPR_COMPACT_FRAMES"):
            base.pop(key)

    def run(cmd, env, timeout=600):
        p = subprocess.run(list(map(str, cmd)), cwd=ROOT, env=env, text=True, capture_output=True, timeout=timeout)
        if p.returncode:
            raise RuntimeError(f"{cmd}: {p.returncode}\n{p.stdout[-3000:]}\n{p.stderr[-3000:]}")
        return p.stdout, p.stderr

    # the sources
    clock = ROOT / "tests/bench/workers_clock.c"
    sources = {}
    for name, (defs, expr, expected) in INTERNAL.items():
        src = out / f"{name}.fpr"
        body = (f"_ = Bench.start Unit; value = {expr}; ns = Bench.elapsed Unit;\n" '  print "{value} {ns}".\n')
        if name == "pipeline":
            body = ("v = Vec.iota 1000000; _ = Bench.start Unit;\n"
                    "  (value, v) = Vec.fold weighted 7 (Vec.filter above (Vec.map inc v));\n"
                    "  ns = Bench.elapsed Unit; _ = Vec.free v;\n"
                    '  print "{value} {ns}".\n')
        if name == "records":
            body = ("v = fill (Vec.new Unit) 0 100000; c = sampleRow 2; _ = Bench.start Unit;\n"
                    "  w = probeRecordMap v; x = probeRecordCaptured c w; y = probeRecordFilter x;\n"
                    "  (value,z) = probeRecordFold 2 3 7 y; ns = Bench.elapsed Unit; _ = Vec.free z;\n"
                    '  print "{value} {ns}".\n')
        src.write_text("unsafe base.\nBench.start : Unit -> Unit .\nBench.elapsed : Unit -> Int .\n" + defs + "main =\n  " + body)
        sources[name] = (src, expected, [str(clock)])
    for name in WALL:
        sources[name] = (ROOT / f"tests/bench/{name}.fpr", (ROOT / f"tests/bench/{name}.expected").read_text(), [])
    warm = out / "warm.fpr"
    warm.write_text("unsafe base.\nmain = print \"warm\".\n")

    # build everything first: a private cache per variant (the prelude unit
    # is compiled under the variant's mode too), warmed by a trivial
    # program so the recorded compile time is the root's
    builds = {}
    for variant in variants:
        env = dict(base, XDG_CACHE_HOME=str(out / "cache" / variant), **VARIANTS[variant])
        t0 = time.perf_counter()
        run([compiler, "build", warm, "--harts", "1", "-o", out / f"warm-{variant}"], env)
        prelude_s = time.perf_counter() - t0
        for name in workloads:
            src, expected, extra = sources[name]
            exe = out / f"{name}-{variant}"
            cmd = ["/usr/bin/time", "-l", str(compiler), "build", str(src), "--harts", "1", "--keep", "-v", "-o", str(exe)]
            for x in extra:
                cmd += ["--with", x]
            t0 = time.perf_counter()
            _, err = run(cmd, env)
            wall = time.perf_counter() - t0
            m = re.search(r"(\d+)\s+maximum resident set size", err)
            rss = int(m.group(1)) if m else None
            kept = re.search(r"fpr build: kept (\S+)", err)
            asm_text = Path(kept.group(1)).read_text() if kept else ""
            notes = [l for l in err.splitlines() if l.startswith("typed-ir-backend: ")]
            native_fns = re.findall(r"^# fn (\S+) \(arity \d+\) typed-ir a64", asm_text, re.M)
            legacy_fns = re.findall(r"^# fn (\S+) \(arity \d+\)(?! typed-ir)", asm_text, re.M)
            size_out, _ = run(["size", exe], env)
            text_bytes = int(size_out.splitlines()[1].split()[0])
            builds[(name, variant)] = {
                "exe": str(exe), "expected": expected,
                "compile_wall_s": wall, "compile_max_rss_bytes": rss, "prelude_warm_s": prelude_s,
                "binary_bytes": exe.stat().st_size, "text_bytes": text_bytes,
                "binary_sha256": hashlib.sha256(exe.read_bytes()).hexdigest(),
                "native_functions_root": native_fns, "legacy_functions_root": len(legacy_fns),
                "notes": notes[:400],
                "root_asm_lines": len(asm_text.splitlines()),
            }
            print(f"built {name}-{variant}: {wall:.2f}s, rss {rss}, native {len(native_fns)} / legacy {len(legacy_fns)} in the root", flush=True)
    env_run = dict(base)
    samples = {k: {"internal_ns": [], "wall_ns": []} for k in builds}

    def sample(key, keep):
        b = builds[key]
        t0 = time.perf_counter_ns()
        text, _ = run([b["exe"]], env_run)
        wall = time.perf_counter_ns() - t0
        if isinstance(b["expected"], int):
            value, ns = map(int, text.split())
            assert value == b["expected"], (key, value)
        else:
            assert text == b["expected"], (key, text)
            ns = None
        if keep:
            samples[key]["wall_ns"].append(wall)
            if ns is not None:
                samples[key]["internal_ns"].append(ns)

    keys = list(builds)
    for k in keys:
        sample(k, False)
    for i in range(args.runs):
        order = keys[i % len(keys):] + keys[:i % len(keys)]
        if (i // len(keys)) % 2:
            order.reverse()
        for k in order:
            sample(k, True)
        print(f"round {i + 1}/{args.runs}", flush=True)

    def digest(p):
        return hashlib.sha256(Path(p).read_bytes()).hexdigest()
    dirty = run(["git", "status", "--porcelain"], base)[0]
    patch = run(["git", "diff", "--binary", "HEAD"], base)[0]
    (out / "source.patch").write_text(patch)
    result = {
        "revision": run(["git", "rev-parse", "HEAD"], base)[0].strip(),
        "compiler_sha256": digest(compiler),
        "working_tree_status": dirty,
        "source_patch_sha256": hashlib.sha256(patch.encode()).hexdigest(),
        "platform": platform.platform(),
        "cc": run(["cc", "--version"], base)[0].splitlines()[0],
        "protocol": {"runs": args.runs, "warmups": 1, "harts": 1,
                     "order": "rotating by one each round, reversed every other block",
                     "internal_timers": list(INTERNAL), "process_wall_timers": WALL,
                     "limits": "host background work and frequency uncontrolled; no energy measurement; "
                               "mixed-mode coverage is recorded per build; speedups cannot be attributed to one pass without a separate comparison"},
        "variants": {v: VARIANTS[v] for v in variants},
        "builds": {f"{n}-{v}": {k: x for k, x in b.items() if k != "expected"} for (n, v), b in builds.items()},
        "samples": {f"{n}-{v}": s for (n, v), s in samples.items()},
    }
    (out / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    (out / "summary.md").write_text(summarise(result, workloads, variants))
    print((out / "summary.md").read_text())


def paired(a, b, rng):
    """b against a on paired samples: medians, median of per-round ratios, faster pairs, bootstrap CI of the median ratio."""
    n = min(len(a), len(b))
    a, b = a[:n], b[:n]
    ratios = [y / x for x, y in zip(a, b)]
    med_a, med_b = statistics.median(a), statistics.median(b)
    boots = []
    for _ in range(2000):
        idx = [rng.randrange(n) for _ in range(n)]
        boots.append(statistics.median([ratios[i] for i in idx]))
    boots.sort()
    return {"n": n, "median_a_ms": med_a / 1e6, "median_b_ms": med_b / 1e6,
            "median_ratio": statistics.median(ratios), "ratio_of_medians": med_b / med_a,
            "faster_pairs": sum(1 for r in ratios if r < 1),
            "ci95": (boots[int(0.025 * len(boots))], boots[int(0.975 * len(boots)) - 1])}


def summarise(result, workloads, variants):
    rng = random.Random(20261021)
    lines = ["# M3 paired measurements", "", f"revision {result['revision']}, compiler sha256 {result['compiler_sha256'][:12]}, {result['platform']}",
             f"{result['protocol']['runs']} rounds; internal timers: {', '.join(result['protocol']['internal_timers'])}; process wall: {', '.join(result['protocol']['process_wall_timers'])}", ""]
    for against in [v for v in ("legacy", "legacy-best", "typed-ir") if v in variants]:
        for subject in [v for v in variants if v.startswith("typed-ir") and v != against]:
            lines += [f"## {subject} against {against}", "",
                      "| workload | timer | " + against + " median ms | " + subject + " median ms | median of paired ratios | 95% bootstrap CI | faster pairs |",
                      "|---|---|---:|---:|---:|---:|---:|"]
            for w in workloads:
                for timer in ("internal_ns", "wall_ns"):
                    a = result["samples"][f"{w}-{against}"][timer]
                    b = result["samples"][f"{w}-{subject}"][timer]
                    if not a or not b:
                        continue
                    p = paired(a, b, rng)
                    lines.append(f"| {w} | {timer.replace('_ns', '')} | {p['median_a_ms']:.3f} | {p['median_b_ms']:.3f} | {p['median_ratio']:.4f} | {p['ci95'][0]:.4f}..{p['ci95'][1]:.4f} | {p['faster_pairs']}/{p['n']} |")
            lines.append("")
    lines += ["## Builds", "", "| build | compile wall s | compiler max RSS MiB | binary bytes | __TEXT bytes | native functions in the root | legacy functions in the root |", "|---|---:|---:|---:|---:|---:|---:|"]
    for k, b in result["builds"].items():
        rss = b["compile_max_rss_bytes"]
        lines.append(f"| {k} | {b['compile_wall_s']:.2f} | {rss / 2**20 if rss else float('nan'):.1f} | {b['binary_bytes']} | {b['text_bytes']} | {len(b['native_functions_root'])} | {b['legacy_functions_root']} |")
    lines += ["", "## Coverage under the backend (root unit)", ""]
    for k, b in result["builds"].items():
        if b["native_functions_root"]:
            lines.append(f"- {k}: " + ", ".join(b["native_functions_root"]))
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    sys.exit(main())
