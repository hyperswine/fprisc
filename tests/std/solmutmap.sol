MM = use "../../std/mutmap".
Ord = use "../../std/order".
M = use "../../std/map".
L = use "../../std/list".
S = use "../../std/string".
O = use "../../std/option".
count ws = L.fold (fn m w -> MM.insertWith (fn a b -> a + b) w 1 m) (MM.strings Unit) ws.
> print (M.entries (MM.freeze Ord.string (count (S.words "the cat and the dog and the bird")))).
> print (strHash "hello").
> print (intHash 42).
> print (case MM.toList (MM.insert 3 30 (MM.insert 1 10 (MM.insert 2 20 (MM.ints Unit)))) of (es, m) -> (case MM.free m of _ -> es)).
