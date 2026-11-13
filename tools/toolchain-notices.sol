# Compare canonical paths before opening a notice. Keep embedded and trailing
# whitespace intact when removing realpath's final line terminator.
D = use "../sol/lib/digest".
J = use "../sol/lib/json".
F = use "toolchain-files".
verifyFile root pair =
  (name,value) = pair;
  candidate = if Str.startsWith "/" name then name else "{root}/{name}";
  path = F.canonical candidate;
  if not (Str.startsWith (if root == "/" then "/" else "{root}/") path) then error "compiler notice outside inventory: {name}" else
    if unwrap (D.sha256File path) != unwrap (J.text value) then error "compiler notice inventory mismatch: {name}" else Unit.
verifyFiles : unsafe String -> List (String,J.Json) -> Unit .
verifyFiles root files = case files of
    [] -> Unit | file :: rest -> _ = verifyFile root file; verifyFiles root rest.
verify : unsafe String -> String -> Unit .
verify directory compiler =
  root = F.canonical directory;
  manifest = unwrap (J.parse (F.readText "{root}/manifest.json"));
  actual = unwrap (J.get "compiler" manifest |>? J.text);
  if actual != compiler then error "compiler notices are for {actual}, the plan for {compiler}" else
    verifyFiles root (unwrap (J.get "notices" manifest |>? J.fields)).
main : unsafe Unit -> Unit .
> case args Unit of [directory,compiler] -> verify directory compiler | _ -> error "expected NOTICES COMPILER_ID".
