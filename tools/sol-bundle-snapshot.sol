# Preserve the order recorded by the installer when rebuilding from an archive.
B = use "../sol/lib/build".
J = use "../sol/lib/json".
snapshotNames : unsafe List J.Json -> List String -> List String .
snapshotNames entries acc = case entries of
    [] -> List.rev acc
  | entry :: rest -> snapshotNames rest ((unwrap (J.text entry) + Str.fromCode 0) :: acc).
checkout root destination =
  git = ProcessSpec ["git","ls-files","-z","--cached","--others","--exclude-standard"] root [] "" 0;
  sort = ProcessSpec ["sort","-zu"] root [("LC_ALL","C")] "" 0;
  must result = case result of Ok value -> value | Err why -> error "{why}";
  PipelineResult status codes bytes _ = must (Proc.pipeline (PipelineSpec [git,sort] (PipeBytes (Bytes.empty Unit)) (PipeCapture 16777216) PipeOutputInherit 0 PipeFail));
  if status != 0 then error "listing source files failed: {codes}" else
    paths = Str.split 0 (unwrap (Utf8.decode bytes));
    files = List.filter (fn path -> if path == "" then False else B.exists "-f" "{root}/{path}") paths;
    writePath destination (Str.join "" (List.map (fn path -> path + Str.fromCode 0) files)).
main : unsafe Unit -> Unit .
> case args Unit of [root,destination] ->
    manifest = "{root}/bundle-source.json";
    if B.exists "-f" manifest then
      value = unwrap (J.parse (readPath manifest) |>? J.get "files");
      case value of
        J.JArr entries ->
          names = snapshotNames entries [];
          writePath destination (Str.join "" names)
      | _ -> error "bundle-source.json files must be an array"
    else checkout root destination
  | _ -> error "usage: sol-bundle-snapshot.sol SOURCE_ROOT PATHS".
