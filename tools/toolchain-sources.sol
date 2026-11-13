# Stage regular files, dereferencing file links but never traversing linked
# subdirectories. The version store also carries files without source suffixes.
B = use "../sol/lib/build".
selected path =
  name = List.last (Str.split 47 path);
  Str.startsWith ".fpr/" path or List.any (fn ext -> name != ext and Str.endsWith ext name) [".fpr",".sol",".c",".h",".S"].
stage root prefix =
  sdk = "{prefix}/libexec/fprisc";
  dirs = List.filter (fn dir -> B.exists "-d" "{root}/{dir}") ["core","std","sol/lib",".fpr","runtime","machine/posix","machine/unix"];
  names = (case dirs of [] -> [] | _ ->
    argv = List.concat [["find","-H"],dirs,["(","-type","f","-o","(","-type","l","-exec","test","-f","\{}",";",")",")","-print0"]];
    ProcessResult status out err = unwrap (Proc.runNow (ProcessSpec argv root [] "" 0));
    if status == 0 then List.filter selected (List.filter (fn path -> path != "") (Str.split 0 out)) else error "listing toolchain sources failed: {err}");
  paths = "LICENSE" :: names;
  input = Str.join "" (List.map (fn p -> p + Str.fromCode 0) paths);
  env = [("COPYFILE_DISABLE","1")];
  pack = ProcessSpec ["tar","-chf","-","--null","-T","-"] root env "" 0;
  unpack = ProcessSpec ["tar","-xpf","-"] sdk env "" 0;
  _ = (case Proc.pipeline (PipelineSpec [pack,unpack] (PipeBytes (unwrap (Utf8.encode input))) PipeDiscard PipeOutputInherit 0 PipeFail) of
      Ok (PipelineResult 0 _ _ _) -> Unit | failed -> error "toolchain source staging failed: {failed}");
  _ = B.command ["mkdir","{prefix}/bin"];
  _ = List.map (fn name -> B.command ["ln","-s","../libexec/fprisc/fpr","{prefix}/bin/{name}"]) ["fpr","sol"];
  Unit.
> case args Unit of [root,prefix] -> stage root prefix | _ -> error "expected SOURCE_ROOT STAGED_PREFIX".
