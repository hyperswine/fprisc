# Allocation sites, strings, owned-map follow-ups, local products, literal divisors

Date: 12 November 2026. Kind: implementation record. It follows
[static reuse, increment 6](2026-11-11-STATIC-REUSE-PLAN.md) and covers the four
items chosen next: string building, the owned-map follow-ups, the
remaining static-reuse gaps, and a first fixed-cost step toward C.

## Summary

All measurements are on an Apple M4, comparing builds of the same app sources. Requests come from
`FPR_COST_REPORT`. RSS and instructions come from `/usr/bin/time -l` on the default build.
Every output matches `tests/bench/apps/expected`.

| Workload | Requests before (69d893a0) | After | Peak RSS | Instructions |
|---|---|---|---|---|
| csv | 24.0M | 12.0M | 233 -> 175 MB | 21.89 -> 19.80 G |
| wordfreq | 10.4M | 4.3M | 417 -> 315 MB | 23.59 -> 22.89 G |
| format | 20.1M | 7.1M | 1025 -> 397 MB | 6.58 -> 4.16 G |
| records | 5.0M | 5.0M | 133 MB | 3.06 -> 3.05 G |
| treemap | 1.94M | 0.87M | 134 -> 76 MB | 5.32 -> 4.96 G |
| sim | 80.1M | 0.04M | 161 -> 4 MB | 9.57 -> 4.98 G |

A loop doing `% 7` and `/ 2` (50M steps) goes from 2.64 G to 1.34 G instructions; its step function
shrinks from 146 to 90 instructions.

## A tool first: allocation sites

`FPR_ALLOC_SITES=<file>` on a probe build (`FPR_COST_PROBE=1`) records each
allocation's return-address chain. The chain is six frames deep, followed along the frame
pointers, and stops at the first address outside the program text. Every allocation in a probe
build goes through `fpr_alloc`, so the table is complete. `tools/alloc_sites.py EXE SITES`
resolves the addresses with `atos` and charges each allocation to its first FP-RISC
function (`--chains` shows whole chains). Every change below started from that table.

## 1. Strings

- **`std/string`.**
  - `split`, `lines` and `words` build their lists front to back, by tail recursion modulo cons,
    instead of accumulating and reversing.
  - `lines` is one scan. It no longer splits and then copies the list, and it leaves out each `"\r"` with
    a single cut.
  - `startsWith` and `endsWith` compare in place (`sameAt`); they used to cut a substring first.
  - `toInt` accumulates negatively, as before. Its digit loop now reports failures as positive codes,
    so only the answer is boxed, and the error messages live in `toIntErr`.

  An edge-case program covering empty strings, trailing separators, `"\r\n"` and the Int extremes
  prints the same with the old and new std. std/string's hash changes as a result. Two compile-pipeline
  baselines under `bench/` record that hash.
- **Interpolation builds one String.** Two pieces work together:
  - A Core pass, `BuildStrings`, rewrites a `strcat` chain of three or more pieces into one call of the runtime's
    `$strcatT` over a tuple of the pieces. It takes `str` off each piece.
  - The runtime copies String pieces and renders anything else as `str` would. It renders twice, once to size
    and once to copy. Rendering is deterministic, and nothing allocates between a render and its
    copy, so the hart's buffer cannot change underneath it.

  Both lowering paths, the erased `Desugar` and `Frontend.Desugar.Typed`, produce `strcat` chains, so
  the pass sits in the optimizer where they meet. It runs where reuse runs (64-bit, fuelled, no ARC).
  A test program covering floats, records, lists, tuples, `Some`, nested interpolations, a 18 KB result
  and twelve pieces prints the same with it on and off (`FPR_NO_REUSE=1`).

  format: 15 allocations per line become 2, the pieces tuple and the line.

## 2. Owned maps

