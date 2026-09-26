#!/bin/sh
# build.sh PROG.fpr [BUILD_DIR] -- an ESP-IDF image of one FP-RISC program.
#   FP-RISC -> rv32 assembly (fprc --system=posix --host=esp-idf), then ESP-IDF builds it
#   with the runtime and this machine layer (project/, an IDF project).
# Needs ESP-IDF 5.3: env.sh is sourced when IDF_PATH is not set (as run.sh
# does), or source it, or ESP-IDF's own export.sh, first.  FPR_ESP_DEBUG=1 adds the boot markers, the
# per-second hart watch and the failed-allocation report; FPR_ESP_STACK_GUARD=1
# the watchpoint on each running actor's stack bottom (hal.c: it costs speed).
# Flash:  idf.py -C machine/esp-idf/project -B BUILD_DIR/idf -DSDKCONFIG=BUILD_DIR/sdkconfig -p PORT flash
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
PROG=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
[ -n "$IDF_PATH" ] || . "$HERE/env.sh"
OUT=${2:-$ROOT/build/esp-idf}
mkdir -p "$OUT/gen"
OUT=$(cd "$OUT" && pwd) # absolute: CMake resolves FPR_GEN_DIR from its own directory
rm -f "$OUT/gen"/*.s
( cd "$ROOT" && LC_ALL=C.UTF-8 ./fprc --system=posix --host=esp-idf --prelude=core/prelude.fpr "$PROG" "$OUT/gen/prog.s" > "$OUT/compile.log" 2>&1 ) \
  || { tail -20 "$OUT/compile.log"; exit 1; }
for u in $(cat "$OUT/gen/prog.s.units"); do cp "$u" "$OUT/gen/"; done
export FPR_GEN_DIR="$OUT/gen"
# esp_hosted's Kconfig compares $(ESP_IDF_VERSION), which ESP-IDF defines only
# from 5.4 on; on 5.3 it comes from here
export ESP_IDF_VERSION="${ESP_IDF_VERSION:-$(cd "$IDF_PATH" && git describe --tags 2>/dev/null | sed -E 's/^v([0-9]+\.[0-9]+).*/\1/' || echo 5.3)}"
[ -n "$ESP_IDF_VERSION" ] || ESP_IDF_VERSION=5.3
idf.py -C "$HERE/project" -B "$OUT/idf" -DSDKCONFIG="$OUT/sdkconfig" -DFPR_ESP_DEBUG="${FPR_ESP_DEBUG:-0}" -DFPR_ESP_IO_SMOKE="${FPR_ESP_IO_SMOKE:-0}" -DFPR_ESP_STACK_GUARD="${FPR_ESP_STACK_GUARD:-0}" build
