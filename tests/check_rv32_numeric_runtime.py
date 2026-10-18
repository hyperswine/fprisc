#!/usr/bin/env python3
"""Exercise RV32 numeric boxes directly in C, independently of FP lowering.

Requires the usual Tang Nano toolchain, qemu-system-riscv32 and SoftFloat:
    FPR_XLEN=32 machine/tangnano20k/build-softfloat.sh
    python3 tests/check_rv32_numeric_runtime.py
"""
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/rv32-runtime-c-probe"
SOFT = Path(os.environ.get("FPR_SOFTFLOAT_ROOT", ROOT / "build/tangnano20k-softfloat"))
LIBRARY = SOFT / "build/Linux-RISCV32-GCC/softfloat.a"


def main():
    if not LIBRARY.is_file():
        raise SystemExit("Run FPR_XLEN=32 machine/tangnano20k/build-softfloat.sh first")
    OUT.mkdir(parents=True, exist_ok=True)
    args = [
        "riscv64-unknown-elf-gcc", "-march=rv32im_zicsr_zifencei", "-mabi=ilp32",
        "-mcmodel=medany", "-Os", "-ffreestanding", "-nostdlib", "-nostartfiles",
        "-fno-builtin", "-DFPR_NHARTS=1", "-DFPR_BUILTIN", "-DFPR_SIMPLE_RISC",
        "-DFPR_TANGNANO_QEMU", "-DFPR_CPU_MHZ=27", "-DFPR_BUILTIN_HEAP_MAX_BYTES=8388608",
        "-ffunction-sections", "-fdata-sections", "-Wl,--gc-sections",
        "-Wl,--no-warn-rwx-segments", "-I", "runtime", "-I", "machine/builtin",
        "-T", "machine/tangnano20k/link.ld", "machine/tangnano20k/crt0.S",
        "machine/tangnano20k/base.c", "machine/tangnano20k/unsupported.c",
        "machine/builtin/heap.c", "runtime/runtime.c", "runtime/i32.c", "runtime/vec.c",
        "machine/virt/memshim.c", "-I" + str(SOFT / "source/include"),
        "machine/tangnano20k/softfloat.c", "tests/base/rv32numeric_runtime.c",
        str(LIBRARY), "-lgcc",
    ]
    results = []
    cases = [
        ("probe", None, 0, "RV32 numeric runtime: all ok\nFPR EXIT 0"),
        ("half-trap", "FPR_TEST_I64_HALF_TRAP", 1,
         "I64.hi/lo: unsigned half does not fit an Int; use hiWord/loWord"),
        ("float-int-trap", "FPR_TEST_FLOAT_INT_TRAP", 1,
         "float.toInt: does not fit an Int"),
        ("i32-div-trap", "FPR_TEST_I32_DIV_TRAP", 1,
         "I32: division overflow (INT32_MIN / -1)"),
        ("float-int-min-trap", "FPR_TEST_FLOAT_INT_MIN_TRAP", 1,
         "float.toInt: does not fit an Int"),
        ("float-int-nan-trap", "FPR_TEST_FLOAT_INT_NAN_TRAP", 1,
         "float.toInt: does not fit an Int"),
    ]
    for name, define, expected_code, expected in cases:
        elf = OUT / (name + ".elf")
        command = args + (["-D" + define] if define else []) + ["-o", str(elf)]
        built = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=120)
        (OUT / (name + "-build.log")).write_text(built.stdout + built.stderr)
        assert built.returncode == 0, built.stdout + built.stderr
        run = subprocess.run([
            "qemu-system-riscv32", "-machine", "virt", "-bios", "none",
            "-nographic", "-kernel", str(elf),
        ], cwd=ROOT, capture_output=True, text=True, timeout=30)
        output = run.stdout + run.stderr
        (OUT / (name + "-qemu.log")).write_text(output)
        assert run.returncode == expected_code, output
        assert expected in output, output
        assert "FPR EXIT " + str(expected_code) in output, output
        results.append({"name": name, "returncode": run.returncode, "output": output, "passed": True})
        print(name + ": PASS")
    (OUT / "results.json").write_text(json.dumps({"platform": "QEMU RV32IM", "cases": results}, indent=2) + "\n")


if __name__ == "__main__":
    main()
