# Keyed-list folds, and two smaller list rewrites (18 November)

The inventory app keeps its items in a list, and rebuilds the model by folding
the journal with the app's own step:

    replayed m ls = List.fold (fn mm l -> apply { mm | events = mm.events + 1 } l) m ls
    findItem items id = List.find (fn x -> x.id == id) items
    putItem renamed m it = case findItem m.items it.id of
        Option.None -> { m | items = it :: m.items, .. }
      | Option.Some old -> new = { it | .. };
                           { m | items = List.map (fn x -> (case x.id == it.id of True -> new | False -> x)) m.items, .. }
    applyOp m op v | strEq op "del" = { m | items = List.filter (fn it -> it.id != int "id" v) m.items }

Every journal line walks and rebuilds the list, so loading 16,001 lines is
quadratic. The hand prototype in the list-1 notes (a MutMap from id to item
while loading, the list once at the end) took the member workload from
10.17 G to 1.07 G instructions. This note covers doing that in the compiler,
for any program with the same shape, plus two rewrites found on the way.

## Rule 1: keyed-list folds (`compiler/Frontend/KeyedListFold.hs`)

On the root file's surface tree, before modules are loaded (as for owned map
folds), a `List.fold` qualifies when its list (the accumulator itself, or one
field F of a record accumulator) is read and written only by these, all with
the same key field K:

- find: `List.find (fn x -> x.K == e) L` (or `e == x.K`, or a root helper
  `eq a b = a == b`), as a case scrutinee;
- put: `y :: L`, only in the None arm of that find, with `y.K` being `e`;
- replace: `List.map (fn x -> if x.K == e then NEW else x) L`, or a root
  helper of two clauses (`h x .. | x.K == p = NEW` and `h x .. = x`), where
  NEW keeps K (`{ x | .. }`, or a record whose K is e);
- delete: `List.filter (fn x -> x.K != e) L` (or `not (x.K == e)`).

`e` must be effect-free: no Sys/print/error, no call of an unknown closure;
root functions are checked through, std modules by a list of pure ones. In the
record case, the record may only flow: field reads other than F, record
updates, and arguments of root functions that qualify themselves (not
recursive, no preconditions). Each such function gets a twin,
`NAME__keyedfoldN`, which takes the table as an extra last argument and returns
(record, table).

The rewritten step works on std/keyedlist's table: a linear `MutMap k v` from
key to element, plus the keys in the order they were put, newest first. At the
end, `toList` walks that order, emits each key at its newest place, and takes
it out of the map so an older place of a re-added key finds nothing.

**Why the order is the list's.** Keys start unique, because the start's list
must be empty. This is checked when the fold runs: otherwise the fold runs as
written. Keys stay unique, because put happens only when find said absent and
replace keeps the key. So find, replace and delete each touch the one element
with that key, and put adds it at the front, exactly what the table records.
A key deleted and put back is at the front in both.

**Which key types.** `==` is structural, but a MutMap hashes only Int and
String. The step is wrapped in a special form, `fprKeyedFold# ORIGINAL
(fn table -> REWRITTEN)`, which inference (`Infer.hs`) types as both, unifying
REWRITTEN with `MutMap k v -> T`. A resolution site `keyedfold!` on k then
picks `mutmapInts`, `mutmapStrings`, or keeps ORIGINAL for any other type.
Elaboration drops the branch not taken, and typed Core gets a `KeyedTable`
plan node. The rewritten program is type and linearity checked like any other.

**Evaluation.** The key of a find, replace or delete is evaluated once
instead of once per element. Because it is effect-free, that cannot be told
apart, except that an empty list evaluates it zero times. The `...Lazy` forms
in std/keyedlist therefore take the key as a thunk and call it only when the
table is not empty, so a key that would trap traps exactly when the fold as
written would.

`FPR_NO_KEYED_LIST_FOLD=1` turns it off.

## Rule 2: snoc folds (`compiler/Frontend/ListRewrites.hs`)

    List.fold (fn acc x -> if ok x then acc + [f x] else acc) start xs

copies the accumulator at every step. When the accumulator is only ever the
result (`acc`, `acc + [e..]`, `List.append acc [e..]`, through cases and blocks
that do not otherwise mention it), the fold conses onto a reversed list and
reverses once:

    List.append start (List.reverse (List.fold (fn acc x -> if ok x then f x :: acc else acc) Nil xs))

The append is skipped when start is `Nil` or `[]`. The elements are evaluated
in the same order. A Vector 1 builder was the other option. It was not taken
because the result must still be a List, and the element type and its linear
layout would have to be known at the rewrite, which runs before inference.
Reversal is one pass and cannot trap. `FPR_NO_SNOC_FOLD=1` turns it off.

## Not on by default: shared maps

