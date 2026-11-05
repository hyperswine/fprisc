#!/usr/bin/env python3
"""Measure complete hosted compiler cost and root RV64 code for a recursive group."""

import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def group_source(size, count):
    members = [
        f"f{i} n a = if n <= 0 then a else f{(i + 1) % size} (n - 1) (a + 1)."
        for i in range(size)
    ]
    return "unsafe base.\n" + "\n".join(members) + f"\nmain = print (f0 {count} 0).\n"


def measure(compiler, size, directory, source_text=None, switches=None):
    source = directory / "main.fpr"
    source.write_text(
        group_source(size, 2 * size) if source_text is None else source_text
    )
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("FPR_") and key != "GHCRTS"
    }
    env.update(
        FPR_HOME=str(ROOT),
        FPR_PATH=str(ROOT),
        XDG_CACHE_HOME=str(directory / "cache"),
        FPR_NO_INLINE="1",
    )
    if switches is not None:
        env.pop("FPR_NO_INLINE")
        env.update(switches)
    assembly = directory / "main.s"
    stats = directory / "rts"
    start = time.monotonic()
    subprocess.run(
        [
            compiler,
            "compile",
            "--target=rv64",
            "--system=posix",
            source,
            assembly,
            "+RTS",
            "-t" + str(stats),
            "--machine-readable",
            "-RTS",
        ],
        cwd=ROOT,
        env=env,
        stdout=subprocess.DEVNULL,
        check=True,
        timeout=240,
    )
    elapsed = time.monotonic() - start
    rts = dict(ast.literal_eval(stats.read_text().split("\n", 1)[1]))
    subprocess.run(
        [
            "riscv64-unknown-elf-gcc",
            "-march=rv64imafdc_zicsr",
            "-mabi=lp64",
            "-c",
            "main.s",
            "-o",
            "main.o",
        ],
        cwd=directory,
        check=True,
    )
    sizes = subprocess.check_output(
        ["riscv64-unknown-elf-size", "-A", "main.o"], cwd=directory, text=True
    )
    disassembly = subprocess.check_output(
        ["riscv64-unknown-elf-objdump", "-dr", "main.o"], cwd=directory
    )
    return dict(
        size=size,
        workers=len(
            re.findall(r"^# fn \$worker\.scalar\.f\d+\b", assembly.read_text(), re.M)
        ),
        allocated_bytes=int(rts["bytes allocated"]),
        peak_bytes=int(rts["max_bytes_used"]),
        seconds=elapsed,
        text_bytes=sum(
            int(v) for v in re.findall(r"^\.text(?:\.\S+)?\s+(\d+)", sizes, re.M)
        ),
        disassembly_sha256=hashlib.sha256(disassembly).hexdigest(),
        source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
    )


def timed_workloads(before, after, directory):
    # Compiler and counter runs finish before the alternating plain runs.
    count = 500_000
    depth = 300
    declarations = "; ".join(
        f"v{i} = {'n' if i == 0 else 'v' + str(i - 1)} + 1" for i in range(depth)
    )

    def wide_source(explicit):
        make = f"produce n = {declarations}; " + (
            f"v{depth - 1}." if explicit else f"Cell v{depth - 1}."
        )
        observe = (
            "observe n = produce n."
            if explicit
            else "observe n = case produce n of Cell x -> x."
        )
        return "\n".join(
            [
                "unsafe base.",
                "Cell = Type (Cell Int).",
                make,
                observe,
                "consume n a = if n <= 0 then a else consume (n - 1) (a + observe n).",
                f"main = print (consume {count} 0).",
                "",
            ]
        )

    families = [
        (
            "scalar-group",
            group_source(131, 20_000_000),
            group_source(1, 20_000_000),
            20_000_000,
            "FPR_NO_SCALAR_WORKERS",
        ),
        (
            "wide-return",
            wide_source(False),
            wide_source(True),
            count * (count + 1) // 2 + depth * count,
            "FPR_NO_PAIR_RETURNS",
        ),
    ]
    return time_families(before, after, directory, families)


