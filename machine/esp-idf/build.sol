# Run from the FP-RISC checkout with the ESP-IDF vendor environment configured.
B = use "../../sol/lib/build".
idfVersion dir = ProcessResult status tag _ = unwrap (Proc.runNow (ProcessSpec ["git","describe","--tags"] dir [] "" 0));
  case (status,Str.split 46 (Str.trim tag)) of
    (0,major :: minor :: _) -> if Str.startsWith "v" major then "{substr major 1 (Str.len major)}.{minor}" else Str.trim tag
  | _ -> "5.3".
compileFailure out code = _ = B.command ["tail","-20","{out}/compile.log"]; error "ESP compiler exited {code}".
compile prog out =
  # Redirect both descriptors to the same log, including output on failure.
  argv = ["sh","-c","log=$1; shift; exec \"$@\" >\"$log\" 2>&1","fpr-compile","{out}/compile.log",
          "./fprc","--system=posix","--host=esp-idf","--prelude=core/prelude.fpr",prog,"{out}/gen/prog.s"];
  code = unwrap (Proc.streamNow (ProcessSpec argv "" [("LC_ALL","C.UTF-8")] "" 0));
  if code == 0 then Unit else compileFailure out code.
build prog out =
  root = B.query ["pwd","-P"]; gen = "{out}/gen";
  _ = B.command ["mkdir","-p",gen];
  stale = List.filter (Str.endsWith ".s") (ls gen);
  _ = List.map (fn name -> B.command ["rm","-f","{gen}/{name}"]) stale;
  _ = compile prog out;
  units = List.filter (fn path -> path != "") (Str.lines (readPath "{gen}/prog.s.units"));
  _ = List.map (fn path -> B.command ["cp",path,gen]) units;
  version = (case unwrap (Env.get "ESP_IDF_VERSION") of EnvText value -> if value != "" then value else idfVersion (B.setting "IDF_PATH" "") | EnvMissing -> idfVersion (B.setting "IDF_PATH" ""));
  B.runWith [("FPR_GEN_DIR",gen),("ESP_IDF_VERSION",version)]
    ["idf.py","-C","{root}/machine/esp-idf/project","-B","{out}/idf","-DSDKCONFIG={out}/sdkconfig",
     "-DFPR_ESP_DEBUG={B.setting "FPR_ESP_DEBUG" "0"}","-DFPR_ESP_IO_SMOKE={B.setting "FPR_ESP_IO_SMOKE" "0"}",
     "-DFPR_ESP_STACK_GUARD={B.setting "FPR_ESP_STACK_GUARD" "0"}","build"].
> case args Unit of [prog,out] -> build prog out | _ -> error "expected absolute program and build directory".
