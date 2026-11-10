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
# std/fixedmap: the same table with an entry limit (Sol.MutMap's fm*); a new
# key into a full map answers None and leaves the map as it was
FM = use "../../std/fixedmap".
fins p kv = case p of (rs, fm) -> (case kv of (k, v) -> (case FM.insert k v fm of (r, fm2) -> (r :: rs, fm2))).
fixedRun u = case L.fold fins (Nil, FM.ints 3) ((1, 10) :: (2, 20) :: (3, 30) :: (4, 40) :: (2, 22) :: Nil) of
  (rs, fm) -> (case FM.remove 1 fm of fm2 -> (case FM.insert 4 40 fm2 of (r, fm3) -> (L.reverse (r :: rs), M.entries (FM.freeze Ord.int fm3)))).
fstep lim p i = case p of (bad, fm, ref) -> (case FM.insert (key i) i fm of (r, fm2) ->
    ok = M.member (key i) ref or M.size ref < lim;
    want = if ok then O.Some Unit else O.None;
    (if r == want then bad else bad + 1, (if i - (i / 5) * 5 == 0 then FM.remove (key (i / 2)) fm2 else fm2), (if ok then (if i - (i / 5) * 5 == 0 then M.remove (key (i / 2)) (M.insert (key i) i ref) else M.insert (key i) i ref) else (if i - (i / 5) * 5 == 0 then M.remove (key (i / 2)) ref else ref)))).
fagree n = case L.fold (fstep 40) (0, FM.ints 40, M.ints) (L.range 0 n) of (bad, fm, ref) -> bad == 0 and M.entries (FM.freeze Ord.int fm) == M.entries ref.
> print (fixedRun Unit).
> print (fagree 3000).
