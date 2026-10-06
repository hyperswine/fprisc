#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="${FPR_SOFTFLOAT_ROOT:-$root/build/tangnano20k-softfloat}"
revision=a0c6494cdc11865811dec815d5c0049fba9d82a8
if [[ ! -d "$out/.git" ]];then
 git clone https://github.com/ucb-bar/berkeley-softfloat-3.git "$out"
fi
if [[ "$(git -C "$out" rev-parse HEAD)" != "$revision" ]];then
 git -C "$out" checkout --detach "$revision"
fi
make -C "$out/build/Linux-RISCV64-GCC" clean
make -C "$out/build/Linux-RISCV64-GCC" -j4 \
 'CC=riscv64-unknown-elf-gcc -mcmodel=medany -ffunction-sections -fdata-sections -ffreestanding -fno-builtin'  \
 MARCH=rv64im MABI=lp64 'MAKELIB=riscv64-unknown-elf-ar crs $@'
