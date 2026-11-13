# A persistent hash map, maps in place when linear, and comparators called directly

Date: 14 November 2026. Kind: implementation record. It follows the review
of the gap to C on 14 November: map lookups cost a comparator call per node,
through the generic apply, and String keys are compared at every node.

## Summary

Three changes on branch `hashmap`:

- **`strCompare`.** The prelude's `strCmp`, and so `Order.string` and every
  String-keyed map and sort, now uses a runtime primitive (`memcmp` over the
  shorter length, then the lengths). The answers are the same as the old byte loop's.
- **`std/hashmap`.** A persistent hash map: std/map's AVL tree with the key's hash in the key
  slot. Lookups compare Ints and compare the keys once, where the hashes match.
  - **In place when linear.** It shares std/map's names and shapes, so the owned-map rewriting rebuilds it in
    place exactly where it rebuilds a Map. No mutable API is exposed for it.
  - **Order.** Iteration is in hash order, which is deterministic. `toMap cmp` gives the ordered Map.
- **Direct comparators.** An owned map's tree walk calls its comparator as a direct function call
  instead of a generic application. This applies when every empty map the unit names carries one known
  comparator.

Measured on an Apple M4, as medians of 5 interleaved runs. C and the peers are rebuilt from
`tests/bench/apps`, and the inputs come from the archived `gen.py`:

| App | `main` (4a596d04) | std/map now | std/hashmap variant | C | best vs C |
|---|---|---|---|---|---|
| csv | 0.51 s | 0.45 s | 0.43 s | 0.020 s | 21.5x |
| wordfreq | 0.61 s | 0.45 s | 0.37 s | 0.040 s | 9.2x |
| treemap | 0.38 s | 0.36 s | 0.62 s | 0.050 s | 7.2x |
| format | 0.14 s | 0.14 s | | 0.160 s | 0.9x |
| records | 0.31 s | 0.31 s | | 0.090 s | 3.4x |
| sim | 0.16 s | 0.16 s | | 0.020 s | 8.0x |

The geometric mean against C goes from 6.44x to 5.94x with std/map, and to 5.71x
taking the faster map for each app. Instructions: treemap 4.65 -> 3.84 G, wordfreq 11.70 ->
6.84 G (std/map) and 5.58 G (std/hashmap), csv 12.38 -> 10.33 G.

## strCompare

`runtime.c g_strCompare`, registered like `strJoin` (Infer.hs, `FPR_FN`).
`core/prelude.fpr strCmp a b = strCompare a b`. `strCmpGo` stays as the same
answer in FP-RISC. On a grid of strings (empty, prefixes, high bytes) the
result equals the old loop's. On its own it took wordfreq from 11.70 to 9.13 G and
csv from 12.38 to 11.18 G.

## std/hashmap

```
HK k = Type (HK Int k).
Tree k v = Type (Leaf | Node Int (Tree k v) (HK k) v (Tree k v)).
Ops k = Type (Ops (k -> Int) (k -> k -> Ord.Ordering)).
Map k v = Type (Map (Ops k) Int (Tree k v)).
```

- **Ordering and ties.** Nodes are ordered by hash, then by the map's comparator. The comparator runs only on equal
  hashes, which in practice means the same key.
- **The empty maps.** `strings` uses `strHash` and `Order.string`; `ints` uses `intHash` and `Order.int`;
  `empty hash cmp` takes any pair.
- **The API.** It mirrors std/map: `get`, `getOr`, `member`, `insert`, `remove`,
  `alter`/`update`, `insertWith`, `fold`, `entries`, `keys`, `values`, `map`, `filter`,
  `union`, `equal` and `fromList`, plus `toMap`. `toMap` sorts once and builds the
  ordered map in O(n) with `fromDistinctAscList`. The type is named `Map`, as std/map's
  is, so switching an app over is a one-line change.

### In place when linear

The owned-map rewriting (Reuse.hs) recognises std/map by its definitions:
`insGo`, `balance`, `node`, the rotations, `Leaf`, a three-field `Map`, and the
`strings`/`ints`/`empty` roots. std/hashmap has all of them, so it is recognised
as well. A HashMap threaded through a loop from an empty map, with nothing else
holding it, is rebuilt in place: the wrapper, the path, balance and rotations, as for Map.

The pass needed one fix. An owned twin enters with a copy of the empty map's wrapper, and that copy assumed a
single `Map` constructor in scope. With both modules present there are two, so it now takes the constructor
of the module the empty map comes from.

The user-facing result is the request "maps mutable when linear": no MutMap-style API is
needed for HashMap. std/mutmap stays as it is for code that wants a flat table.

### What it does not reach

wordfreq on std/mutmap runs in 0.21 s; on std/hashmap, 0.37 s. A persistent tree, even one
rebuilt in place, is O(log n) node visits per update with balance bookkeeping, while a
linear table is one probe. Closing that would mean an owned HashMap taking a
table representation for the length of its loop. That is a representation change, not
a rewriting one, so it is not attempted here.

treemap needs its keys in order (its checksum is ordered), so the hash-map variant
sorts at the end, and std/map remains the right map for it.

## Direct comparators

A walker twin (`$worker.mapown.walk.*`) runs only on an owned map. An owned map's
comparator is the one of the empty map it started from, because the twins rebuild
the wrapper with its own field. So:

- **The comparator set.** The pass collects the comparators of every empty map the unit names (`strings@`,
  `ints@` and `empty@` of either module). The bodies come from the linked program, and
  `tgtMapBodies` now carries those roots. Names are followed through the body's lets to a
  global.
- **The substitution.** If the set is exactly one known global, the walker's comparator parameter is that function:
  the parameter applied to two arguments and handed on unchanged to the walker's own saturated calls. Its
  calls become direct calls.
- **The fallback.** A unit that also names an empty map with an unknown comparator (`Map.empty cmp`)
  keeps the generic call. The set is collected apart from the plans, which depend on the walkers.

`codegenRev` is 223.

## Checks

On `main` the Python check suite is gone, so these were run by hand:

- **std golden tests.** All 44 `tests/std` programs were run with this branch and with `main`. 38 match their
  `.expected` output. The other six (supervisor, posix, kvwire, http, durable, apps) also
  differ on `main`: they needed arguments or environment from the deleted runner. Five print the same on both
  compilers, and http differs only by a timestamp.
- **New golden test.** `tests/std/hashmap` checks every operation against std/map: 100,000 inserts and
  removals, 100,000 alters, forced hash ties (a hash of `k % 3`), and versions kept while a
  loop updates in place.
- **Legacy checks.** The checks from just before the cutover were copied in temporarily: persistent reclamation,
  reuse, consuming reuse, state generations, digest vectors and local products. All pass, as does the native `ReuseCheck` suite.
- **Apps.** All app outputs match `expected/`, including the three hash-map variants.

## Next

- **Items 4-6 from the review.** `Option`/`Result` results returned in registers (`toInt`, `get`); sim's fixed costs;
  substring views, the copy-out walks and call-region bookkeeping.
- **A table representation for owned hash maps,** the remaining gap to MutMap.
- **A test runner.** The std golden tests need one again (Sol, or native).
