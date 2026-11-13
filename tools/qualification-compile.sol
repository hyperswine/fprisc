# Build one fixture in the qualification driver's sanitized FPR environment.
Symbols = use "qualification-symbols".
compile env root source exe cross driver probe hal =
  target = (if cross == "cross" then ["--target=linux-aarch64"] else []);
  compiler = (if probe == "probe" then ["--cc",driver,"--cflag","-DFPR_SCHED_PROBE"] else if cross == "cross" then ["--cc",driver] else []);
  units = (if hal == "" then [] else ["--with",hal]);
  argv = ["{root}/fpr","build",source,"--harts","4","-o",exe] + target + compiler + units;
  ProcessResult status out err = unwrap (Proc.runNow (ProcessSpec argv root env "" 0));
  if status == 0 then Unit else error "{source}: compiler exited {status}: {out}{err}".
verifyPiImage exe =
  ProcessResult status out err = unwrap (Proc.runNow (ProcessSpec ["od","-An","-v","-tu1","-N20",exe] "" [] "" 0));
  bytes = List.concat (List.map Str.words (Str.lines out));
  if status != 0 then error "reading {exe}: {err}" else
    if List.len bytes == 20 and List.take 6 bytes == ["127","69","76","70","2","1"] and List.drop 18 bytes == ["183","0"]
    then Unit else error "{exe}: expected a little-endian AArch64 ELF64 image".
buildChecked env root source exe cross driver probe hal pi expectations =
  _ = compile env root source exe cross driver probe hal;
  _ = (if pi then verifyPiImage exe else Unit);
  names = Symbols.inspect (if cross == "cross" then "llvm-nm" else "nm") exe probe;
  _ = (case expectations of [] -> Unit | [family,shape,mode] -> Symbols.verifyWorkers exe family shape (mode == "enabled") names
       | _ -> error "invalid worker expectations");
  names.
