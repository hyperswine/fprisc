#!/bin/sh
# Cross-build examples/pos1.fpr for Graviton (Linux AArch64) from this Mac.
# Needs the patched fpr (--target=linux-aarch64) and Homebrew's
# aarch64-unknown-linux-gnu toolchain (glibc 2.28 sysroot: runs on AL2023).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out="$here/out"; mkdir -p "$out"
cd "$root"
./fpr build examples/pos1.fpr --target=linux-aarch64 --cc "${CROSS_CC:-aarch64-linux-gnu-gcc}" \
  --harts "${HARTS:-2}" -o "$out/pos1"
file "$out/pos1"
