#!/usr/bin/env python3
"""Link emitted nested return workers to an independent allocator-free RV64 oracle."""

import argparse
import os
import shutil
import tempfile
from pathlib import Path
from check_product_returns import ROOT, run
from product_return_probe import emitted_bodies
from fuel_wrapper import fuel_wrapper


def source(width):
    if width == 1:
        return (
            "unsafe base.\nCell a = Type (Cell a).\nmake n = if n < 0 then make (0 - n) else Cell (Cell n).\n"
            "loop n acc = if n == 0 then acc else case make n of Cell inner -> case inner of Cell x -> loop (n - 1) (acc + x).\nmain = print (loop 100 0).\n"
        )
    half = width // 2
    names = [f"v{i}" for i in range(width)]
    tupled = lambda args: "(" + ",".join(args) + ")"
    values = [f"n + {i}" for i in range(width)]
    return (
        "unsafe base.\nmake n = if n < 0 then make (0 - n) else "
        + tupled([tupled(values[:half]), tupled(values[half:])])
        + ".\n"
        + "loop n acc = if n == 0 then acc else case make n of (a,b) -> case a of "
        + tupled(names[:half])
        + " -> case b of "
        + tupled(names[half:])
        + " -> loop (n - 1) (acc + "
        + " + ".join(f"{v} * {i + 1}" for i, v in enumerate(names))
        + ").\nmain = print (loop 100 0).\n"
    )


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--require-execution", action="store_true")
    args = ap.parse_args()
    missing = [
        name
        for name in ["riscv64-unknown-elf-gcc", "qemu-system-riscv64"]
        if not shutil.which(name)
    ]
    if missing:
        if args.require_execution:
            raise SystemExit(f"Missing {missing}")
        print("Nested return RV64 execution skipped:", missing)
        return
    with tempfile.TemporaryDirectory(prefix="fpr-nested-rv64-") as tmp:
        tmp = Path(tmp)
        env = {k: v for k, v in os.environ.items() if not k.startswith("FPR_")}
        env.update(
            FPR_HOME=str(ROOT),
            FPR_PATH=str(ROOT),
            FPR_NO_INLINE="1",
            FPR_NO_LOOP_REGIONS="1",
            FPR_NO_CALL_REGIONS="1",
            FPR_NO_FIELD_WORKERS="1",
            FPR_NO_SCALAR_WORKERS="1",
            XDG_CACHE_HOME=str(tmp / "cache"),
        )

        def checked(cmd):
            p = run(cmd, env)
            assert p.returncode == 0, (p.stdout[-2000:], p.stderr[-3000:])
            return p.stdout

        rt = ROOT / "tests/typed_ir"
        for width in [1, 4, 8]:
            src = tmp / "main.fpr"
            src.write_text(source(width))
            asm = tmp / "out.s"
            checked(
                [
                    ROOT / "fpr",
                    "compile",
                    "--system=bare-metal",
                    "--target=rv64",
                    src,
                    asm,
                ]
            )
            whole = asm.read_text()
            body = emitted_bodies(whole, ["fpr_fn_loop"])
            assert f"_x24worker_x2eret{width}_x2e_x24nested_x2eresult_x2emake" in body
            if width == 1:
                assert "_x24nested_x2ector_x2eCell" in body
            asm.write_text(".text\n" + body + fuel_wrapper(whole, body))
            exe = tmp / "oracle"
            checked(
                [
                    "riscv64-unknown-elf-gcc",
                    "-march=rv64imafdc_zicsr_zifencei",
                    "-mabi=lp64",
                    "-mcmodel=medany",
                    "-msmall-data-limit=0",
                    "-O2",
                    "-ffreestanding",
                    "-nostdlib",
                    "-fno-builtin",
                    f"-DPRODUCT_WIDTH={width}",
                    "-T",
                    rt / "kernel_link.ld",
                    rt / "kernel_crt.S",
                    asm,
                    rt / "product_return_oracle.c",
                    "-o",
                    exe,
                ]
            )
            out = checked(
                [
                    "qemu-system-riscv64",
                    "-machine",
                    "virt",
                    "-smp",
                    "1",
                    "-m",
                    "16M",
                    "-nographic",
                    "-bios",
                    "none",
                    "-kernel",
                    exe,
                ]
            )
            assert "2100 C-reference" in out and "PASS" in out
            print(width, out.strip())


if __name__ == "__main__":
    main()
