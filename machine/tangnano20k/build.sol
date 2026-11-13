B = use "../../sol/lib/build".
Board = use "build-tools".
Preset = use "preset".
ISA = use "isa".
Artifact = use "artifact".
switch key yes = case B.setting key "0" of
  "0" -> [] | "1" -> yes | _ -> error "{key} must be 0 or 1".
inputs width argv =
  defaultProg = if width == "32" then "tests/tangnano20k_rv32_host.fpr" else "tests/tangnano20k_base.fpr";
  defaultOut = "{B.query ["pwd","-P"]}/build/tangnano20k-base";
  case argv of [] -> (defaultProg,defaultOut)
  | [prog] -> (prog,defaultOut) | [prog,out] -> (prog,out)
  | _ -> error "usage: build.sh [PROGRAM [OUT]]".
sources = ["machine/tangnano20k/crt0.S","machine/tangnano20k/base.c","machine/tangnano20k/sd_hal.c",
  "machine/tangnano20k/unsupported.c","machine/builtin/heap.c","runtime/runtime.c","machine/builtin/unsafe.c",
  "machine/builtin/tangnano20k/machine.c","runtime/i32.c","runtime/bits.c","runtime/vec.c","runtime/sstr.c",
  "runtime/mod.c","machine/virt/memshim.c"].
main : unsafe Unit -> Unit .
> _ = Preset.apply Unit; width = B.setting "FPR_XLEN" "64"; abi = Board.abi width;
  (prog,out) = inputs width (args Unit); clock = B.setting "FPR_CPU_MHZ" "27";
  compressed = switch "FPR_RVC" ["--compressed"]; rvc = if compressed == [] then "0" else "1";
  isa = if rvc == "0" then "im" else "imc";
  _ = (if or (B.setting "FPR_GC" "0" != "0") (B.setting "FPR_GC_STRESS" "" != "") then error "FPR_GC was removed: the Base heap reclaims by compiler-placed regions" else Unit);
  uart = switch "FPR_QEMU" ["-DFPR_TANGNANO_QEMU"]; diagnostic = switch "FPR_HEAP_REPORT" ["-DFPR_HEAP_REPORT","-DFPR_BUILTIN_HEAP_STATS"];
  _ = B.command ["mkdir","-p",out]; _ = B.command ["rm","-f","{out}/build-manifest.json"];
  assembly = "{out}/base.s"; elf = "{out}/base.elf";
  _ = B.runWith [("FPR_NO_F64_INLINE","1")] ["./fprc","--system=bare-metal","--profile=base","--target=rv{width}","--prelude=core/prelude.fpr",prog,assembly];
  soft = B.setting "FPR_SOFTFLOAT_ROOT" "{B.query ["pwd","-P"]}/build/tangnano20k-softfloat";
  archive = "{soft}/build/Linux-RISCV{width}-GCC/softfloat.a";
  _ = (if B.exists "-f" archive then Unit else error "SoftFloat missing: run FPR_XLEN={width} machine/tangnano20k/build-softfloat.sh");
  units = List.filter (fn p -> p != "") (Str.lines (readPath "{assembly}.units"));
  support = if width == "32" then ["-lgcc"] else [];
  _ = B.command (List.concat [["riscv64-unknown-elf-gcc","-march=rv{width}{isa}_zicsr_zifencei","-mabi={abi}","-mcmodel=medany","-ffixed-x27","-Os"],Board.libc Unit,
    ["-ffreestanding","-nostdlib","-nostartfiles","-fno-builtin","-DFPR_NHARTS=1","-DFPR_BUILTIN"],uart,diagnostic,
    ["-DFPR_SIMPLE_RISC","-DFPR_CPU_MHZ={clock}","-DFPR_BUILTIN_HEAP_MAX_BYTES=8388608","-ffunction-sections","-fdata-sections",
     "-Wl,--gc-sections","-Wl,--no-warn-rwx-segments","-I","runtime","-I","machine/builtin","-T","machine/tangnano20k/link.ld"],
    sources,["-I{soft}/source/include","machine/tangnano20k/softfloat.c",assembly],units,[archive],support,["-o",elf]]);
  _ = ISA.check elf width (rvc == "1");
  _ = B.command ["riscv64-unknown-elf-objcopy","-O","binary",elf,"{out}/base.bin"];
  _ = B.command ["riscv64-unknown-elf-size",elf];
  Artifact.manifest (B.query ["pwd","-P"]) prog out width rvc clock soft.
