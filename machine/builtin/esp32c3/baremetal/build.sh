#!/bin/sh
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
root=${FPRISC_ROOT:-$(cd "$here/../../../.." && pwd)}
build=${1:-build/c3-baremetal}
example=${2:-selfcheck}
case "$example" in
    selfcheck) source="$root/machine/builtin/esp32c3/examples/selfcheck.fpr" ;;
    journal|journal-cut) source="$root/machine/builtin/esp32c3/examples/journal.fpr" ;;
    endurance) source="$root/machine/builtin/esp32c3/examples/endurance.fpr" ;;
    button) source="$here/button.fpr" ;;
    *) echo "Expected selfcheck, button, journal, journal-cut, or endurance" >&2; exit 2 ;;
esac
mode=${3:-ram}
case "$mode" in
    ram) output="$example" ;;
    flash) output="$example-flash" ;;
    *) echo "Expected ram or flash" >&2; exit 2 ;;
esac
case "$example:$mode" in
    journal:ram|journal-cut:ram|endurance:ram)
        echo "Journal applications require flash boot to initialize SPI." >&2
        exit 2 ;;
esac
cc=${CC:-riscv32-esp-elf-gcc}
mkdir -p "$build"
cd "$build"
cmake "-Dfpr=$root/fpr" "-Dsource=$source" \
    "-Dcc=$cc" "-Dguest=$PWD/guest.o" -P "$root/machine/builtin/esp32c3/main/compile.cmake"
compile() {
    source_file=$1
    object_file=$2
    shift 2
    "$cc" -march=rv32imc_zicsr -mabi=ilp32 -Os -ffreestanding -ffunction-sections \
        -fdata-sections -ffixed-x27 -msmall-data-limit=0 -mno-relax \
        -DFPR_BUILTIN -DFPR_NHARTS=1 -I"$root/runtime" -I"$root/machine/builtin" \
        "$@" -c "$source_file" -o "$object_file"
}
set --
if [ "$mode" = flash ]; then
    compile "$here/flash_boot.c" flash_boot.o "-DC3_EXAMPLE=\"$example\""
    set -- -DC3_FLASH_BOOT "-DC3_EXAMPLE=\"$example\"" -DFPR_BUILTIN_HEAP_STATS
fi
compile "$here/start.S" start.o "$@"
compile "$here/console.c" console.o "$@"
set --
if [ "$mode" = flash ]; then
    set -- flash_boot.o
fi
case "$example" in
journal|journal-cut|endurance)
    if [ "$example" = journal-cut ]; then
        compile "$here/flash.c" flash.o -DC3_TEST_CUT
    else
        compile "$here/flash.c" flash.o
    fi
    compile "$here/file_unavailable.c" file_unavailable.o
    compile "$here/../main/log.c" log.o
    compile "$here/../main/flash_log.c" flash_log.o -DFPR_C3_BAREMETAL -DFPR_RAW_JOURNAL
    compile "$root/machine/virt/memshim.c" memshim.o
    set -- "$@" flash.o file_unavailable.o log.o flash_log.o memshim.o -T "$here/flash_rom.ld" ;;
esac
compile "$here/gpio.c" gpio.o
compile "$here/clock.c" clock.o
compile "$here/interrupt.c" interrupt.o
compile "$here/../main/memory.c" memory.o
compile "$root/machine/builtin/unsafe.c" unsafe.o
compile "$root/runtime/runtime.c" runtime.o
compile "$root/runtime/i32.c" i32.o
compile "$root/machine/builtin/heap.c" heap.o -DFPR_BUILTIN_HEAP_STATS
"$cc" -march=rv32imc -mabi=ilp32 -nostdlib -T "$here/ram.ld" \
    -Wl,--gc-sections,--no-relax,-Map="$output.map" \
    start.o console.o gpio.o clock.o interrupt.o memory.o unsafe.o runtime.o i32.o heap.o guest.o "$@" -lgcc -o "$output.elf"
"${ESPTOOL:-esptool.py}" --chip esp32c3 elf2image -o "$output.bin" "$output.elf"
