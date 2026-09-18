# version-compare.sol -- compare dotted numeric versions without subprocesses.
# Missing trailing components are zero, so 1.2 == 1.2.0.
#
#   ./fpr sol sol/scripts/version-compare.sol 2.10 2.9

Order = Type (Before | Same | After).

parsePart s = case Try.parseInt s of
  Ok n -> (case n >= 0 of True -> Ok n | False -> Err "negative component '{s}'")
| Err e -> Err "invalid component '{s}': {e}".

parseVersion s =
  case s == "" of
    True -> Err "version is empty"
  | False -> collect (List.map parsePart (Str.split 46 s)).

compareLeft : (xs : List Int | measure xs) -> Order .
compareLeft xs | xs == [] = Same.
compareLeft xs = x :: xr = xs; case x > 0 of True -> After | False -> compareLeft xr.

compareRight : (ys : List Int | measure ys) -> Order .
compareRight ys | ys == [] = Same.
compareRight ys = y :: yr = ys; case y > 0 of True -> Before | False -> compareRight yr.

compareParts : (xs : List Int | measure xs) -> List Int -> Order .
compareParts xs ys | xs == [] = compareRight ys.
compareParts xs ys | ys == [] = compareLeft xs.
compareParts xs ys =
  x :: xr = xs; y :: yr = ys;
  case x < y of
  True -> Before
| False -> case x > y of True -> After | False -> compareParts xr yr.

compareVersions left right =
  parseVersion left |>? (fn ls ->
    parseVersion right |> mapOk (fn rs -> compareParts ls rs)).

showOrder left right order = case order of
  Before -> "{left} < {right}"
| Same -> "{left} == {right}"
| After -> "{left} > {right}".

execute argv = case argv of
  left :: right :: [] -> case compareVersions left right of
    Ok order -> print (showOrder left right order)
  | Err message -> error "version-compare: {message}"
| _ -> error "usage: version-compare.sol VERSION VERSION".

> execute (args Unit).
