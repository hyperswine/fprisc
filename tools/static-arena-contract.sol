F = use "toolchain-files".
J = use "../sol/lib/json".
D = use "../sol/lib/digest".
sources = ["machine/builtin/heap.c","machine/builtin/arc.c","machine/virt/memshim.c","machine/builtin/builtin.h","machine/builtin/uniform.inc","machine/builtin/uniform-aggregate.inc","runtime/fpr.h",
  "compiler/Codegen/Heap.hs","compiler/Codegen/Calling.hs","compiler/Codegen/Calling/Types.hs","compiler/Codegen/Export/Plan.hs",
  "compiler/Codegen/Target/RV/Export.hs","compiler/Codegen/Target/RV.hs","compiler/Codegen/Target/RV/ScalarAdapters.hs"].
fieldsEqual obj names =
  actual = List.map (fn p -> (name,_) = p; name) (unwrap (J.fields obj));
  List.len actual == List.len names and List.all (fn key -> List.has key actual) names.
verify : unsafe String -> String -> J.Json .
verify root path =
  contract = unwrap (J.parse (F.readText path));
  if not (fieldsEqual contract ["schema","description","sources_sha256"]) then error "invalid audited heap contract fields" else
    if unwrap (J.get "schema" contract) != J.JStr "builtin-rv64-c-heap-v1" then error "unsupported audited heap contract" else
      hashes = unwrap (J.get "sources_sha256" contract);
      if not (fieldsEqual hashes sources) then error "audited heap contract does not cover its complete policy/runtime dependencies" else
        _ = List.map (fn name ->
          expected = unwrap (J.get name hashes |>? J.text);
          if Str.len expected != 64 or not (List.all (fn c -> Str.find c "0123456789abcdef" >= 0) (Str.codes expected)) then error "invalid audited source hash: {name}"
          else if unwrap (D.sha256File (F.canonical "{root}/{name}")) != expected then error "audited runtime/heap contract changed: {name}" else Unit) sources;
        contract.
main : unsafe Unit -> Unit .
> case args Unit of [root,path] -> print (J.render (verify root path)) | _ -> error "expected ROOT CONTRACT".
