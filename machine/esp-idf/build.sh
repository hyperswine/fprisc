#!/bin/sh
# Keep caller-relative paths and ESP-IDF's sourced toolchain environment.
set -e
root=$(cd "$(dirname "$0")/../.." && pwd)
prog=$(cd "$(dirname "${1:?usage: build.sh PROG.fpr [BUILD_DIR]}")" && pwd)/$(basename "$1")
out=${2:-$root/build/esp-idf}
mkdir -p "$out"
out=$(cd "$out" && pwd)
[ -n "${IDF_PATH:-}" ] || . "$root/machine/esp-idf/env.sh"
cd "$root"
exec "${SOL:-sol}" machine/esp-idf/build.sol "$prog" "$out"
