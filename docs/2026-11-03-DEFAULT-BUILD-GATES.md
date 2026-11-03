# Default-build gates: passes checked together

Date: 3 November 2026. Kind: test record. Base: main `2d3b9d6`.
Item 1 of the [roadmap checkpoint](2026-11-03-ZERO-OVERHEAD-ROADMAP-CHECKPOINT.md):
make the correctness and abstraction-cost gates reflect default builds.

Each zero-overhead pass already had its own on/off test. Those tests turn one
pass off and leave the rest on, so they never compare the default build with a
build that has all of them off, and their programs are written for one pass.
List fusion needed four trap-safety fixes on its first day for this reason
([trap-safety record](2026-11-02-LIST-FUSION-TRAP-SAFETY.md)). This record adds
two checks that look at the passes together.

**Outcome:** no miscompile found. 9,880 generated case comparisons across
three seeds agree with the default build, and every relaxed difference is the
documented List fusion overflow reordering. The abstraction check found two
cost gaps (below). They are recorded, not fixed.

## 1. `tests/reliability/list_fusion_random.py`, extended

The existing generator is extended, not replaced. A program now holds
`LFR_K` (10) independent cases, and `main` picks one case from its argument
(`Sys.args`). So every case runs in its own process, and a trap in one case
cannot hide a later one. Each case calls its function twice with two of
`0, 1, 2, 3, maxInt`, which takes both branches of most conditions.

Case kinds:

| Kind | What it exercises |
| --- | --- |
| `plain` | the original pipelines: range/literal sources, map/filter, sum/product/length/fold or a printed List, direct or let-bound, optionally behind a sibling binding that can trap or print |
| `print` | the same with printing callbacks (`print "tN {x}" >> body`), so the order and number of callback calls is on stdout |
| `capture` | callbacks that capture a let-bound value whose evaluation can print or trap, and a producer used only through a closure capture |
| `cond` | a let-bound producer used only under an `if` arm, a `case` arm, the right of `and`, after a refutable `O.Some v = o`, or right of `\|>?` |
| `trmc` | materialized `map`/`filter`/`append`/`take`/`head` outputs (typed TRMC) |
| `tuple` | a loop-carried tuple or record. The pipeline runs either in the next state (tuple scalars decline) or in the exit with an arithmetic, trap-capable next state (tuple scalars fire), sometimes behind a conditional or let-bound next state |
| `pair` | a pair-returning recursion or accumulator (pair returns) |
| `tick` | a self-looping accumulator around a pipeline (tick batching) |
| `known` | an Option-returning helper or a tuple scrutinised in a loop, with trapping fields (case of known constructor) |

Callbacks may trap with division by zero, Int overflow, `error`, or a failed
refutable pattern. Range ends still include minInt and maxInt.

Variants, from `compiler/Compiler/Options.hs` (`FPR_NO_<NAME>`):

- `default`: no `FPR_*` flags;
- `all-off`: `FPR_NO_LIST_FUSE FPR_NO_CASE_KNOWN FPR_NO_TUPLE_SCALARS
  FPR_NO_TICK_BATCH FPR_NO_TRMC FPR_NO_PAIR_RETURNS` together;
- one variant per flag, each turned off alone, on the first `LFR_SINGLE` programs.

Each variant must match the default build exactly on exit status, stdout and
stderr. The only allowed difference is RELAXED: both runs trap with Int
overflow, at a different element, with the same stdout. This now applies only
to variants that turn List fusion off, because no other pass has a relaxation.
`LFR_STRICT=1` still makes RELAXED fail.

The check also prints how many variants changed the code section (`__text`,
or `.text` on Linux) compared with the default build. That is evidence the
pass changed code, which a remark alone does not show.

Sizes: the PR-CI default is 8 programs, all-off, and the single-flag variants
on 2 programs. That is 200 comparisons in about 17 s on this Mac.
`RELIABILITY_FULL=1` (nightly) runs 96 programs, with the single-flag variants
on 24 of them.

### Results (local, arm64 macOS, compiler at `2d3b9d6`)

| Run | Comparisons | Not OK | Relaxed (variant) | Time |
| --- | --- | --- | --- | --- |
| fast, seed 20261103 | 200 | 0 | 3 (list fusion off) | 17 s |
| full, seed 20261103, single on 24 | 2,400 | 0 | 42 (32 all-off, 10 list_fuse-off) | 175 s |
| full, seed 1, single on 48 | 3,840 | 0 | 39 | 197 s |
| full, seed 2, single on 48 | 3,840 | 0 | 48 | 183 s |

Variants whose code section differed from the default build in the seed-1 run
(out of 48): list_fuse 48, case_known 29, tuple_scalars 18, tick_batch 48,
trmc 48, pair_returns 23. All-off differed in 96 of 96 programs. Roughly half
the cases trap in the default build, and the mix is spread across all nine kinds.

The first full run had 2 TIMEOUTs. Both were a generator defect, not a compiler
defect: a captured `List.sum (List.range 1 n)` with `n = maxInt` made the
unfused build materialize a huge list (the fused build overflowed at once).
The generator now uses `n % 50`.

## 2. `tests/check_abstraction_equivalence.py` (new; Base registry)

