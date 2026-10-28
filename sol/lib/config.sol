# JSON configuration: strict keys and typed fields, with named environment
# overrides selected explicitly by the caller. Environment wins over JSON;
# an application's CLI override can be applied before these accessors.
J = use "json".
M = use "../../std/map".
readWith limits path = Try.readPath path |>? (J.parseWith limits) |> mapErr (fn why -> "config {path}: {why}").
read path = readWith (J.Limits 1048576 64 4096 65536) path.
schema allowed json = J.fields json |>? (fn entries -> keys allowed entries M.strings |>? (fn u -> Ok json)).
keys : List String -> (entries : List (String, J.Json) | measure entries) -> M.Map String Bool -> Result Unit String.
keys allowed entries seen = case entries of
  [] -> Ok Unit
| (key,value) :: rest ->
    if not (List.has key allowed) then Err "config: unknown key '{key}'"
    else if M.member key seen then Err "config: duplicate key '{key}'"
    else keys allowed rest (M.insert key True seen).
environment name = if name == "" then Ok EnvMissing else Env.get name.
string key envName json = environment envName |>? (fn source -> case source of
  EnvText text -> Ok text
| EnvMissing -> J.get key json |>? J.text) |> mapErr (fn why -> "config '{key}': {why}").
integer key envName json = environment envName |>? (fn source -> case source of
  EnvText text -> Try.parseInt text
| EnvMissing -> J.get key json |>? J.num |>? (fn n -> case Try.parseInt (str n) of Ok v -> Ok v | Err why -> Err "expected an integer"))
  |> mapErr (fn why -> "config '{key}': {why}").
integerBetween low high key envName json = integer key envName json |>? (fn n ->
  if and (n >= low) (n <= high) then Ok n else Err "config '{key}': expected {low}..{high}").
