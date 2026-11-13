# Controlled RV64 link recipe for a fresh static activation or a finite sequence.
F = use "toolchain-files".
J = use "../sol/lib/json".
D = use "../sol/lib/digest".
B = use "../sol/lib/build".
runtime = ["machine/builtin/heap.c","machine/builtin/arc.c","machine/virt/memshim.c"].
flags = ["-march=rv64imc_zicsr","-mabi=lp64","-mcmodel=medany","-msmall-data-limit=0","-O2","-ffreestanding","-fno-builtin",
  "-fno-stack-protector","-nostdlib","-nostartfiles","-ffunction-sections","-fdata-sections","-DFPR_BUILTIN","-DFPR_BUILTIN_ARC"].
hash path = unwrap (D.sha256File (F.canonical path)).
inventory inputs = J.JObj (List.map (fn p -> (p,J.JStr (hash p))) inputs).
runTool root argv =
  ProcessResult code out err = unwrap (Proc.runNow (ProcessSpec argv root [] "" 240000));
  if code != 0 then error "controlled build/execution failed:\n{out}{err}" else out + err.
link root out sequence =
  asm = "{out}/callback.s";
  units = if B.exists "-f" "{asm}.units" then Str.lines (F.readText "{asm}.units") else [];
  inputs = List.concat [["{out}/start.S",asm],units,["{out}/caller.c"],List.map (fn p -> "{root}/{p}") runtime];
  before = inventory inputs;
  # The sequence dispatcher must remain visible to the direct-call stack proof.
  opts = if sequence then List.append flags ["-fno-jump-tables"] else flags;
  driver = ["riscv64-unknown-elf-gcc","-ffixed-x27"];
  command = List.concat [driver,opts,["-Wl,--gc-sections","-Iruntime","-Imachine/builtin","-T","{out}/link.ld"],inputs,["-lgcc","-o","{out}/image.elf"]];
  _ = runTool root command;
  if inventory inputs != before then error "link inputs changed during admission" else
    info = List.append driver ["--version"];
    version = Str.lines (runTool root info) ! 0;
    J.JObj [("flags",J.JArr (List.map J.JStr opts)),("inputs",before),("toolchain",J.JStr version),
            ("commands",J.JArr (List.map (fn argv -> J.JArr (List.map J.JStr argv)) [command,info]))].
> case args Unit of
    [root,out,"single"] -> print (J.render (link root out False))
  | [root,out,"sequence"] -> print (J.render (link root out True))
  | _ -> error "expected ROOT BUILD_DIR single|sequence".