- **The `Map` wrapper.** Once a twin has consumed the map on a path, a `Map` built on that path takes the
  wrapper's cell. That is one allocation per step in every owned-map loop (treemap 500k, wordfreq 2M,
  csv 1M).

  The first version wrote into std/map's shared static empty map: `mapshared` printed `997 997`.
  Entering a twin now copies the empty wrapper first (`freshWrapper`, one allocation per entry).
- **Known constructors in walker twins.** std/map's `update k f m` calls `f (Some old)` and matches the
  result. With `f` inlined, a let whose value is a constructor, used only by tests and projections,
  never needs the cell. Its fields get names, and its tests are decided. That removes wordfreq's 2M
  `Some` boxes.
- **Consuming rotations.** `rotLeft` and `rotRight` are inlined into the walker twin with `balance`.
  `consumeCells` then gives each new `Node` a cell from:
  - t;
  - the walker's own rebuilt subtrees;
  - nodes taken apart from those.

  Every node of an owned map has one parent, so each of these is unique. A cell is taken only under these conditions:
  - on a path where it is known to be a `Node`, so never the static `Leaf`;
  - by a node whose fields only read it;
  - when nothing evaluated afterwards mentions it;
  - at most once.

  Children of t itself are excluded: they went to the recursive call, which may hand back the same cell.
  treemap: `node` allocations 458k -> 275k. The remaining requests are new leaves, one per distinct key, and `get`'s `Some`.

## 3. Local products

sim's 80M requests were `move`'s two `bounce` pairs. Once inlined, each pair was built in every
branch of an `if` and taken apart straight away. The new first pass of the Core pipeline,
`LocalProducts`, handles a let whose value is a tree of lets and ifs ending in one constructor shape (a tuple or a record),
used only by projections and tests of that shape. The let becomes one let per field, each over a copy of the
branching part:

- **Only cheap, pure code is copied.** That means arithmetic, comparisons, projections, tests and ticks: no call
  and no allocation. The lets in front of the branches are floated out and run once.
- **The first trap is unchanged.** The first copy evaluates what the original evaluated up to its first
  field, so if anything traps, it traps first in that copy.

`tests/check_local_products.py` compares answers and traps against the build with these passes off. It covers a tuple, a record in three
branches, a field that divides by zero only in its own copy, a tuple that escapes into a list (it must stay
a cell) and the string pieces. A 200,000-step loop goes from 400,201 requests to 5.

## 4. Division by a literal (first fixed-cost step)

`x / d` with `d` a literal other than 0 and -1 cannot trap: there is no zero divisor, and |q| <= |x|. The
`q * d` and `x - q * d` that `%` expands into cannot overflow either. `Simplify.foldDivisors` marks the three as `OArithU`:

- **IR.** `OArithU` now means "proven not to trap" for every operation, and it is pure.
- **AArch64.** The backend emits the bare `sdiv`, `mul` and `sub`.
- **Other backends.** X64 and RV keep their checked forms for Mul and Div, which is correct but not yet faster.
- **Evaluator.** `Codegen.Eval` still checks, so a wrong proof would show up as a trap.

A differential program over 19 values (signed extremes, negatives, powers of two) and 15 literal divisors
prints the same as the previous compiler.

## 5. The prelude's string loops

csv and wordfreq spend most of their time comparing map keys (`strCmp`) and searching
(`strIndexFrom`). Both are FP-RISC loops in `core/prelude.fpr`.

- **`strCmpGo`.** An `or` in it built a `Bool` object per byte, which was then tested through its header,
  and the walk alternated with `strCmpAt`. It is now one self-recursive function of guards.
- **`strMatchAt`.** It returns how many characters matched, so no `Bool` crosses the call.

Answers are the same on a grid of strings: empty strings, prefixes, and `from` values that are negative or past the end.
csv drops from 19.8 to 15.6 G instructions, and wordfreq from 22.9 to 16.5 G.

The loop still pays, at every byte, the stack check and fuel tick, a test that both arguments are
strings, and a bounds check on each `charAt`. That is about 70 instructions a byte, where C needs about 4. The existing opt-in
modes (`FPR_TYPED_IR_LOOP_MOTION`, `STRING_SCAN`, `SHRINK_WRAP`) change nothing here. Hoisting these
invariant checks out of a self-loop is the fixed-cost proposal's step 3, and it is the largest
remaining lever for csv and wordfreq.

