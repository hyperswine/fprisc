# Read only fresh-aligned RV64 budget proofs for the selected exports.
J = use "../sol/lib/json".
F = use "toolchain-files".
invalid = "missing/ambiguous fresh compiler heap proof".
readDigits : unsafe List Int -> Int -> Int .
readDigits digits value = case digits of
    [] -> value
  | c :: rest -> if c >= 48 and c <= 57 then readDigits rest (value * 10 + c - 48) else error invalid.
decimal : unsafe String -> String -> Int .
decimal key token =
  prefix = key + "=";
  digits = Str.slice token (Str.len prefix) (Str.len token);
  if Str.startsWith prefix token and digits != ""
  then readDigits (Str.codes digits) 0 else error invalid.
proof : unsafe List String -> Int -> String -> (String,J.Json) .
proof lines heap symbol =
  prefix = "# native-heap-budget-v1: " + symbol + " ";
  case List.filter (Str.startsWith prefix) lines of
    [line] -> (case Str.split 32 (Str.slice line (Str.len prefix) (Str.len line)) of
      [count,requested,arena,limit,"scope=fresh-aligned-builtin-rv64-c-heap"] ->
        calls = decimal "requests" count; bytes = decimal "requested" requested;
        bound = decimal "arena" arena; selected = decimal "limit" limit;
        if selected != (if heap == 0 then 1 else heap) or bound > heap then error "heap proof differs from selected arena"
        else (symbol,J.JObj [("requests",J.JNum calls),("requested_bytes",J.JNum bytes),("required_arena_bytes",J.JNum bound)])
    | _ -> error invalid)
  | _ -> error invalid.
main : unsafe Unit -> Unit .
> case args Unit of _ :: path :: size :: symbols ->
    lines = Str.lines (F.readText path);
    print (J.render (J.JObj (List.map (proof lines (parseInt size)) symbols)))
  | _ -> error "expected ROOT ASSEMBLY HEAP_BYTES EXPORT...".