Four computations, each written four ways: a direct pipeline, a let-bound
pipeline, a pipeline wrapped in helper functions, and an explicit loop.

- `sum-map-filter`: `sum (map (*3) (filter (<= n/2) (range 1 n)))`;
- `count-filter`: `length (filter (> n/2) (range 1 n))`;
- `sum-count-pair`: sum and count with a `(Int, Int)` fold accumulator, or a
  pair-returning accumulator loop;
- `materialize`: a `map (*2) (filter ...)` list used twice (sum and length),
  or a cons-and-reverse loop.

Gated: stdout must be identical across all four spellings and match the
expected value, both in an allocation-probe build (1,000 elements) and in the
default build (1,000,000 elements). Allocator requests (`FPR_COST_PROBE` /
`FPR_COST_REPORT`) are gated only where the expectation is firm (10 rows):

| Expectation | Requests |
| --- | --- |
| fused direct/let-bound sum-map-filter and count-filter, and their loops | 0 |
| sum-count-pair loop: 4 for `"{s} {c}"` plus the one final pair | 5 |
| materialize direct/let-bound (the producer composition `check_list_fusion.py` pins) | 1,501 |
| materialize loop: 500 conses plus a 500-cell reverse, plus 1 | 1,001 |

Reported, not gated: `__text` size, the compiler's own allocation
(`fpr compile +RTS -t`, as `check_compile_budget.py` measures it) cold and warm,
`fpr build` wall time cold and warm, and runtime. Runtime is 11 paired rounds
plus one discarded warmup round. Each round runs all four spellings of a
family in a rotated order, and the median is reported.

`fpr compile` keeps its unit cache next to the output file (`<out dir>/units`),
not under `XDG_CACHE_HOME`. So a cold compile needs its own output directory.
The first draft of the check got this wrong.

### Results (local, arm64 macOS; raw samples in [`bench/2026-11-03-default-build-gates.json`](../bench/2026-11-03-default-build-gates.json))

| Family | Spelling | Alloc @1k | vs loop | Median ms @1M | Compiler MB cold / warm |
| --- | --- | --- | --- | --- | --- |
| sum-map-filter | direct / let | 0 / 0 | 0 | 6.4 / 6.4 | 2678 / 1652 |
| | helper | **2,000** | +2,000 | **20.5** | 2681 / 1655 |
| | loop | 0 | - | 7.0 | 1558 / 862 |
| count-filter | direct / let | 0 / 0 | 0 | 5.9 / 5.6 | 2667 / 1641 |
| | helper | **1,500** | +1,500 | **16.1** | 2659 / 1632 |
| | loop | 0 | - | 6.5 | 1556 / 860 |
| sum-count-pair | direct / let / helper | **505** each | +500 | 8.7-8.9 | ~2680 / ~1653 |
| | loop | 5 | - | 6.2 | 1557 / 862 |
| materialize | direct / let / helper | 1,501 each | +500 | 18.1 | ~2670 / ~1645 |
| | loop | 1,001 | - | 14.6 | 2652 / 1626 |

Times are whole-process wall time, startup included. `__text` is about
318 KB for every spelling that imports `std/list`, and 278 KB for the loops
that do not import it.

### Gaps found (abstraction costs, not miscompiles)

1. **Helper-wrapped pipelines do not fuse.** For example,
   `small xs = List.filter p xs`, `triple xs = List.map f xs`, then
   `List.sum (triple (small (List.range 1 n)))`. This makes 2,000 requests
   where the direct form makes 0, and runs about 3.2x slower (2.7x for
   count-filter). The remarks show the cause. Callback specialization runs
   inside each helper first (`filter`/`map` become `$typed.mono.small.1` and
   `$typed.mono.triple.1`). `main` inlines the helpers afterwards, so List
   fusion sees user loops rather than catalog combinators. It declines without
   a `not-fused` remark. Fixing this is a pass-ordering decision (fuse before
   specializing callbacks into helpers, or let fusion recognise specialized
   catalog clones). It is not a small fix.
2. **A tuple accumulator in `List.fold` allocates one tuple per element**
   (505 requests, about 1.4x slower than the loop). This holds in all three
   pipeline spellings. The pair-returning loop allocates only its final pair.
   The [tuple-scalars record](2026-11-02-TUPLE-SCALARS.md) limits A2 to
   self-recursive parameters, so a fold's accumulator is outside its admitted
   shapes. The gap is recorded here so that extending A2 or B1 can gate it.
3. (Context, not a defect.) A materialized `map` over `filter` over a range
   still conses the 1,000-element range (1,501 requests against the loop's
   1,001).

Warm compiles still allocate about 1.65 GB, because cached units skip only
codegen and the front end runs again. That is visible here and gated
elsewhere (`check_compile_budget.py`).

## Scope

- Everything above is local: arm64 macOS, `fpr build` default target, one hart.
  No hosted CI run, no X64/RV64 execution. The allocation gates were recorded
  here, and Linux x86-64 CI may need its own numbers if they differ.
- The scheduling contract (preemption inside each spelling) is not part of the
  equivalence check. `check_tick_batch.py` and `check_self_loops.py` cover it
  for the shapes they hold.
- Also green on this branch: `make fpr`, `make unit-tests`,
  `python3 tests/check_list_fusion.py`, `tests/test_check_registry.py`.
