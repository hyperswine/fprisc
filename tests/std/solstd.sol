# the SAME std modules, from a Sol script (docs/2026-09-20-STD.md)
L = use "../../std/list".
S = use "../../std/string".
M = use "../../std/map".
Ord = use "../../std/order".
O = use "../../std/option".
J = use "../../std/json".
bump old = O.Some (1 + O.withDefault 0 old).
> print (L.sortWith Ord.int (3 :: 1 :: 2 :: Nil)).
> print (L.find (fn x -> x > 1) (3 :: 1 :: Nil)).
> print (S.split "," "a,b,,c" |> L.map S.toUpper |> S.join "-").
> print (M.entries (L.fold (fn m w -> M.update w bump m) M.strings (S.words "the cat and the dog and the bird"))).
> print (case J.parse "[1, \{\"a\": null\}]" of Ok v -> J.render v | Err e -> e).
> print (J.parse "[1,").
