#!/bin/sh
# Use the generated settings from a file-enabled IDF 5.3.2 C3 build.
set -eu
config=${1:?usage: check_spiffs_power.sh PATH/TO/BUILD}
shift
test -f "$config/config/sdkconfig.h"
src="$IDF_PATH/components/spiffs"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
: > "$tmp/esp_log.h"
echo '#define ESP_STATIC_ASSERT _Static_assert' > "$tmp/esp_assert.h"
"${CC:-cc}" -std=c11 -O2 -I"$tmp" -I"$config/config" -I"$src/include" \
    -I"$src/spiffs/src" "$(dirname "$0")/spiffs_power.c" "$src"/spiffs/src/*.c \
    -lz -o "$tmp/check"
"$tmp/check" "$@"
