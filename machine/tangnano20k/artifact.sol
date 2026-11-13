B = use "../../sol/lib/build".
F = use "../../tools/toolchain-files".
D = use "../../sol/lib/digest".
J = use "../../sol/lib/json".
hash path = unwrap (D.sha256File (F.canonical path)).
unavailable detail =
  why = Str.trim detail;
  J.JObj [("revision",J.JNull),("diff_sha256",J.JNull),("error",J.JStr (Str.slice why (Numeric.max 0 (Str.len why - 400)) (Str.len why)))].
repository root =
  result = Proc.runNow (ProcessSpec ["git","rev-parse","HEAD"] root [] "" 0);
  case result of
    Err why -> unavailable "{why}"
  | Ok (ProcessResult code rev err) -> if code != 0 then unavailable (err + rev) else
      work = tempDir "tang-diff";
      path = "{work}/diff";
      diff = ProcessSpec ["git","diff","HEAD"] root [] "" 0;
      case Proc.pipeline (PipelineSpec [diff] (PipeBytes (Bytes.empty Unit)) (PipeFileNew path) (PipeCapture 65536) 0 PipeFail) of
        Ok (PipelineResult 0 _ _ _) -> J.JObj [("revision",J.JStr (Str.trim rev)),("diff_sha256",J.JStr (hash path))]
      | Ok (PipelineResult status _ _ errors) -> unavailable (case Utf8.decode (Bytes.concat errors) of Ok s -> s | _ -> "git diff exited {status}")
      | Err why -> unavailable "{why}".
manifest root program out width rvc mhz soft =
  units = List.filter (fn p -> p != "") (Str.lines (F.readText "{out}/base.s.units"));
  source = F.canonical program;
  gcc = Str.lines (B.query ["riscv64-unknown-elf-gcc","-ffixed-x27","--version"]) ! 0;
  preset = case unwrap (Env.get "FPR_PRESET") of EnvMissing -> J.JNull | EnvText name -> J.JStr name;
  config = J.JObj [("xlen",J.JNum (parseInt width)),("compressed",J.JBool (rvc == "1")),("cpu_mhz",J.JNum (parseInt mhz)),
    ("reclamation",J.JStr "regions"),("qemu",J.JBool (B.setting "FPR_QEMU" "0" == "1"))];
  artifacts = J.JObj (List.map (fn name -> (name,J.JStr (hash "{out}/{name}"))) ["base.s","base.elf","base.bin"]);
  sources = List.fold (fn obj path -> J.set (F.canonical path) (J.JStr (hash path)) obj) (J.JObj []) units;
  record = J.JObj [("preset",preset),("repository",repository root),("program",J.JObj [("path",J.JStr source),("sha256",J.JStr (hash source))]),
    ("compiler_sha256",J.JStr (hash "{root}/fpr")),("gcc",J.JStr gcc),("configuration",config),("artifacts",artifacts),("units",sources),
    ("softfloat_sha256",J.JStr (hash "{soft}/build/Linux-RISCV{width}-GCC/softfloat.a"))];
  writePath "{out}/build-manifest.json" (J.pretty record + "\n").
> case args Unit of ["repository",root] -> print (J.render (repository root))
  | [root,source,out,width,rvc,mhz,soft] -> manifest root source out width rvc mhz soft
  | _ -> error "expected ROOT SOURCE OUTPUT XLEN RVC CPU_MHZ SOFTFLOAT_ROOT or repository ROOT".
