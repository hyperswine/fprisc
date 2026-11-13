B = use "../../sol/lib/build".
Board = use "build-tools".
Preset = use "preset".
revision = "a0c6494cdc11865811dec815d5c0049fba9d82a8".
prepare32 source target =
  _ = B.command ["mkdir","-p",target];
  _ = B.command ["cp","{source}/Makefile","{source}/platform.h","{target}/"];
  _ = B.command ["sed","-i.bak","/^#define SOFTFLOAT_INTRINSIC_INT128 /d","{target}/platform.h"];
  B.command ["rm","-f","{target}/platform.h.bak"].
> _ = Preset.apply Unit; width = B.setting "FPR_XLEN" "64"; abi = Board.abi width;
  out = B.setting "FPR_SOFTFLOAT_ROOT" "{B.query ["pwd","-P"]}/build/tangnano20k-softfloat";
  _ = (if B.exists "-d" "{out}/.git" then Unit else B.command ["git","clone","https://github.com/ucb-bar/berkeley-softfloat-3.git",out]);
  _ = (if B.query ["git","-C",out,"rev-parse","HEAD"] == revision then Unit else B.command ["git","-C",out,"checkout","--detach",revision]);
  target = "{out}/build/Linux-RISCV{width}-GCC";
  _ = (if width == "32" then prepare32 "{out}/build/Linux-RISCV64-GCC" target else Unit);
  cc = Str.join " " (List.append ["riscv64-unknown-elf-gcc","-mcmodel=medany","-ffunction-sections","-fdata-sections","-ffreestanding","-fno-builtin"] (Board.libc Unit));
  _ = B.command ["make","-C",target,"clean"];
  B.command ["make","-C",target,"-j4","CC={cc}","MARCH=rv{width}im","MABI={abi}","MAKELIB=riscv64-unknown-elf-ar crs $@"].
