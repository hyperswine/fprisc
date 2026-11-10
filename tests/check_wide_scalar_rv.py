#!/usr/bin/env python3
"""Execute emitted public and private wide scalar entries with hostile fuel resets."""

import argparse
import os
import re
import shutil
import tempfile
from pathlib import Path
from check_wide_scalar_workers import fixture, WIDTHS
from check_product_returns import ROOT, run
from fuel_wrapper import fuel_wrapper


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--require-execution", action="store_true")
    args = parser.parse_args()
    missing = [
        name
        for name in ("riscv64-unknown-elf-gcc", "qemu-system-riscv64")
        if not shutil.which(name)
    ]
    if missing:
        if args.require_execution:
            raise SystemExit(f"Missing {missing}")
        print("Wide scalar RV64 execution skipped:", missing)
        return
    with tempfile.TemporaryDirectory(prefix="fpr-wide-rv64-") as tmp:
        tmp = Path(tmp)
        env = {k: v for k, v in os.environ.items() if not k.startswith("FPR_")}
        env.update(
            FPR_HOME=str(ROOT),
            FPR_PATH=str(ROOT),
            FPR_NO_INLINE="1",
            XDG_CACHE_HOME=str(tmp / "cache"),
        )

        def checked(cmd):
            p = run(cmd, env)
            assert p.returncode == 0, (p.returncode, p.stdout[-2000:], p.stderr[-2000:])
            return p.stdout

        src = tmp / "wide.fpr"
        src.write_text(fixture())
        asm = tmp / "wide.s"
        checked(
            [ROOT / "fpr", "compile", "--target=rv64", "--system=bare-metal", src, asm]
        )
        whole = asm.read_text()
        parts = []
        for w in WIDTHS:
            for name in [f"start{w}", f"wide{w}", f"_x24worker_x2escalar_x2ewide{w}"]:
                symbol = "fpr_fn_" + name
                body = re.search(rf"(?ms)^{symbol}:\n.*?(?=^# native-insns-v1:)", whole)
                assert body, symbol
                parts.append(".globl " + symbol + "\n" + body[0])
        text = "\n".join(parts)
        asm.write_text(".text\n" + text + fuel_wrapper(whole, text))
        exe = tmp / "oracle"
        rt = ROOT / "tests/typed_ir"
        checked(
            [
                "riscv64-unknown-elf-gcc",
                '-ffixed-x27',
                "-march=rv64imafdc_zicsr_zifencei",
                "-mabi=lp64",
                "-mcmodel=medany",
                "-msmall-data-limit=0",
                "-O2",
                "-ffreestanding",
                "-nostdlib",
                "-fno-builtin",
                "-T",
                rt / "kernel_link.ld",
                rt / "kernel_crt.S",
                asm,
                rt / "wide_scalar_oracle.c",
                "-o",
                exe,
            ]
        )
        output = checked(
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
        assert "3591 wide scalar answers and fuel clobbers PASS" in output, output
        print(output.strip())


if __name__ == "__main__":
    main()
