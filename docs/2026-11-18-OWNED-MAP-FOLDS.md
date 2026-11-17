# Owned map folds, and MutMaps that cross regions in place (18 November)

The application workloads' remaining gap to C was profiled on 18 November
(Apple M4, standard inputs, best of five): csv 7.7x, wordfreq 7.8x, treemap
5.5x, sim 3.4x, records 2.3x. In csv and wordfreq about two thirds of the
samples were std/map's AVL walk and `g_strCompare`: an ordered map keyed by
strings, built one element at a time, against C's hash table. This note
covers the first fix taken up: building such a map in std/mutmap's hash table
and turning it into the ordered Map once, at the end.

## The rewrite (`compiler/Frontend/OwnedMapFold.hs`)

    counts = List.fold (fn m w -> Map.update w bump m) Map.strings ws

becomes

    counts = MutMap.freeze Order.string
               (List.fold (fn m w -> MutMap.update w bump m) (MutMap.strings Unit) ws)

on the root's surface tree, before modules are loaded. The conditions:

- the fold is `List.fold` (std/list, or the prelude's when nothing is named
  List), `String.foldLines` or `String.foldWords`, and its start is
  `Map.strings` or `Map.ints` (the key kinds MutMap hashes);
- the step is a two-parameter lambda, or a top-level function with one clause
  and a signature `Map.Map k v -> a -> Map.Map k v` (a twin `NAME__ownedmap`
  is generated with the MutMap type; the original stays for its other uses);
  a step name a local binding shadows is not the top-level one;
- in the step's body the map is only threaded: on every path it is the result
  itself, or the last argument of a fully applied `Map.update`, `insert`,
  `insertWith`, `remove` or `alter` whose other arguments do not mention it.
  Case scrutinees and block statements do not mention it. A step that reads
  the map (`Map.get`, `Map.size`) is left alone.

The rewritten program is type and linearity checked like any other. MutMap is
linear, so a step that let the map escape would be refused there; the
conditions above are what keep that from happening.

**What changes, observably:** nothing in Map's contract. The entries are the
same and every traversal is in key order. The tree's shape differs (a
balanced build from sorted pairs instead of the insertion order's), which
std/map already documents: `==` compares trees and `Map.equal` compares
entries.

`FPR_NO_OWNED_MAP_FOLD=1` turns the rewrite off (`cgOwnedMapFold`). It is not
applied to the sol profile, builtin, or `--lib` units, and only the root file
is rewritten today, not imported modules.

## The memory it exposed, and the runtime fix

The first build was 2x faster on wordfreq, but its peak memory went from 232
to 422 MB and csv's from 144 to 537 MB (over its 240 MB ceiling). The ordered
map's loop had run inside a loop region (`$worker.mapown.region`) that resets
each iteration's temporaries; a fold over a MutMap had none, because the
region value model (`Core/Region/Types.hs`) refused every linear type. Letting
a MutMap be a region's state, as a Vector already is, brought csv back to
135 MB but left wordfreq at 417 MB.

Reproduced alone: an `update` fold over 2M steps used 251 MB with 1,000
distinct keys, the same as `insertWith`, but 440 MB with 50,000 keys against
`insertWith`'s 253 MB. A loop region copies its state out when its arena
fills. A Vector crosses by its handle only when every column is raw words
(`vec_movable_here`); a MutMap's keys and values are boxed, so the whole table
was copied at every cycle, and once that copy outgrew the region it stopped
reclaiming. Each `update` step's two 32-byte cells (the probe pair from
`g_mutmapSlot` and the step's own) then stayed.

The fix, in `runtime/runtime.c` (`map_inplace`):

- A MutMap whose table is in the actor's base pool (vec.c always allocates it
  there) crosses a region boundary **in place**: its header and columns stay,
  and only its boxed keys and values are copied, by the region's own rules (a
  cell another pool owns stays shared), each copy written back into its slot.
  The map is linear, so its one holder is the state being copied and writing
  the slots is the move. This applies at the region copy (`dc_size_in`,
  `dc_dup`) and at a region's close (`kp_reaches`, `kp_dup`); the release
  after the close leaves such a map alone. Messages and every other copy are
  unchanged: a map in an ownerless slab is copied whole as before.
- A flag on the map, `MM_EPH` (bit 8 of `var`, above the rep), says whether
  it may hold an element the base pool does not own. Every store sets it when
  the key or value is such a cell (`fpr_mutmap_note`, vec.c); a crossing that
  leaves every element in the base pool clears it. A map without the flag
  crosses with no walk at all, so a counting map whose keys come from an
  input list built before the loop costs nothing per cycle.

Copying stored values up into the base pool at every store was tried first
and rejected: the base pool never frees cells, so a value later replaced
would stay for the life of the actor, and a long-running actor's MutMap of
boxed values would grow without bound. With the in-place copy, replaced
values die with the region that made them: 8M steps of tuple values replaced
in a 50,000-key table use the same 189 MB as 2M steps, and 1,000 keys stay at
5 MB.

The cost that remains: a map flagged `MM_EPH` (keys or values made inside the
loop) is walked at every cycle, O(slots), and its region-made elements are
copied again each time. For csv's 1,000-key table that is small. A large table
whose boxed values change every step pays it in full; a log of the slots
written since the last crossing would bound the walk by the writes instead.

## Results

Apple M4, standard inputs, best of five; outputs identical to `expected/`.

| workload | before | after | C |
|---|---|---|---|
| wordfreq | 0.320 s, 232 MB | 0.136 s, 240 MB | 0.044 s |
| csv | 0.170 s, 144 MB | 0.128 s, 133 MB | 0.023 s |
| treemap (`_mutmap` variant) | 0.144 s, 160 MB | 0.140 s, 117 MB | 0.053 s |

wordfreq goes from 7.3x C to 3.1x. csv's remaining time is `String.split`
(the list of substrings and its reversal) and integer parsing, not the map.
The csv and treemap-mutmap RSS ceilings are lowered to 200 and 180 MB.

`tests/std/ownedmapfold.fpr` prints the same with the rewrite on and off: a
named step, a lambda, every threading operation on Int keys, `foldWords`, a
step that reads the map and a seeded start (both left alone), the frozen map
used afterwards, a shadowed step name, and 300,000 steps with keys made in
the loop and tuple values replaced, which cycles the region many times.
