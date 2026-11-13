# Cabal freezes the checkout's flags, while its version comes from the build.
J = use "../sol/lib/json".
F = use "toolchain-files".
empty = J.JObj [].
get obj key fallback = case J.get key obj of Ok v -> v | Err _ -> fallback.
dropPrefix n word = substr word n (Str.len word - n).
signed word = Str.startsWith "+" word or Str.startsWith "-" word.
flag flags word = J.set (dropPrefix 1 word) (J.JBool (Str.startsWith "+" word)) flags.
constraint frozen text =
  words = Str.words (Str.trim text);
  case words of
    [] -> frozen
  | pkg :: rest ->
    if Str.startsWith "any." pkg and List.len rest == 1 and Str.startsWith "==" (Str.join "" rest) then
      name = dropPrefix 4 pkg;
      J.set name (J.set "version" (J.JStr (dropPrefix 2 (Str.join "" rest))) (get frozen name empty)) frozen
    else if rest != [] and List.all signed rest then
      row = get frozen pkg empty;
      flags = List.fold flag (get row "flags" empty) rest;
      J.set pkg (J.set "flags" flags row) frozen
    else error "unexpected Cabal freeze constraint: {text}".
parseItems : unsafe J.Json -> List String -> J.Json .
parseItems frozen items = case items of [] -> frozen | text :: rest -> parseItems (constraint frozen text) rest.
parseFreeze : unsafe String -> J.Json .
parseFreeze path =
  rows = List.filter (fn line -> not (Str.startsWith "active-repositories:" line or Str.startsWith "index-state:" line)) (Str.lines (F.readText path));
  constraints = Str.replace "constraints:" " " (Str.join " " rows);
  parseItems empty (Str.split 44 constraints).
checkFlags name have item =
  (key,want) = item;
  if get have key want == want then [] else ["{name}: flag {key} disagrees with freeze"].
compareRow frozen item =
  (name,have) = item;
  want = get frozen name empty;
  version = unwrap (J.get "version" have |>? J.text);
  expected = if name == "fp-risc" then J.JStr version else get want "version" J.JNull;
  case expected of
    J.JNull -> ["{name}-{version} is in the plan but not frozen"]
  | J.JStr text -> if text != version then ["{name}: plan {version}, freeze {text}"] else
      List.concat (List.map (checkFlags name (get have "flags" empty)) (unwrap (J.fields (get want "flags" empty))))
  | _ -> error "invalid freeze version for {name}".
verify : unsafe String -> String -> Unit .
verify manifest path =
  plan = unwrap (J.parse (F.readText manifest) |>? J.path ["cabalPlan","packages"]);
  frozen = parseFreeze path;
  extra = List.concat (List.map (fn item -> (name,_) = item;
    if get plan name J.JNull == J.JNull then ["{name} is frozen but missing from plan"] else []) (unwrap (J.fields frozen)));
  drift = List.append (List.concat (List.map (compareRow frozen) (unwrap (J.fields plan)))) extra;
  if drift == [] then Unit else error "the compiler was not built from cabal.project.freeze: {Str.join "; " drift}".
main : unsafe Unit -> Unit .
> case args Unit of [manifest,path] -> verify manifest path | _ -> error "expected TOOLCHAIN_JSON FREEZE".
