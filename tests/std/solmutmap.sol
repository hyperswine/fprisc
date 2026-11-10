# std/mutmap from a Sol script: the sketch tier's engine (Sol.MutMap) runs the
# same module, with the native 64-bit hashes and slot order
MM = use "../../std/mutmap".
Ord = use "../../std/order".
M = use "../../std/map".
L = use "../../std/list".
S = use "../../std/string".
O = use "../../std/option".
count ws = L.fold (fn m w -> MM.insertWith (fn a b -> a + b) w 1 m) (MM.strings Unit) ws.
key i = (i * 7919) - ((i * 7919) / 97) * 97.
bump o = case o of O.Some c -> O.Some (c + 1) | O.None -> O.Some 1.
mstep p i = case p of (mm, ref) -> (case i - (i / 3) * 3 of
    0 -> (MM.insert (key i) i mm, M.insert (key i) i ref)
  | 1 -> (MM.alter (key i) bump mm, M.alter (key i) bump ref)
  | _ -> (MM.remove (key (i / 2)) mm, M.remove (key (i / 2)) ref)).
agree n = case L.fold mstep (MM.ints Unit, M.ints) (L.range 0 n) of (mm, ref) -> M.entries (MM.freeze Ord.int mm) == M.entries ref.
> print (M.entries (MM.freeze Ord.string (count (S.words "the cat and the dog and the bird")))).
> print (strHash "hello").
> print (intHash 42).
> print (case MM.toList (MM.insert 3 30 (MM.insert 1 10 (MM.insert 2 20 (MM.ints Unit)))) of (es, m) -> (case MM.free m of _ -> es)).
> print (agree 3000).
