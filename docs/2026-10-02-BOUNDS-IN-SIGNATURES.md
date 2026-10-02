# Bounds in signatures

Date: 2026-10-02. Kind: implementation record. Stage 2 of
[2026-10-02-RESOURCE-BOUNDS.md](2026-10-02-RESOURCE-BOUNDS.md).

```
count : (n : Int | measure n) -> Int -> Int | work count <= 5 * n + 5 | alloc count <= 0 .
```

A signature may end in resource bounds, each introduced by `|` after the
result type: `work f <= e` or `alloc f <= e` (the function name may be left
out: `work <= e`). The right-hand side is built from integer literals, the
function's parameters (an `Int` parameter is its value), `len p`, `work p`
and `alloc p` of a function-valued parameter, `+`, `*` and `max`. A name
that is not a parameter is an error: coefficients are literals here, and a
target manifest will supply named ones (stage 3). The grammar is strict on
purpose: until this morning `| anything` was a dropped signature.

## What the compiler does with one

Whenever any signature in the program declares a bound (or on `--cost`), the
cost pass runs and compares the derived equation with the declaration,
coefficient by coefficient over the monomials in the parameters and sizes,
with a `max` on the derived side checked arm by arm and `⌈e/k⌉` bounded by
`e/k + 1`. Three verdicts:

```
count: declared work <= 5·n + 5   derived 5·(n + 1)   PROVEN
count: declared work <= 4·n + 5   derived 5·(n + 1)   OVER (n: derived 5, declared 4)
shout: declared work <= 10        derived ω(print) + 2   UNPROVED (opaque: print)
```

`OVER` and `UNPROVED` are compile errors under `=== COST: ERRORS ===`. A
bound the compiler cannot confirm does not compile; remove it, or make the
opaque callee's cost known.

**Callers compose on the declaration.** Where a function has a declared
bound, every caller substitutes the declared bound, not the derived cost.
`inc : Int -> Int | work inc <= 10 .` is one op, but `g n = inc n + 1` derives
`work g <= 12`. That is what makes the bound an interface: an implementation
may change within its promise without moving its callers.

**Commit sees the bound.** `fpr commit` renders `$work`/`$alloc` entries into
the written interface it compares, so a changed bound, tighter or wider, is
not a compatible subset and needs `--major`. (Tighter could be a patch; the
check compares written text, as it does for types.)

**Encoding.** The parser keeps bounds as reserved entries `("$work", e)` and
`("$alloc", e)` after the per-parameter predicate list, like the `$unsafe`
marker. `Precond.reservedEntry` keeps them out of the precondition table and
out of Safety's facts. They travel with the signature through units and
module hashing untouched. Sol parses and ignores them.

## Result sizes: the one declaration the pass does not check

`List.sum (List.map f xs)` folds over a list whose length the pass cannot
see: it is the result of `map`. A third kind of bound names it:

```
map : (a -> b) -> (xs : List a) -> List b | size map <= len xs .
range : (a : Int) -> (b : Int) -> List Int | size range <= b - a + 1 .
```

A caller substitutes the declared size wherever the call's result is used
as a length. Unlike `work` and `alloc`, `size` is not verified against the
body: deriving output lengths needs a size analysis the pass does not have
yet, so the report lists every one under
`assumed result sizes (declared, not verified by this pass)`. It is an
explicit assumption, visible in the interface and in the report, which is
the honest shape until a size pass exists. With sizes on std/list's
producers, `total xs = List.sum (List.map double xs)` closes to
`19·(len xs + 1) + 8` and `main = print (total (List.range 1 10))` to
`ω(print) + 292`.

## Making bounds provable: the standard library

A bound is only as provable as the costs beneath it, so the same batch made
two libraries legible to the pass:

- **std/list.fpr**: its producers (`range`, `repeat`, `reverse`, `append`,
  `map`, `indexedMap`, `filter`, `filterMap`, `take`, `drop`, `takeWhile`,
  `dropWhile`, `zip`, `zipWith`, `sortWith`, `sortBy`, `unique`) declare
  their result size, and twenty of its twenty-two `unsafe` loops now declare
  their measure, the list they walk (`(xs : List a | measure xs)`), the
  count they lower (`repeatGo`), or `measure (b - a)` for `rangeGo`. Only
  `merge` (two lists) and `mergeAll` (a halving) stay `unsafe`: their descent
  is not one parameter. A caller's `List.map f xs` now costs
  `(len xs + 1) · (work f + c)`.
- **std/string.fpr**: `leadGo`, `trailGo`, `repeatGo`, `codesGo`, `chrs`,
  `mapGo` declare measures; the helpers that recurse through `splitAt` and
  `countAt` do not yet.
- **String primitives** have declared costs read off `runtime/runtime.c`: a
  string carries its length, so `strlen`, `String.len` and `charAt` are one
  op; `strcat a b` is `1 + len a + len b` work and `16 + len a + len b` bytes;
  `substr` is bounded by its source; `chr` is one 17-byte cell. `str` renders
  any value and `print` is I/O: both stay ω.
- **Sizes through fields.** `List.length m.items` is `len m.#2`: the pass
  knows a record field by position, and the report says so. Writing
  `len m.items` in a bound is refused with that explanation; bound such a
  length as a parameter for now. The length of a computed value (a rendered
  string, a built list) is the named opaque `ω(?len)`.

`examples/todo.fpr`'s `view` went from a sum of ω terms to
`(len m.#2 + 1)·(9·ω(?len) + 5·ω(str) + 48) + …`: the loop structure is now
visible, and what remains opaque is the rendering of values to strings.

## Tests

`tests/check_cost.py`: `bound_ok.fpr` and `bound_caller.fpr` build (and
`g` derives 12 from `inc`'s declared 10); `bound_over.fpr` is refused naming
the coefficient; `bound_free_name.fpr` names `omega`; `bound_unproved.fpr`
names `print`; `bound_pipeline.fpr` proves `19 * len xs + 27` over a
range/map/sum pipeline and closes `main`; the todo report shows
`(len m.#2 + 1)·(` on `view` and
`ω(dropGo)` for the program's own unmeasured helper. `tests/check_cases.py`
still refuses `f : Int -> Int | junk .`, now inside the bound grammar.
