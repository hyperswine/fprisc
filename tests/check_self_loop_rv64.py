#!/usr/bin/env python3
"""Execute the emitted RV64 self loop in QEMU with the independent C oracle."""
import os
import re
import shutil
import tempfile
from pathlib import Path
from check_self_loops import ROOT, fixture, run

def main():
    for tool in ("riscv64-unknown-elf-gcc", "qemu-system-riscv64"):
        if not shutil.which(tool):
            print(f"Self-loop RV64 execution SKIP: {tool} unavailable")
            return
    with tempfile.TemporaryDirectory(prefix="fpr-self-rv64-") as td:
        tmp = Path(td)
        env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT),
                   XDG_CACHE_HOME=str(tmp / "cache"), FPR_NO_INLINE="1",
                   FPR_NO_SCALAR_WORKERS="1", FPR_NO_FIELD_WORKERS="1")
        env.pop("FPR_FOREIGN", None)
        # FPR_SELF_LOOPS is a legacy-emission switch: this check names the legacy backend
        env.pop("FPR_TYPED_IR_BACKEND", None)
        source = tmp / "probe.fpr"
        source.write_text(fixture()[0])
        crt = tmp / "crt.s"
        crt.write_text("""
.section .text.entry,"ax",@progbits
.globl _start
_start:
    la sp, _stack_top
    la t0, trap
    csrw mtvec, t0
    la t0, _bss_start
    la t1, _bss_end
1:  bgeu t0, t1, 2f
    sd zero, 0(t0)
    addi t0, t0, 8
    j 1b
2:  call main
    tail oracle_finish
.balign 4
trap:
    li a0, 1
    tail oracle_finish
""")
        link = tmp / "link.ld"
        link.write_text("""
OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 8M }
SECTIONS {
 .text : { KEEP(*(.text.entry)) *(.text .text.*) } > RAM
 .rodata : { *(.rodata .rodata.*) } > RAM
 .data : { *(.data .data.*) } > RAM
 .bss (NOLOAD) : { . = ALIGN(8); _bss_start = .; *(.bss .bss.* COMMON)
                   . = ALIGN(8); _bss_end = .; } > RAM
 _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
""")
        for enabled in ("0", "1"):
            assembly = tmp / "probe.s"
            run([ROOT / "fpr", "compile", "--target=rv64", source, assembly],
                dict(env, FPR_SELF_LOOPS=enabled))
            match = re.search(r"(?ms)^\s*\.globl fpr_fn_rotate2\n.*?(?=^# wcet:)",
                              assembly.read_text())
            assert match
            selected = ".text\n" + match[0]
            assert bool(re.search(r"^\.Lself\d+:", selected, re.M)) == (enabled == "1")
            assembly.write_text(selected)
            exe = tmp / "oracle.elf"
            run(["riscv64-unknown-elf-gcc", "-march=rv64im_zicsr_zifencei",
                 "-mabi=lp64", "-mcmodel=medany", "-msmall-data-limit=0",
                 "-O2", "-ffreestanding", "-nostdlib", "-fno-builtin",
                 "-DFPR_ORACLE_RV64", "-T", link, crt, assembly,
                 ROOT / "tests/base/selfloops_oracle.c", "-o", exe], env)
            output = run(["qemu-system-riscv64", "-machine", "virt", "-smp", "1",
                          "-m", "16M", "-nographic", "-bios", "none", "-kernel", exe], env)
            assert "2100 C-reference" in output and "PASS" in output, output
            print(f"FPR_SELF_LOOPS={enabled} RV64/QEMU: " + output.strip(), flush=True)

if __name__ == "__main__":
    main()
