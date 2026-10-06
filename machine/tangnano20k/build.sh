#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
prog="${1:-tests/tangnano20k_base.fpr}"
out="${2:-$root/build/tangnano20k-base}"
freq="${FPR_CPU_MHZ:-27}"
mkdir -p "$out"
FPR_NO_F64_INLINE=1 ./fprc --system=bare-metal --profile=base --prelude=core/prelude.fpr "$prog" "$out/base.s"
softfloat="${FPR_SOFTFLOAT_ROOT:-$root/build/tangnano20k-softfloat}"
if [[ ! -f "$softfloat/build/Linux-RISCV64-GCC/softfloat.a" ]]; then
  echo "SoftFloat missing: run machine/tangnano20k/build-softfloat.sh" >&2;exit 1
fi
# The compiler's unit list contains one pathname per line; quote every one.
units=();while IFS= read -r unit;do [[ -z "$unit" ]] || units+=("$unit");done < "$out/base.s.units"
riscv64-unknown-elf-gcc -march=rv64im_zicsr_zifencei -mabi=lp64 -mcmodel=medany -Os \
 -ffreestanding -nostdlib -nostartfiles -fno-builtin -DFPR_NHARTS=1 -DFPR_BUILTIN \
 -DFPR_SIMPLE_RISC -DFPR_CPU_MHZ="$freq" -ffunction-sections -fdata-sections \
 -Wl,--gc-sections -Wl,--no-warn-rwx-segments -I runtime -I machine/builtin \
 -T machine/tangnano20k/link.ld machine/tangnano20k/crt0.S machine/tangnano20k/base.c \
 machine/tangnano20k/unsupported.c machine/builtin/heap.c runtime/runtime.c \
 runtime/bits.c runtime/vec.c runtime/sstr.c runtime/mod.c machine/virt/memshim.c \
 -I"$softfloat/source/include" machine/tangnano20k/softfloat.c \
 "$out/base.s" "${units[@]}" "$softfloat/build/Linux-RISCV64-GCC/softfloat.a" -o "$out/base.elf"
python3 tools/check_tangnano20k_isa.py "$out/base.elf"
riscv64-unknown-elf-objcopy -O binary "$out/base.elf" "$out/base.bin"
riscv64-unknown-elf-size "$out/base.elf"
