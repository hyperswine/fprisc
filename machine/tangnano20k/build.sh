#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
source "$root/machine/tangnano20k/preset.sh"
prog="${1:-tests/tangnano20k_base.fpr}"
out="${2:-$root/build/tangnano20k-base}"
freq="${FPR_CPU_MHZ:-27}"
rvc="${FPR_RVC:-0}"
xlen="${FPR_XLEN:-64}"
case "$xlen" in 32) abi=ilp32; support=(-lgcc);; 64) abi=lp64; support=();; *) echo 'FPR_XLEN must be 32 or 64' >&2;exit 1;; esac
if [[ "$xlen" == 32 && $# == 0 ]];then prog=tests/tangnano20k_rv32_host.fpr;fi
case "$rvc" in 0) march=rv${xlen}im_zicsr_zifencei;; 1) march=rv${xlen}imc_zicsr_zifencei;; *) echo 'FPR_RVC must be 0 or 1' >&2;exit 1;; esac
uart=()
diagnostics=()
# The conservative collector (FPR_GC) is gone: the heap reclaims by regions the
# compiler places (docs/2026-10-25-REGIONS-LOOPS-CALLS.md).  Refused by name, so
# an old command line says why instead of building something else.
if [[ "${FPR_GC:-0}" != 0 || -n "${FPR_GC_STRESS:-}" ]];then
  echo 'FPR_GC was removed: the Base heap reclaims by compiler-placed regions (docs/2026-10-25-REGIONS-LOOPS-CALLS.md)' >&2;exit 1
fi
case "${FPR_HEAP_REPORT:-0}" in 0) ;; 1) diagnostics=(-DFPR_HEAP_REPORT -DFPR_BUILTIN_HEAP_STATS);; *) echo 'FPR_HEAP_REPORT must be 0 or 1' >&2;exit 1;; esac
case "${FPR_QEMU:-0}" in 0) ;; 1) uart=(-DFPR_TANGNANO_QEMU);; *) echo 'FPR_QEMU must be 0 or 1' >&2;exit 1;; esac
mkdir -p "$out"
# A failed rebuild must not leave a previous successful manifest behind.
rm -f "$out/build-manifest.json"
FPR_NO_F64_INLINE=1 ./fprc --system=bare-metal --profile=base --target="rv$xlen" --prelude=core/prelude.fpr "$prog" "$out/base.s"
softfloat="${FPR_SOFTFLOAT_ROOT:-$root/build/tangnano20k-softfloat}"
library="$softfloat/build/Linux-RISCV$xlen-GCC/softfloat.a"
if [[ ! -f "$library" ]]; then
  echo "SoftFloat missing: run FPR_XLEN=$xlen machine/tangnano20k/build-softfloat.sh" >&2;exit 1
fi
# The compiler's unit list contains one pathname per line; quote every one.
units=();while IFS= read -r unit;do [[ -z "$unit" ]] || units+=("$unit");done < "$out/base.s.units"
# a bare toolchain whose libc is picolibc (Debian) keeps its C headers behind
# the specs file; a newlib toolchain answers the bare name and needs nothing
specs="$(riscv64-unknown-elf-gcc -print-file-name=picolibc.specs)"
libc=()
if [[ "$specs" == /* && -f "$specs" ]]; then libc=(--specs=picolibc.specs); fi
riscv64-unknown-elf-gcc -march="$march" -mabi="$abi" -mcmodel=medany -Os ${libc[@]+"${libc[@]}"} \
 -ffreestanding -nostdlib -nostartfiles -fno-builtin -DFPR_NHARTS=1 -DFPR_BUILTIN ${uart[@]+"${uart[@]}"} ${diagnostics[@]+"${diagnostics[@]}"} \
 -DFPR_SIMPLE_RISC -DFPR_CPU_MHZ="$freq" -DFPR_BUILTIN_HEAP_MAX_BYTES=8388608 -ffunction-sections -fdata-sections \
 -Wl,--gc-sections -Wl,--no-warn-rwx-segments -I runtime -I machine/builtin \
 -T machine/tangnano20k/link.ld machine/tangnano20k/crt0.S machine/tangnano20k/base.c \
 machine/tangnano20k/sd_hal.c \
 machine/tangnano20k/unsupported.c machine/builtin/heap.c runtime/runtime.c \
 machine/builtin/unsafe.c machine/builtin/tangnano20k/machine.c \
 runtime/i32.c runtime/bits.c runtime/vec.c runtime/sstr.c runtime/mod.c machine/virt/memshim.c \
 -I"$softfloat/source/include" machine/tangnano20k/softfloat.c \
 "$out/base.s" ${units[@]+"${units[@]}"} "$library" ${support[@]+"${support[@]}"} -o "$out/base.elf"
if [[ "$rvc" == 1 ]];then
 python3 tools/check_tangnano20k_isa.py "$out/base.elf" --compressed --xlen "$xlen"
else
 python3 tools/check_tangnano20k_isa.py "$out/base.elf" --xlen "$xlen"
fi
riscv64-unknown-elf-objcopy -O binary "$out/base.elf" "$out/base.bin"
riscv64-unknown-elf-size "$out/base.elf"
python3 tools/tangnano_artifact.py "$prog" "$out" "$xlen" "$rvc" "$freq"
