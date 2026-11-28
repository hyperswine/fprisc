#!/bin/sh
set -eu

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
root=${FPRISC_ROOT:-$(cd "$here/../../../.." && pwd)}
build=${1:-build/p4-baremetal}
cc=${CC:-riscv32-esp-elf-gcc}
radio=$root/machine/builtin/esp32c3/baremetal/radio
source=${P4_SOURCE:-$root/machine/builtin/esp32c3/examples/selfcheck.fpr}
heap_stats=
if [ "${P4_BLE_SAMPLE:-0}" = 1 ]; then
    source=$here/ble_sample.fpr
    heap_stats=-DFPR_BUILTIN_HEAP_STATS
fi
source=$(CDPATH='' cd -- "$(dirname -- "$source")" && pwd)/$(basename -- "$source")
mkdir -p "$build"
cd "$build"

cmake "-Dfpr=$root/fpr" "-Dsource=$source" \
    "-Dcc=$cc" "-Dguest=$PWD/guest.o" -P "$root/machine/builtin/esp32c3/main/compile.cmake"

compile() {
    "$cc" -march=rv32imc_zicsr -mabi=ilp32 -Os -ffreestanding \
        -ffunction-sections -fdata-sections -ffixed-x27 -msmall-data-limit=0 -mno-relax \
        -DFPR_BUILTIN -DFPR_NHARTS=1 ${heap_stats:+$heap_stats} -I"$root/machine/builtin/esp32c3/main" -I"$radio" -I"$root/runtime" -I"$root/machine/builtin" \
        -c "$1" -o "$2"
}

compile "$here/start.S" start.o
compile "$here/console.c" console.o
compile "$here/sdio_probe.c" sdio_probe.o
compile "$here/ble.c" ble.o
compile "$radio/hci.c" hci.o
compile "$here/clock.c" clock.o
compile "$here/gpio.c" gpio.o
compile "$here/interrupt.c" interrupt.o
compile "$root/machine/builtin/esp32c3/main/memory.c" memory.o
compile "$root/machine/builtin/unsafe.c" unsafe.o
compile "$root/runtime/runtime.c" runtime.o
compile "$root/runtime/i32.c" i32.o
compile "$root/machine/builtin/heap.c" heap.o
compile "$root/machine/virt/memshim.c" memshim.o
"$cc" -march=rv32imc -mabi=ilp32 -nostdlib -T "$here/ram.ld" \
    -Wl,--gc-sections,--no-relax,-Map=selfcheck.map \
    start.o console.o sdio_probe.o ble.o hci.o clock.o gpio.o interrupt.o memory.o unsafe.o runtime.o i32.o heap.o memshim.o guest.o -lgcc -o selfcheck.elf
"${ESPTOOL:-esptool.py}" --chip esp32p4 elf2image -o selfcheck.bin selfcheck.elf
