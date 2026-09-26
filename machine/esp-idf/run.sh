#!/bin/sh
# run.sh PROG.fpr [PORT] -- build, flash, and be the program's console
# (`fpr run --host=esp-idf` comes here; console.py says what that means).
#   PORT: the board's serial port; else $FPR_ESP_PORT; else the one USB serial
#   device attached (refused if there are none or several).
#   FPR_ESP_OUT: the build directory (default build/esp-idf/<program>).
#   -v / FPR_ESP_VERBOSE=1: the build's and ESP-IDF's own output too.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
PROG=$1
[ -n "$PROG" ] || { echo "usage: run.sh PROG.fpr [PORT]" >&2; exit 2; }
[ -n "$IDF_PATH" ] || . "$HERE/env.sh"
OUT=${FPR_ESP_OUT:-$ROOT/build/esp-idf/$(basename "$PROG" .fpr)}
mkdir -p "$OUT"
if [ "$FPR_ESP_VERBOSE" = 1 ]; then
  sh "$HERE/build.sh" "$PROG" "$OUT"
else
  sh "$HERE/build.sh" "$PROG" "$OUT" > "$OUT/build.log" 2>&1 \
    || { grep -aE "error|Error|FAILED" "$OUT/build.log" | tail -20 >&2; echo "fpr run: the build failed ($OUT/build.log)" >&2; exit 1; }
fi
PORT=${2:-$FPR_ESP_PORT}
if [ -z "$PORT" ]; then
  set -- $(ls /dev/cu.usbmodem* /dev/cu.usbserial* /dev/ttyACM* /dev/ttyUSB* 2>/dev/null)
  [ $# -eq 1 ] || { echo "fpr run: say which serial port the board is on (--port or FPR_ESP_PORT); found: ${*:-none}" >&2; exit 1; }
  PORT=$1
fi
( cd "$OUT/idf" && python -m esptool --chip esp32p4 -p "$PORT" -b 460800 --before default_reset --after hard_reset write_flash "@flash_args" ) \
  > "$OUT/flash.log" 2>&1 || { tail -5 "$OUT/flash.log" >&2; echo "fpr run: flashing failed ($OUT/flash.log)" >&2; exit 1; }
exec python "$HERE/console.py" "$PORT"
