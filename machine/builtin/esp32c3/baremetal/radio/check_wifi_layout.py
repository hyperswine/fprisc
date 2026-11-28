"""Compare every generated C3 Wi-Fi layout field with the pinned Rust ABI."""
import argparse
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory

from generate_wifi import Bindings, STRUCTS
from audit import verify_package


def check(package, cc, objcopy, rustc):
    verify_package(package)
    source = package / "esp-wifi-sys-esp32c3" / "src"
    bindings = Bindings((source / "include.rs").read_text())
    c_types, rust_types = [], []
    for name in STRUCTS:
        c_types += [f"sizeof({name})", f"_Alignof({name})"]
        rust_types += [f"size_of::<{name}>()", f"align_of::<{name}>()"]
        for field, _ in bindings.fields(name):
            c_types.append(f"offsetof({name}, {field})")
            rust_types.append(f"offset_of!({name}, {field})")

    with TemporaryDirectory(prefix="fpr-c3-wifi-abi-") as path:
        work = Path(path)
        generator = Path(__file__).with_name("generate_wifi.py").resolve()
        with (work / "wifi_config.h").open("w") as output:
            subprocess.run(["python3", generator, package], stdout=output, check=True)
        values = ",\n    ".join(c_types)
        (work / "layout.c").write_text(
            '#include "wifi_config.h"\n'
            '__attribute__((section(".fpr_abi"), used))\n'
            f'const uint32_t layout[] = {{\n    {values}\n}};\n'
        )
        values = ",\n    ".join(x + " as u32" for x in rust_types)
        (work / "layout.rs").write_text(
            '#![no_std]\n#![allow(warnings)]\n'
            f'#[path = "{source / "c_types.rs"}"] mod c_types;\n'
            f'#[path = "{source / "include.rs"}"] mod bindings;\n'
            'use bindings::*;\nuse core::mem::{size_of, align_of, offset_of};\n'
            '#[link_section = ".fpr_abi"]\n#[no_mangle]\n#[used]\n'
            f'pub static LAYOUT: [u32; {len(rust_types)}] = [\n    {values}\n];\n'
        )
        subprocess.run([cc, "-std=c11", "-march=rv32imc", "-mabi=ilp32", "-ffreestanding",
                        "-Wall", "-Wextra", "-Werror", "-c", work / "layout.c",
                        "-o", work / "c.o"], check=True)
        subprocess.run([rustc, "--edition=2021", "--crate-type=lib", "--emit=obj",
                        "--target=riscv32imc-unknown-none-elf", work / "layout.rs",
                        "-o", work / "rust.o"], check=True)
        observed = []
        for language in ("c", "rust"):
            blob = work / f"{language}.bin"
            subprocess.run([objcopy, "--dump-section", f".fpr_abi={blob}", work / f"{language}.o"],
                           check=True)
            observed.append(blob.read_bytes())
        if observed[0] != observed[1]:
            for i, expression in enumerate(c_types):
                c = observed[0][i*4:i*4+4]
                rust = observed[1][i*4:i*4+4]
                if c != rust:
                    raise ValueError(f"{expression}: C {int.from_bytes(c, 'little')}, "
                                     f"Rust {int.from_bytes(rust, 'little')}")
            raise ValueError("ABI section lengths differ")
    print(f"C3 Wi-Fi ABI PASS: {len(STRUCTS)} structs, {len(c_types)} RV32 layout checks")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("--prefix", default="riscv32-esp-elf-")
    parser.add_argument("--rustc", default="rustc")
    args = parser.parse_args()
    check(args.package.resolve(), args.prefix + "gcc", args.prefix + "objcopy", args.rustc)
