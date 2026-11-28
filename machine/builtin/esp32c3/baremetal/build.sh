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
    wifi) source="$here/radio/wifi.fpr" ;;
    wifi-sta|coex) source="$here/radio/wifi_sta.fpr" ;;
    ble)
        source=${4:-$here/../examples/ble.fpr}
        source="$(cd "$(dirname -- "$source")" && pwd)/$(basename -- "$source")" ;;
    button) source="$here/button.fpr" ;;
    *) echo "Expected selfcheck, button, journal, journal-cut, endurance, ble, wifi, wifi-sta, or coex" >&2; exit 2 ;;
esac
mode=${3:-ram}
case "$mode" in
    ram) output="$example" ;;
    flash) output="$example-flash" ;;
    *) echo "Expected ram or flash" >&2; exit 2 ;;
esac
case "$example:$mode" in
    journal:ram|journal-cut:ram|endurance:ram|ble:ram|wifi:ram|wifi-sta:ram|coex:ram)
        echo "The selected application requires flash boot." >&2
        exit 2 ;;
esac
if [ "$example" = ble ] || [ "$example" = wifi ] || [ "$example" = wifi-sta ] || [ "$example" = coex ]; then
    radio_package=$(cd "${C3_RADIO_SYS:?Set C3_RADIO_SYS to the pinned esp-wifi-sys checkout}" && pwd)
    radio_reference=$(cd "${C3_RADIO_REF:?Set C3_RADIO_REF to the pinned esp-hal checkout}" && pwd)
fi
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
link_layout="$here/ram.ld"
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
    compile "$here/flash_region.c" flash_region.o
    compile "$here/file_unavailable.c" file_unavailable.o
    compile "$here/../main/log.c" log.o
    compile "$here/../main/flash_log.c" flash_log.o -DFPR_C3_BAREMETAL -DFPR_RAW_JOURNAL
    set -- "$@" flash.o flash_region.o file_unavailable.o log.o flash_log.o -T "$here/flash_rom.ld" ;;
ble)
    link_layout="$here/radio/ble.ld"
    python3 "$here/radio/generate_bt.py" "$radio_package" "$radio_reference" > ble_config.h
    printf '#define C3_PHY_INIT_DATA_IMPLEMENTATION\n#include "ble_config.h"\n' > phy_data.c
    compile "$PWD/phy_data.c" phy_data.o
    for src in ble ble_hw radio_phy alloc lib_support hci task os_queue task_clock btdm_services btdm_irq
    do
        compile "$here/radio/$src.c" "$src.o" -I"$PWD"
        set -- "$@" "$src.o"
    done
    compile "$here/radio/task_switch.S" task_switch.o
    set -- "$@" phy_data.o task_switch.o -T ble_rom.ld -Wl,--start-group
    for library in btdm_app btbb phy coexist printf; do
        set -- "$@" "$radio_package/esp-wifi-sys-esp32c3/libs/lib$library.a"
    done
    set -- "$@" -lm -lc -Wl,--end-group ;;
wifi|wifi-sta|coex)
    link_layout="$here/radio/wifi.ld"
    python3 "$here/radio/generate_bt.py" "$radio_package" "$radio_reference" > ble_config.h
    printf '#define C3_PHY_INIT_DATA_IMPLEMENTATION\n#include "ble_config.h"\n' > phy_data.c
    compile "$PWD/phy_data.c" phy_data.o
    python3 "$here/radio/generate_ftm.py" "$radio_reference" > wifi_ftm.c
    compile "$PWD/wifi_ftm.c" wifi_ftm.o
    python3 "$here/radio/generate_wifi.py" "$radio_package" > wifi_config.h
    for src in wifi_hw radio_phy wifi_single wifi_services wifi_irq wifi_lib station_lib lib_support task os_queue task_clock btdm_services event_group os_timer
    do
        compile "$here/radio/$src.c" "$src.o" -I"$PWD" -DC3_RADIO_QUEUE_BYTES=2048
        set -- "$@" "$src.o"
    done
    if [ "$example" != wifi ]; then
        for src in net_probe wifi_probe station_config; do
            compile "$here/radio/$src.c" "$src.o" -I"$PWD"
            set -- "$@" "$src.o"
        done
        if [ "$example" = coex ]; then
            for src in ble ble_hw hci btdm_irq coex; do
                compile "$here/radio/$src.c" "$src.o" -I"$PWD" -DC3_COEX
                set -- "$@" "$src.o"
            done
            compile "$here/radio/wifi.c" wifi.o -I"$PWD" -DC3_WIFI_STATION -DC3_COEX
        else
            compile "$here/radio/wifi.c" wifi.o -I"$PWD" -DC3_WIFI_STATION
        fi
    else
        compile "$here/radio/wifi.c" wifi.o -I"$PWD"
    fi
    set -- "$@" wifi.o
    compile "$here/radio/alloc.c" alloc.o -DC3_RADIO_ARENA_BYTES=65536
    compile "$here/radio/task_switch.S" task_switch.o
    set -- "$@" alloc.o phy_data.o wifi_ftm.o task_switch.o -T ble_rom.ld -Wl,--start-group
    for library in core espnow mesh net80211 pp wpa_supplicant phy coexist printf regulatory; do
        set -- "$@" "$radio_package/esp-wifi-sys-esp32c3/libs/lib$library.a"
    done
    if [ "$example" = coex ]; then
        for library in btdm_app btbb; do
            set -- "$@" "$radio_package/esp-wifi-sys-esp32c3/libs/lib$library.a"
        done
    fi
    set -- "$@" -lm -lc -lnosys -Wl,--end-group ;;
esac
compile "$here/gpio.c" gpio.o
compile "$here/clock.c" clock.o
compile "$here/interrupt.c" interrupt.o
compile "$here/../main/memory.c" memory.o
compile "$root/machine/builtin/unsafe.c" unsafe.o
compile "$root/runtime/runtime.c" runtime.o
compile "$root/runtime/i32.c" i32.o
compile "$root/machine/builtin/heap.c" heap.o -DFPR_BUILTIN_HEAP_STATS
compile "$root/machine/virt/memshim.c" memshim.o
"$cc" -march=rv32imc -mabi=ilp32 -nostdlib -T "$link_layout" \
    -Wl,--gc-sections,--no-relax,-Map="$output.map" \
    start.o console.o gpio.o clock.o interrupt.o memory.o unsafe.o runtime.o i32.o heap.o memshim.o guest.o "$@" -lgcc -o "$output.elf"
set --
if [ "$example" = wifi ] || [ "$example" = wifi-sta ] || [ "$example" = ble ] || [ "$example" = coex ]; then
    set -- --flash_mode dio --flash_size 4MB
fi
"${ESPTOOL:-esptool.py}" --chip esp32c3 elf2image "$@" -o "$output.bin" "$output.elf"
