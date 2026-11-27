#!/bin/sh
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
root=$(dirname "$here")
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
"${CC:-riscv32-esp-elf-gcc}" -march=rv32imc_zicsr -mabi=ilp32 -Os \
    -ffreestanding -nostdlib -Wall -Wextra -Werror -msmall-data-limit=0 -mno-relax \
    -I"$root" -T "$here/vectors.ld" "$here/vectors_start.S" "$here/task_vectors.c" \
    "$root/task.c" "$root/task_switch.S" "$root/os_queue.c" "$root/btdm_services.c" -o "$build/vectors.elf"
"${QEMU:-qemu-system-riscv32}" -machine virt -bios none -kernel "$build/vectors.elf" -nographic
