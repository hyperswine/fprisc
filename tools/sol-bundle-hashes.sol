# Relative source paths are NUL-delimited so names can contain newlines.
D = use "../sol/lib/digest".
files bundle inventory =
  names = List.filter (fn path -> path != "") (Str.split 0 (readPath inventory));
  "{bundle}/fpr" :: List.map (fn name -> "{bundle}/source/{name}") names.
# Streams require a regular file. Resolve links only when the direct open fails.
digest path = case D.sha256File path of
    Ok hash -> hash
  | Err why ->
      ProcessResult status out _ = unwrap (Proc.runNow (ProcessSpec ["realpath",path] "" [] "" 0));
      if status != 0 then error "cannot resolve {path}: {why}" else
        resolved = Str.sub out 0 (Str.len out - 1);
        unwrap (D.sha256File resolved).
verify paths expected =
  if List.len paths != List.len expected then error "bundle digest count mismatch" else
    _ = List.map (fn pair -> (path,want) = pair;
      if digest path == want then Unit else error "bundle digest mismatch: {path}") (List.zip paths expected);
    Unit.
> case args Unit of [bundle,inventory] -> _ = List.map (fn path -> print (digest path)) (files bundle inventory); Unit
  | ["verify",bundle,inventory,reference] ->
      verify (files bundle inventory) (Str.split 10 (Str.trim (readPath reference)))
  | _ -> error "expected BUNDLE INVENTORY or verify BUNDLE INVENTORY REFERENCE".
