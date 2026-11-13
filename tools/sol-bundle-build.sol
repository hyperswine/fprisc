# Build identity and metadata from the staged bytes, including the staged runner.
B = use "../sol/lib/build".
check argv = case Proc.streamNow (ProcessSpec argv "" [] "" 0) of Ok 0 -> True | _ -> False.
publish tool work id prefix output =
  staged = "{work}/{id}";
  _ = (if output == "" then Unit else B.command (tool "archive" [work,id,output]));
  if prefix == "" then Unit else
    versions = "{prefix}/libexec/sol";
    final = "{versions}/{id}";
    # Move into the versions parent. A concurrent install of the same ID
    # can win the rename, in which case validate the winner before use.
    moved = if B.exists "-e" final then False else check ["mv",staged,versions];
    _ = (if moved then Unit else
      if not (check (tool "stage" ["verify",final,staged])) then error "existing bundle is corrupt: {final}" else
      if not (check (tool "hashes" ["verify",final,"{work}/paths","{work}/digests"])) then error "existing bundle is corrupt: {final}" else Unit);
    B.command (tool "activate" ["{prefix}/bin",id]).
build root binary work prefix output launcher =
  bundle = "{work}/bundle";
  paths = "{work}/paths";
  digests = "{work}/digests";
  tool name argv = List.append launcher ("{root}/tools/sol-bundle-{name}.sol" :: argv);
  _ = B.command (tool "snapshot" [root,paths]);
  _ = B.command (tool "stage" [root,binary,bundle,paths]);
  ProcessResult status out err = unwrap (Proc.runNow (ProcessSpec ["{bundle}/fpr","sol","--version"] "" [] "" 30000));
  version = Str.trim out;
  _ = (if status != 0 then error "runner version check failed: {err}" else
    if version != "Sol 0.14.0-dev (scripting API 1)" then error "unexpected runner version {version}" else Unit);
  hash = ProcessSpec (tool "hashes" [bundle,paths]) "" [] "" 0;
  _ = (case Proc.pipeline (PipelineSpec [hash] (PipeBytes (Bytes.empty Unit)) (PipePublish digests False) PipeOutputInherit 0 PipeFail) of
      Ok (PipelineResult 0 _ _ _) -> Unit
    | failed -> error "hashing bundle failed: {failed}");
  result = B.query (tool "identity" [bundle,version,B.query ["uname","-s"],B.query ["uname","-m"],paths,digests]);
  case Str.split 10 result of
    [id,digest] -> _ = B.command ["mv",bundle,"{work}/{id}"]; _ = publish tool work id prefix output; print result
  | _ -> error "invalid bundle identity result".
> case args Unit of root :: binary :: work :: prefix :: output :: launcher -> build root binary work prefix output launcher
  | _ -> error "expected ROOT BINARY WORK_DIRECTORY PREFIX OUTPUT SOL_COMMAND".
