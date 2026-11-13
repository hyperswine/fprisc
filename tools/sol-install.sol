B = use "../sol/lib/build".
J = use "../sol/lib/json".
usage = "sol-install.sol SOURCE_ROOT [--binary FPR] [--prefix PREFIX] [--output ARCHIVE]".
options : unsafe List String -> String -> String -> String -> (String,String,String) .
options argv binary prefix output = case argv of
    [] -> (binary,prefix,output)
  | "--binary" :: value :: rest -> options rest value prefix output
  | "--prefix" :: value :: rest -> options rest binary value output
  | "--output" :: value :: rest -> options rest binary prefix value
  | _ -> error usage.
absolute path = if path == "" then "" else if Str.at path 0 == 47 then path else B.query ["pwd"] + "/" + path.
nullable path = if path == "" then "null" else J.quote path.
prepare prefix =
  versions = "{prefix}/libexec/sol";
  target = "{prefix}/bin/sol";
  _ = B.command ["mkdir","-p",versions,"{prefix}/bin"];
  _ = (if B.exists "-L" target then
    resolved = B.query ["realpath",target];
    owner = B.query ["dirname",B.query ["dirname",resolved]];
    if owner == B.query ["realpath",versions] then Unit else error "refusing to replace unmanaged {target}"
    else if B.exists "-e" target then error "refusing to replace unmanaged {target}" else Unit);
  versions.
install root binary prefix output =
  _ = (if and (prefix == "") (output == "") then error usage else Unit);
  exe = B.query ["realpath",binary];
  sol = B.setting "SOL" "";
  launcher = if sol == "" then [exe,"sol"] else [sol];
  parent = if prefix == "" then B.setting "TMPDIR" "/tmp" else prepare prefix;
  work = B.query ["mktemp","-d","{parent}/.sol-stage-XXXXXXXX"];
  argv = List.concat [launcher,["{root}/tools/sol-bundle-build.sol",root,exe,work,prefix,absolute output],launcher];
  result = Proc.runNow (ProcessSpec argv "" [] "" 0);
  _ = B.command ["rm","-rf",work];
  case result of
    Ok (ProcessResult 0 out _) -> (case Str.split 10 (Str.trim out) of
        [id,digest] -> print "\{\"bundle_id\": {J.quote id}, \"prefix\": {nullable prefix}, \"archive\": {nullable output}, \"binary_sha256\": {J.quote digest}}"
      | _ -> error "invalid bundle build output")
  | Ok (ProcessResult code _ err) -> error "bundle build exited {code}: {err}"
  | Err why -> error "{why}".
main : unsafe Unit -> Unit .
> case args Unit of root :: argv ->
    (binary,prefix,output) = options argv "{root}/fpr" "" "";
    install (absolute root) binary (absolute prefix) output
  | _ -> error usage.