def time_families(before, after, directory, families, before_home=None):
    modes = []
    base = {k: v for k, v in os.environ.items() if not k.startswith("FPR_")}
    base.update(
        FPR_HOME=str(ROOT),
        FPR_PATH=str(ROOT),
        XDG_CACHE_HOME=str(directory / "cache"),
        FPR_HARTS="1",
    )
    for name, source, explicit, answer, switch in families:
        for form, compiler in [
            ("before", before),
            ("after", after),
            ("explicit", after),
            ("rollback", after),
        ]:
            tag = name + "-" + form
            src = directory / (tag + ".fpr")
            src.write_text(explicit if form == "explicit" else source)
            env = dict(base)
            if form == "before" and before_home is not None:
                env.update(FPR_HOME=str(before_home), FPR_PATH=str(before_home))
            if form == "rollback":
                env[switch] = "1"
            expected = str(answer) + "\n"
            for probe in (True, False):
                exe = directory / (tag + ("-probe" if probe else ""))
                runenv = (
                    dict(env, FPR_COST_PROBE="1", FPR_COST_REPORT="1") if probe else env
                )
                subprocess.run(
                    [
                        compiler,
                        "build",
                        src,
                        "--harts",
                        "4",
                        *([] if probe else ["--keep"]),
                        "-o",
                        exe,
                    ],
                    cwd=ROOT,
                    env=runenv,
                    check=True,
                    capture_output=True,
                    timeout=180,
                )
                run = subprocess.run(
                    [exe],
                    env=runenv,
                    capture_output=True,
                    text=True,
                    check=True,
                    timeout=60,
                )
                assert run.stdout == expected
                if probe:
                    cost = json.loads(
                        re.search(r"\[fpr cost\] (\{.*\})", run.stderr)[1]
                    )
                else:
                    assert not run.stderr
            files = list((directory / "cache/fpr/build").glob(tag + "-*.s"))
            assert len(files) == 1, files
            workers = re.findall(r"^# fn (\$(?:worker|carrier)\.\S+) ", files[0].read_text(), re.M)
            row = dict(
                family=name,
                root_workers=workers,
                form=form,
                compiler_sha256=hashlib.sha256(compiler.read_bytes()).hexdigest(),
                source_sha256=hashlib.sha256(src.read_bytes()).hexdigest(),
                cost=cost,
                samples_seconds=[],
            )
            modes.append((row, exe, env, expected))
    for i in range(13):
        for row, exe, env, expected in modes if i % 2 == 0 else reversed(modes):
            start = time.perf_counter()
            run = subprocess.run(
                [exe], env=env, capture_output=True, text=True, check=True, timeout=60
            )
            elapsed = time.perf_counter() - start
            assert run.stdout == expected and not run.stderr
            row["samples_seconds"].append(elapsed)
    rows = []
    for row, _, _, _ in modes:
        row["median_seconds"] = statistics.median(row["samples_seconds"])
        rows.append(row)
        print(
            row["family"],
            row["form"],
            row["cost"]["alloc_requests"],
            row["median_seconds"],
            flush=True,
        )
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--compiler",
        action="append",
        required=True,
        type=Path,
        help="repeat to compare saved compilers",
    )
    parser.add_argument("--sizes", nargs="+", type=int, default=[16, 32, 64, 128, 256])
    parser.add_argument("--record", required=True, type=Path)
    parser.add_argument(
        "--throughput",
        action="store_true",
        help="also time the first and last compiler on native ARM64/x86-64",
    )
    args = parser.parse_args()
    if min(args.sizes) < 1:
        parser.error("group sizes must be positive")
    results = []
    for compiler in args.compiler:
        sha = hashlib.sha256(compiler.read_bytes()).hexdigest()
        for size in args.sizes:
            with tempfile.TemporaryDirectory(prefix="fpr-scalar-component-") as tmp:
                row = measure(compiler.resolve(), size, Path(tmp))
            results.append(dict(compiler_sha256=sha, **row))
            print(
                f"{sha[:10]}: {size} functions, {row['workers']} workers, {row['text_bytes']} code bytes, {row['allocated_bytes']:,} allocated compiler bytes",
                flush=True,
            )
    with tempfile.TemporaryDirectory(prefix="fpr-hosted-worker-timing-") as tmp:
        timing = (
            timed_workloads(
                args.compiler[0].resolve(), args.compiler[-1].resolve(), Path(tmp)
            )
            if args.throughput
            else []
        )
    args.record.write_text(
        json.dumps(
            dict(
                tool_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                results=results,
                throughput=timing,
            ),
            indent=2,
        )
        + "\n"
    )


if __name__ == "__main__":
    main()
