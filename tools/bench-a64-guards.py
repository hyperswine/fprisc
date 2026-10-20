#!/usr/bin/env python3
"""Paired native codegen experiments; retained sources, assembly, hashes and samples."""
import argparse
import hashlib
import json
import os
import platform
import statistics
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--output", type=Path, required=True)
    ap.add_argument("--runs", type=int, default=15)
    experiment = ap.add_mutually_exclusive_group()
    experiment.add_argument("--before-compiler", type=Path, help="Compare frozen compiler with current compiler, guards off in both")
    experiment.add_argument("--self-loops", action="store_true", help="Compare FPR_SELF_LOOPS off/on, guards off in both")
    experiment.add_argument("--retained-registers", action="store_true", help="Compare retained-access register scoring off/on")
    experiment.add_argument("--placement", action="store_true", help="Compare bounded register selection plus compact frames off/on")
    experiment.add_argument("--frame-pairs", action="store_true", help="Compare A64 paired frame-link saves/restores off/on")
    ap.add_argument("--with-self-loops", action="store_true", help="With --retained-registers, also enable frame reuse in the on variant")
    ap.add_argument("--with-frame-pairs", action="store_true", help="With --placement, also enable A64 paired frames in the on variant")
    args = ap.parse_args()
    if args.with_self_loops and not (args.retained_registers or args.placement):
        ap.error("--with-self-loops requires --retained-registers or --placement")
    if args.with_frame_pairs and not args.placement:
        ap.error("--with-frame-pairs requires --placement")
    if args.runs < 3:
        ap.error("--runs must be at least 3")
    if platform.machine() not in ("arm64", "aarch64"):
        ap.error("this experiment requires native A64")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT),
               XDG_CACHE_HOME=str(out / "cache"), FPR_HARTS="1")
    # Freeze relevant compiler modes instead of inheriting an editor/debug run.
    for key in list(env):
        if key.startswith("FPR_NO_") or key in ("FPR_FOREIGN", "FPR_COST_PROBE", "FPR_CC", "FPR_A64_FIT_GUARDS", "FPR_A64_FRAME_PAIRS", "FPR_SELF_LOOPS", "FPR_RETAINED_REGISTERS", "FPR_COSTED_REGISTERS", "FPR_COMPACT_FRAMES"):
            env.pop(key)
    def run(cmd, mode=env):
        p = subprocess.run(list(map(str, cmd)), cwd=ROOT, env=mode,
                           text=True, capture_output=True, timeout=300)
        if p.returncode:
            raise RuntimeError(f"{cmd}: {p.returncode}\n{p.stdout}\n{p.stderr}")
        return p.stdout
    clock = ROOT / "tests/bench/workers_clock.c"
    sources = {
        "fib": (
            "fib : unsafe Int -> Int .\n"
            "fib n = if n < 2 then n else fib (n - 1) + fib (n - 2).\n",
            "fib 35", 9227465),
        "sum": (
            "loop : unsafe Int -> Int -> Int .\n"
            "loop n a = if n == 0 then a else loop (n - 1) (a + n).\n",
            "loop 10000000 0", 50000005000000),
        "pipeline": (
            "inc x = x + 1.\nabove x = x > 500000.\nweighted a x = a + 2 * x.\n",
            "0", 750000500007),
    }
    targets = {}
    def compiler(label):
        return args.before_compiler.resolve() if args.before_compiler and label == "off" else ROOT / "fpr"
    def mode(label):
        # The frozen pre-literal compiler used the old disable switch.
        return dict(env, FPR_NO_A64_GUARDS="1",
                    FPR_A64_FRAME_PAIRS="1" if (args.frame_pairs or args.with_frame_pairs) and label == "on" else "0",
                    FPR_COSTED_REGISTERS="1" if args.placement and label == "on" else "0",
                    FPR_COMPACT_FRAMES="1" if args.placement and label == "on" else "0",
                    FPR_SELF_LOOPS="1" if (args.self_loops or args.with_self_loops) and label == "on" else "0",
                    FPR_RETAINED_REGISTERS="1" if args.retained_registers and label == "on" else "0",
                    FPR_A64_FIT_GUARDS="1" if not (args.before_compiler or args.self_loops or args.retained_registers or args.placement or args.frame_pairs) and label == "on" else "0")
    for name, (defs, expr, expected) in sources.items():
        source = out / (name + ".fpr")
        body = (f"_ = Bench.start Unit; value = {expr}; ns = Bench.elapsed Unit;\n"
                '  print "{value} {ns}".\n')
        if name == "pipeline":
            body = ("v = Vec.iota 1000000; _ = Bench.start Unit;\n"
                    "  (value, v) = Vec.fold weighted 7 (Vec.filter above (Vec.map inc v));\n"
                    "  ns = Bench.elapsed Unit; _ = Vec.free v;\n"
                    '  print "{value} {ns}".\n')
        source.write_text("unsafe base.\nBench.start : Unit -> Unit .\n"
                          "Bench.elapsed : Unit -> Int .\n" + defs + "main =\n  " + body)
        for label, off in (("off", "1"), ("on", "0")):
            exe = out / (name + "-" + label)
            run([compiler(label), "build", source, "--harts", "1",
                 "--with", clock, "--keep", "-o", exe],
                mode(label))
            targets[name + "-" + label] = ([exe], expected)
    # C fixtures are separate translation units, so the driver cannot fold fib.
    csource = out / "fib-c.c"
    csource.write_text("""
#include <stdint.h>
long fib_plain(long n) {
    if (n < 2) return n;
    return fib_plain(n-1) + fib_plain(n-2);
}
static long fit63(long r) {
    if (r < -4611686018427387904L || r > 4611686018427387903L) __builtin_trap();
    return r;
}
long fib_checked(long n) {
    if (n < 2) return n;
    long a = fib_checked(fit63(n-1));
    long b = fib_checked(fit63(n-2));
    long r;
    if (__builtin_add_overflow(a,b,&r)) __builtin_trap();
    return fit63(r);
}
""")
    driver = out / "fib-driver.c"
    driver.write_text("""
#include <stdio.h>
#include <time.h>
extern long fib_plain(long), fib_checked(long);
int main(int argc, char **argv) {
    struct timespec a,b;
    if (clock_gettime(CLOCK_MONOTONIC,&a)) return 2;
    long r = argc > 1 ? fib_checked(35) : fib_plain(35);
    if (clock_gettime(CLOCK_MONOTONIC,&b)) return 2;
    if (r != 9227465) return 1;
    printf("%ld %lld\\n",r,(long long)(b.tv_sec-a.tv_sec)*1000000000LL+b.tv_nsec-a.tv_nsec);
    return 0;
}
""")
    run(["cc", "-O2", "-S", csource, "-o", out / "fib-c.s"])
    run(["cc", "-O2", csource, driver, "-o", out / "fib-c"])
    targets["c-plain"] = ([out / "fib-c"], 9227465)
    targets["c-checked63"] = ([out / "fib-c", "checked"], 9227465)
    # Include existing output-checked workloads, with process wall time clearly
    # distinguished from the internal-timer fixtures above.
    for name in ("byteloop", "helpers", "sha"):
        for label, off in (("off", "1"), ("on", "0")):
            exe = out / (name + "-" + label)
            run([compiler(label), "build", ROOT / f"tests/bench/{name}.fpr",
                 "--harts", "1", "--keep", "-o", exe],
                mode(label))
            targets[name + "-" + label] = (
                [exe], (ROOT / f"tests/bench/{name}.expected").read_text())
    samples = {name: [] for name in targets}
    def sample(name, keep):
        cmd, expected = targets[name]
        start = time.perf_counter_ns()
        text = run(cmd)
        wall = time.perf_counter_ns() - start
        if isinstance(expected, int):
            value, ns = map(int, text.split())
            assert value == expected, (name, value, expected)
        else:
            assert text == expected, (name, text, expected)
            ns = wall
        if keep:
            samples[name].append(ns)
    for name in targets:
        sample(name, False)
    names = list(targets)
    for i in range(args.runs):
        for name in (names if i % 2 == 0 else list(reversed(names))):
            sample(name, True)
        print(f"paired round {i+1}/{args.runs}", flush=True)
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    result = {
        "experiment": "A64 paired frame saves/restores off/on" if args.frame_pairs else
                      ("bounded register selection and compact frames" + (" and self-tail frame reuse" if args.with_self_loops else "") + (" and A64 paired frames" if args.with_frame_pairs else "") + " off/on, guards disabled") if args.placement else
                      ("retained-access register scoring" + (" and self-tail frame reuse" if args.with_self_loops else "") + " off/on, guards disabled") if args.retained_registers else
                      "self-tail frame reuse off/on, guards disabled" if args.self_loops else
                      "frozen-before/current-after, guards disabled" if args.before_compiler else "A64 fit guards off/on",
        "before_compiler_sha256": digest(args.before_compiler.resolve()) if args.before_compiler else None,
        "base_revision": run(["git", "rev-parse", "HEAD"]).strip(),
        "platform": platform.platform(), "cc": run(["cc", "--version"]),
        "compiler_sha256": digest(ROOT / "fpr"),
        "source_sha256": {str(p.relative_to(ROOT)): digest(p)
                          for p in [ROOT / "compiler" / x for x in
                                    ("A64.hs", "Codegen.hs", "Compile.hs", "Build.hs")]},
        "protocol": {"runs": args.runs, "harts": 1, "warmups": 1,
                     "order": "forward/reverse alternating",
                     "internal_timers": ["fib", "sum", "pipeline", "c-plain", "c-checked63"],
                     "process_wall_timers": ["byteloop", "helpers", "sha"],
                     "limits": "Host background work and frequency are uncontrolled. C lacks actor runtime and panic diagnostics."},
        "samples_ns": samples,
        "medians_ns": {name: statistics.median(xs) for name, xs in samples.items()},
        "best_ns": {name: min(xs) for name, xs in samples.items()},
        "binary_sha256": {name: digest(cmd[0]) for name, (cmd, _) in targets.items()},
        "binary_bytes": {name: cmd[0].stat().st_size for name, (cmd, _) in targets.items()},
    }
    (out / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    for name in ("fib", "sum", "pipeline", "byteloop", "helpers", "sha"):
        old, new = (result["medians_ns"][name + "-" + x] for x in ("off", "on"))
        print(f"{name}: {old/1e6:.3f} -> {new/1e6:.3f} ms; {(1-new/old)*100:.2f}% less time")
    print(f"C fib: plain {result['medians_ns']['c-plain']/1e6:.3f} ms; checked63 {result['medians_ns']['c-checked63']/1e6:.3f} ms")

if __name__ == "__main__":
    main()