`List.map (fn x -> if TEST then NEW else x) xs` (or the two-clause helper form,
like pos1's `markVoid`) can become `List.mapWhere TEST NEW xs`. This new std/list
function copies only up to the last element TEST picks and shares the rest;
TEST must be total and effect-free. It is correct (tests/std/keyedlistfold,
and the `shared_map` config-differential configuration), but measured slower.
On an owned list, `List.map`'s own lowering is cheap, while mapWhere makes two
passes through closure calls: pos1 batch went from 3,240,923,041 to
3,380,611,385 instructions, and a 20,000-sale void micro from 6,930,973,325 to
9,636,432,761. So it runs only with `FPR_SHARED_MAP=1`.

## Where they fire

`FPR_LIST_REWRITE_NOTES=1` prints the count and the function of each site.
Of the examples, these are the ones with sites:

| program | sites |
|---|---|
| examples/inventory.fpr (and the pre-#1 inventory app, cba3771) | keyed-list fold in `replayed` (record mode, field `items`, key `id`, Int); keyed-list fold in `renameCmd` (its start is the live model, so at run time it takes the fold as written) |
| examples/pos1.fpr | none by default (shared maps in `applyVoid` and `mapP` with FPR_SHARED_MAP=1) |
| examples/logbook.fpr | none by default (shared map in `withSess` with FPR_SHARED_MAP=1) |
| the 16 benchmarks | none |

## Measurements

Callgrind instructions, median of 3, one lane. "main" is f5a6bd9d; "branch" is
this branch with its defaults. The apps are the unmodified pre-#1 inventory
source (cba3771), built as the root file, and examples/pos1.fpr with the batch
driver appended (the rewrites apply to the root file only).

| workload | main | branch (default) | change | branch + FPR_SHARED_MAP=1 |
|---|---:|---:|---:|---:|
| inventory member (journal load + add member) | 10,176,088,448 | 1,079,339,331 | 9.4x fewer | 1,079,339,344 |
| inventory import (journal load + 300 docs) | 17,284,381,523 | 8,183,519,352 | 2.1x fewer | 8,184,764,037 |
| pos1 batch (fold x3 + 2000-sale ring with voids) | 3,240,923,041 | 3,240,947,912 | +0.00% | 3,380,611,385 |
| micro: keyed upsert/delete, Int keys | 3,270,525,881 | 40,148,655 | 81.5x fewer | 40,205,550 |
| micro: keyed upsert, String keys | 8,741,105,302 | 53,223,212 | 164.2x fewer | 53,211,161 |
| micro: snoc fold, 4000 | 296,410,831 | 656,567 | 451.5x fewer | 675,048 |
| micro: void the newest of 20000 sales x2000 | 6,930,973,325 | 6,933,492,918 | +0.04% | 9,636,432,761 |

The last column is the first commit of the branch, where shared maps were on
by default. That is where the regression was measured. Inventory member is the
hand prototype's number (1.07 G). Import keeps 8.18 G, as the prototype did:
after the load, each imported document is committed through the app's list
code, which runs outside any fold. pos1 has no keyed fold, so by default it is
unchanged. Its `replayed` folds through a wrapper,
`foldE f z l = List.fold (fn acc x -> f x acc) z l`, whose step calls an
unknown closure. The rule does not look through that, and its sales are
added without a `find`, which the rule needs to know that keys stay unique.

The 16 benchmarks: no rewrite fires, and the instruction counts are within 0.1% of main (largest: wordfreq -0.081%, records -0.049%; median of 3 each).

## Soundness, cost and checks

- WCET/fuel: the rewritten forms are ordinary code and are costed like any
  other. std/keyedlist declares the bounds that `fpr build --cost` proves:
  `empty`, and `updateIn` (the table write). The table operations are
  std/mutmap's, which carry their own contracts. `mapWhere` declares work and
  alloc. The lazy forms and `toList` declare none, like `List.map` and
  `List.fold`: their cost depends on a closure or on a map that shrinks as it
  is read. On the test program, no function that had a closed bound with the
  rewrites off loses it with them on.
- No new traps: the key and TEST are effect-free, the key is evaluated only
  when the list is not empty, and the table is a MutMap (no capacity limit).
- Safety: std/keyedlist is on the allow-list (`compiler/Safety.hs`,
  [2026-10-15-SAFETY-ALLOW-LIST-REVIEW.md](2026-10-15-SAFETY-ALLOW-LIST-REVIEW.md)).
  It has no `unsafe` functions, and its one recursion carries a measure.
  Because the compiler adds it to programs, it must never be why a safe
  program is refused.
- tests/std/keyedlistfold compares every rewritten fold with the same step run
  by plain recursion. That covers Int and String keys, record mode, 50 to 3000
  pseudo-random upserts and deletes, a non-empty start, a key type that falls
  back, and snoc folds. The config differential runs it under
  `no_list_rewrites` and `shared_map` as well as the existing configurations.

## Limits

- Root file only: a module's folds are not rewritten (as for owned map folds).
  std/list must be imported under an alias.
- The start's list must be empty when the fold runs; otherwise the fold runs
  as written, and the twins are dead code.
- Int or String keys only. For other key types the rewritten branch is
  dropped after inference, though the twins are still generated and checked.
- The helpers a record accumulator is handed to must not be recursive or carry
  preconditions. Each must take the model in one position only, and must use
  the list only through the four operations.
- The effect analysis is syntactic and assumes local variables hold data or
  effect-free closures.
- Snoc folds: only `acc + [..]` and `List.append acc [..]` with a list
  literal; an append of a computed list is left alone.
