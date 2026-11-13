# Record only the Cabal plan whose exe:fpr matches the staged compiler.
B = use "../sol/lib/build".
D = use "../sol/lib/digest".
J = use "../sol/lib/json".
F = use "toolchain-files".
optional row key fallback = case J.get key row of Ok value -> value | Err _ -> fallback.
name row = unwrap (J.get "pkg-name" row |>? J.text).
isCompiler row = optional row "component-name" J.JNull == J.JStr "exe:fpr" and name row == "fp-risc".
absent reason = J.JObj [("recorded",J.JBool False),("reason",J.JStr reason)].
digest path = unwrap (D.sha256File (F.canonical path)).
add packages row =
  info = J.JObj [("version",unwrap (J.get "pkg-version" row)),("flags",optional row "flags" (J.JObj []))];
  J.set (name row) info packages.
compilerRow : unsafe List J.Json -> List J.Json .
compilerRow rows = case rows of [] -> [] | row :: rest -> if isCompiler row then [row] else compilerRow rest.
plan : unsafe String -> String -> J.Json .
plan path binary =
  if not (B.exists "-f" path) then absent "no Cabal plan at {path}" else
    parsed = unwrap (J.parse (F.readText path));
    rows = unwrap (J.get "install-plan" parsed |>? J.items);
    mismatch = absent "{binary} is not the exe:fpr that {path} built";
    case compilerRow rows of
      [] -> mismatch
    | exe :: _ ->
        built = optional exe "bin-file" J.JNull;
        case built of
          J.JStr file -> if not (B.exists "-f" file) then mismatch else
            if digest file != digest binary then mismatch else
              included = List.filter (fn row -> name row != "fp-risc" or row == exe) rows;
              J.JObj [("recorded",J.JBool True),("compiler",unwrap (J.get "compiler-id" parsed)),
                ("sha256",J.JStr (digest path)),("packages",List.fold add (J.JObj []) included)]
        | _ -> mismatch.
main : unsafe Unit -> Unit .
> case args Unit of [path,binary] -> print (J.render (plan path binary)) | _ -> error "expected CABAL_PLAN COMPILER".
