#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="${FPR_SOFTFLOAT_ROOT:-$root/build/tangnano20k-softfloat}"
revision=a0c6494cdc11865811dec815d5c0049fba9d82a8
xlen="${FPR_XLEN:-64}"
case "$xlen" in 32) abi=ilp32;; 64) abi=lp64;; *) echo 'FPR_XLEN must be 32 or 64' >&2;exit 1;; esac
if [[ ! -d "$out/.git" ]];then
 git clone https://github.com/ucb-bar/berkeley-softfloat-3.git "$out"
fi
if [[ "$(git -C "$out" rev-parse HEAD)" != "$revision" ]];then
 git -C "$out" checkout --detach "$revision"
fi
target="$out/build/Linux-RISCV$xlen-GCC"
if [[ "$xlen" == 32 ]]; then
 # Keep the RV64 archive intact. Both builds use the pinned RISCV
 # specialization; GCC lowers the FAST_INT64 C implementation on RV32.
 mkdir -p "$target"
 cp "$out/build/Linux-RISCV64-GCC/Makefile" "$out/build/Linux-RISCV64-GCC/platform.h" "$target/"
 # GCC's RV32 backend has no __int128. SoftFloat supplies equivalent
 # portable multiword primitives when this intrinsic override is absent.
 sed -i.bak '/^#define SOFTFLOAT_INTRINSIC_INT128 /d' "$target/platform.h"
 rm -f "$target/platform.h.bak"
fi
make -C "$target" clean
make -C "$target" -j4 \
 'CC=riscv64-unknown-elf-gcc -mcmodel=medany -ffunction-sections -fdata-sections -ffreestanding -fno-builtin'  \
 MARCH="rv${xlen}im" MABI="$abi" 'MAKELIB=riscv64-unknown-elf-ar crs $@'
