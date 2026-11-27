#!/bin/sh
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
root=$(dirname "$here")
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
if [ -n "${C3_RADIO_SYS:-}" ]; then
    python3 "$root/generate_wifi.py" "$C3_RADIO_SYS" > "$build/wifi_config.h"
    set -- -DC3_TEST_WIFI -I"$build" "$root/wifi_services.c" "$root/wifi_irq.c" "$root/coex.c" "$root/radio_phy.c" "$root/os_timer.c" "$root/alloc.c"
else
    set --
fi
"${CC:-riscv32-esp-elf-gcc}" -march=rv32imc_zicsr -mabi=ilp32 -Os \
    -ffreestanding -nostdlib -ffunction-sections -fdata-sections -Wl,--gc-sections -Wall -Wextra -Werror -msmall-data-limit=0 -mno-relax \
    -DC3_INTERRUPT_MATRIX=0x80200000u -I"$root" -T "$here/vectors.ld" "$here/vectors_start.S" "$here/task_vectors.c" \
    "$root/task.c" "$root/task_switch.S" "$root/os_queue.c" "$root/event_group.c" "$root/btdm_services.c" "$root/btdm_irq.c" "$root/../interrupt.c" \
    "$@" -lgcc -o "$build/vectors.elf"
"${QEMU:-qemu-system-riscv32}" -machine virt -bios none -kernel "$build/vectors.elf" -nographic
