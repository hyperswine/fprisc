#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
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
gc=()
case "${FPR_GC:-0}" in 0) ;; 1) gc=(-DFPR_BUILTIN_GC machine/tangnano20k/gc_registers.S machine/tangnano20k/gc_roots.c);; *) echo 'FPR_GC must be 0 or 1' >&2;exit 1;; esac
case "${FPR_HEAP_REPORT:-0}" in 0) ;; 1) diagnostics=(-DFPR_HEAP_REPORT -DFPR_BUILTIN_HEAP_STATS);; *) echo 'FPR_HEAP_REPORT must be 0 or 1' >&2;exit 1;; esac
if [[ -n "${FPR_GC_STRESS:-}" ]];then
  if [[ "${FPR_GC:-0}" != 1 || ! "$FPR_GC_STRESS" =~ ^[1-9][0-9]{0,5}$ ]];then
    echo 'FPR_GC_STRESS needs FPR_GC=1 and an interval in 1..999999' >&2;exit 1
  fi
  gc+=(-DFPR_BUILTIN_GC_STRESS="$FPR_GC_STRESS")
fi
case "${FPR_QEMU:-0}" in 0) ;; 1) uart=(-DFPR_TANGNANO_QEMU);; *) echo 'FPR_QEMU must be 0 or 1' >&2;exit 1;; esac
mkdir -p "$out"
FPR_NO_F64_INLINE=1 ./fprc --system=bare-metal --profile=base --target="rv$xlen" --prelude=core/prelude.fpr "$prog" "$out/base.s"
softfloat="${FPR_SOFTFLOAT_ROOT:-$root/build/tangnano20k-softfloat}"
library="$softfloat/build/Linux-RISCV$xlen-GCC/softfloat.a"
if [[ ! -f "$library" ]]; then
  echo "SoftFloat missing: run FPR_XLEN=$xlen machine/tangnano20k/build-softfloat.sh" >&2;exit 1
fi
# The compiler's unit list contains one pathname per line; quote every one.
units=();while IFS= read -r unit;do [[ -z "$unit" ]] || units+=("$unit");done < "$out/base.s.units"
riscv64-unknown-elf-gcc -march="$march" -mabi="$abi" -mcmodel=medany -Os \
 -ffreestanding -nostdlib -nostartfiles -fno-builtin -DFPR_NHARTS=1 -DFPR_BUILTIN ${uart[@]+"${uart[@]}"} ${diagnostics[@]+"${diagnostics[@]}"} ${gc[@]+"${gc[@]}"} \
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
