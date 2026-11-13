D = use "../sol/lib/digest".
J = use "../sol/lib/json".
F = use "toolchain-files".
inventory prefix =
  names = List.filter (fn p -> List.last (Str.split 47 p) != "toolchain.json") (F.files prefix);
  J.JObj (List.map (fn p -> (p,J.JStr (unwrap (D.sha256File "{prefix}/{p}")))) names).
> case args Unit of [prefix] -> print (J.render (inventory prefix)) | _ -> error "expected TOOLCHAIN_PREFIX".