## Gates and the compile budget

Several exact allocation gates now count less than they used to. Each is updated, with a comment saying why:

- **`check_reuse`.** 10000 -> 0. The loop's record never escapes, so local products leaves no cell.
- **`check_case_known` shared-alternative.** 31 -> 1, with the pass on and off. One shape is unboxed either way.
- **`check_abstraction_equivalence` sum-count-pair.** 5 -> 3. The printed interpolation is one String.
- **`check_fold_scalars`.** 2005/1005 -> 2003/1003, for the same reason.
- **`check_persistent_reclamation` elements.** It is now allocation-free, so copy-out has nothing to copy.

The darwin compile budget for `std-live` was already +9.2% over its baseline at `69d893a0`. This work
adds about one more point. Most of it is that each unit using a map now compiles a copy of std/map's
`insGo` with `balance` and the rotations inlined. `tests/compile_budget.json` is rerecorded for
`ghc-9.8.2 aarch64-apple-darwin`. The Linux CI baseline could not be rerecorded from here.

## Speed against C and the peers

`tests/bench/apps/run.py --runs 5` on a quiet machine (`results/2026-11-12-m4-final.json`). The
`before` column is yesterday's default build, still in `bin-fpr` as `fpr-nocopy` (copy-out off, as on
11 November):

| Workload | Before: wall / RSS | Now: wall / RSS | C | Now / C |
|---|---|---|---|---|
| csv | 0.845 s / 1356 MB | 0.580 s / 159 MB | 0.023 s | 25.0x |
| wordfreq | 1.169 s / 1795 MB | 0.696 s / 315 MB | 0.045 s | 15.4x |
| format | 0.621 s / 1026 MB | 0.241 s / 397 MB | 0.168 s | 1.4x |
| records | 0.346 s / 209 MB | 0.339 s / 133 MB | 0.094 s | 3.6x |
| treemap | 0.525 s / 614 MB | 0.419 s / 76 MB | 0.055 s | 7.6x |
| sim | 1.332 s / 3904 MB | 0.168 s / 4 MB | 0.029 s | 5.9x |

The geometric mean against C goes from 12.6x (11 November baseline, `2026-11-11-m4-57201f0.json`) to 6.7x,
and against the peer median from about 6x to 4.0x. The RSS ceilings are lowered to about 1.5x the new
peaks: csv 240, wordfreq 475, format 600, treemap 115 and sim 16 MB. sim's ceiling is set at the process floor rather than 1.5x.

csv and wordfreq remain 15-25x C. Their time is in the prelude's byte loops (section 5) and in the
map's comparator, which is called through the generic `fpr_applyN`. It is not in allocation.

## Still open

- **`Option`/`Result` results of functions that are not inlined.** These are `toInt` (2M boxes in csv) and `get` (196k in treemap).
  A function returning a small sum to a caller that matches at once could return the tag and fields
  in registers, the sum form of pair returns.
- **Substrings.** csv's `split` and wordfreq's `words` cut 4M substrings each. Slices sharing the source
  String would remove them. That is a runtime representation change.
- **The `List.range` cells under `List.map` in `main`.** This is increment 4's open item; format still allocates them.
- **`kp_dup` at `main`'s region close.** format copies its 1M kept lines when `main`'s region closes. Adopting
  the region's slabs when most of it survives would remove that copy.
- **Literal divisors on X64 and RV.** The bare `idiv`/`div` lowering there, and powers of two as shifts on all three.
- **Byte loops.** Hoist the stack check, the string tests and the bounds checks out of self-loops such as `strCmpGo`
  (fixed-cost step 3); call a known comparator directly instead of through `fpr_applyN`.
- **Fixed-cost proposal steps 1-3.** Instruction selection and frames, sharing checked operations, and
  loop-invariant checks are next on the speed side.
