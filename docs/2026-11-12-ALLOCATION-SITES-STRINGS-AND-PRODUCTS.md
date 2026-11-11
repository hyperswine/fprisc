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

## Speed against C and the peers

`tests/bench/apps/run.py --runs 5` after these changes (`results/2026-11-12-after.json`):

| Workload | FP-RISC wall / RSS | C | FP-RISC / C |
|---|---|---|---|
| csv | 0.908 s / 175 MB | 0.029 s | 31.8x |
| wordfreq | 1.440 s / 315 MB | 0.067 s | 21.4x |
| format | 0.301 s / 397 MB | 0.192 s | 1.6x |
| records | 0.453 s / 133 MB | 0.113 s | 4.0x |
| treemap | 0.794 s / 76 MB | 0.071 s | 11.2x |
| sim | 0.192 s / 4 MB | 0.038 s | 5.1x |

The table above was measured while the test suite ran on four workers in parallel. Best-of-3 single
runs on a quiet machine are lower (treemap 0.63 s, records 0.37 s, wordfreq 1.2 s). Against the
11 November baseline (`2026-11-11-m4-57201f0.json`): format 0.645 -> 0.301 s and sim 1.347 -> 0.192 s.
Peak RSS is down across the board (csv 1356 -> 175 MB, wordfreq 1795 -> 315 MB, sim 3775 -> 4 MB).
csv and wordfreq remain 20-30x C. Their time is in the string and map code itself, not in allocation.

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
- **Fixed-cost proposal steps 1-3.** Instruction selection and frames, sharing checked operations, and
  loop-invariant checks are next on the speed side.
