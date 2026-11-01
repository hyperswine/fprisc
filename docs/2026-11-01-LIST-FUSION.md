# Checked typed-core List fusion (B1)

Date: 1 November 2026. Status: implemented; enabled by default for native
compilation. This lands B1 from
[the zero-overhead proposal](2026-11-01-UNBOXING-ZERO-OVERHEAD-PROPOSAL.md),
with the representation boundary confirmed in
[the companion analysis](2026-11-01-ZERO-OVERHEAD-CONFIRMATION.md).
The change does not alter List's representation or introduce SIMD on cons
cells. Updated later the same day: let-bound producers are floated to their
use before the site walk, and the remaining B1 rules (`map`/`filter`
cross-composition, `length` consumer rules, and producer-only `map` over
`range`) are now implemented.

## Scope and placement

`Core.Typed.ListFusion` is a typed-core pass over closed programs. It runs
before callback specialization, so the ordinary specializer, inliner and
native backend consume the fused result rather than requiring a second native
List implementation. Both standalone and linked native pipelines use the same
pass. Linked inputs share one immutable callback catalog; the pass also reuses
that catalog's contract library instead of reconstructing it for each
function. Only definitions rewritten by the pass enter the existing
pass-scoped verification/erasure path.

The admitted rewrites are:

- `fold f z (range a b)` becomes `foldRange f z a b`;
- `sum` and `product` consume `range` through their checked fold wrappers;
- fold consumes `map` or `filter` with a composed callback;
- `length` consumes `range` (`lengthRange a b`), reduces through safe `map`
  (`length (map f xs)` becomes `length xs`), and folds safe `filter`
  predicates without allocating list cells (`length (filter p xs)` becomes
  `fold (\n x -> if p x then n + 1 else n) 0 xs`, which then fuses further
  with any inner producer);
- `map` after `map` and `filter` after `filter` compose their callbacks;
- `map` after `filter` (`mapFilter f p xs`) and `filter` after `map`
  (`filterMapped p f xs`) fuse remaining list-producing cross-compositions
  into a single pass without materializing the intermediate list;
- producer-only `map f (range a b)` (not consumed by `fold` or `length`)
  rewrites to `mapRange f a b`, building the output list in one descending
  pass (one cons cell per element, with no intermediate `range` list and no
  `reverse`);
- `sum`, `product`, and `length` work through all supported producer chains;
- a let-bound producer reaches its consumer through the binding: a
  single-use `xs = range/map/filter ...` is floated to its use position
  first, so the rules above apply unchanged to the idiomatic spelling.

The pass runs in three ordered stages after let-bound producer floating:

1. **Consumer and same-kind fusion (`go`):** `fold`, `sum`, `product`, and
   `length` consume `range`, `map`, and `filter` spines to a fixed point,
   while `map`/`map` and `filter`/`filter` collapse adjacent same-kind
   transformers.
2. **Cross-kind transformer fusion (`goCross`):** remaining `map f (filter p xs)`
   and `filter p (map f xs)` list producers (those not already consumed by a
   scalar reduction) fuse to `mapFilter` and `filterMapped`.
3. **Producer-only range mapping (`goRange`):** remaining `map f (range a b)`
   list producers fuse to `mapRange f a b`.

The float is the rule's own small safety proof: the binding must be
single-use (occurrences counted capture-aware, so a value consumed by a
synthesized closure still counts), and the producer's evaluation may move
across only movable work - FusionSafety-safe expressions, bare function
values, and partial applications (which allocate the function value; the
body or primitive runs only when a combinator saturates it, an interleaving
the composition rules already rule on). Substitution never descends into a
lambda. A declined float leaves the binding untouched, so a program the rule
does not admit is observationally unchanged even before any fusion decision.

The composition rules also accept an existing List as the innermost source;
they eliminate the intermediate List, not the source List itself. Nested
chains are rewritten to a fixed point. Captures and leading callback arguments
are retained in fresh typed closures, with the existing combined capture
budget.

`foldRange`/`foldRangeGo`, `lengthRange`/`lengthRangeGo`,
`mapRange`/`mapRangeGo`, `mapFilter`/`mapFilterGo`, and
`filterMapped`/`filterMappedGo` in `std/list.fpr` are the checked loops used
for these targets. No new source-language construct is exposed.

## Identity, safety and diagnostics

A global name is not enough evidence: user code may define its own `map`,
`fold`, `length`, or `range`. Candidate wrappers and workers are structurally
matched against their catalog templates, including generated function-match
wrappers, closure-conversion aliases and the expected Nil/Cons control flow. A
same-named user function without the standard combinator shape is left alone.

Composition reuses `Core.FusionPolicy`/`FusionSafety` evidence for both
callbacks and capture evaluation. Effects and traps therefore cannot be
reordered or elided merely to obtain fusion (for example, `length (map f xs)`
and `mapRange f a b` both require `f` and its captures to be
`FusionSafety`-safe). Declines use the existing `FusionNote` machinery and
`--remarks` reporting; `Compiler.Remarks` renders both vector and List notes.
For example, a callback containing `/` is declined because division can trap.
The original `tests/bench/unbox/list_filter.fpr` deliberately retains this
behavior.

Range/fold fusion has one intentional boundary difference already admitted by
`Core.FusionPolicy`: checked Int overflow may occur at a different point. In
particular, an unfused singleton range ending at tagged-Int `maxInt` returns,
whereas the ascending fused loop traps while computing its final `a + 1`.
The regression suite pins this edge; it is not claimed as byte-identical trap
behavior.

The rollback is `FPR_NO_LIST_FUSE=1`. `-nolistfuse` participates in codegen
cache identity, so switching the pass cannot reuse incompatible cached native
output.

## Regression evidence

`python3 tests/check_list_fusion.py` checks:

- differential output for fold/sum/product/length over range, capture
  composition, map/map, filter/filter, map/filter cross-composition,
  producer-only `map` over `range`, and composition over a literal List input;
- the let-bound spellings of all of the above, including chained bindings and
  let-bound `length`, with multi-use and unsafe-seed bindings asserted
  untouched (allocation counts identical to the disabled build);
- allocation-request counts with fusion enabled and disabled across both
  scalar consumers (0 requests when fused) and list-producing pipelines
  (`mapRange`, `mapFilter`, `filterMapped`);
- refusal of same-named user combinators (`range`, `sum`, `length`);
- identical output/trap behavior for a division callback, plus its decline
  remark;
- the documented `foldRange` maxInt overflow edge.

With allocator probing restricted to the pipeline (`FPR_NO_LOOP_REGIONS=1` and
`FPR_NO_CALL_REGIONS=1`), the enabled `sum`, `map`, `filter`, `length-range`,
`length-map`, and `length-filter` cases make zero allocation requests. Their
disabled equivalents make respectively 1,000, 3,000, 2,000, 1,000, 3,000, and
2,000 requests for 1,000 source elements; the let-bound spellings (fold, sum,
map, filter, a two-binding map chain, `let-length-map` over 2,000 elements,
and `let-length-filter`) go 1,000 / 1,000 / 3,000 / 2,000 / 5,000 / 6,000 /
2,000 requests to zero. For producer-only list outputs over 1,000 elements
(with `List.head` adding 1 `Option` request), `map-range` drops from 3,001 to
1,001 requests, `map-filter` (500 kept) drops from 3,001 to 2,001, and
`filter-map` (500 kept) drops from 4,001 to 2,001.

## Measured performance

Raw samples are in `bench/2026-11-01-list-fusion.json`: 15 interleaved runs on
macOS arm64. Medians below are wall seconds; speedups are rounded.

| workload | disabled | enabled | speedup |
|---|---:|---:|---:|
| `list_sum` | 0.197943 | 0.075825 | 2.61x |
| `list_map` | 0.514999 | 0.112533 | 4.58x |
| safe range/filter/sum | 0.353482 | 0.113571 | 3.11x |
| original trapping filter | 0.376541 | 0.350414 | not fused |

The explicit `loop_sum` median is 0.046031 s. The fused range/sum pipeline is
therefore about 1.65x from that particular loop ceiling; B1 removes the
intermediate allocation but does not claim that all remaining loop, callback,
tagging or scheduler costs are gone.

Whole-process allocator probes show the same structural result at benchmark
scale:

| workload | disabled requests / bytes | enabled requests / bytes |
|---|---:|---:|
| `list_sum` | 20,000,002 / 960,000,112 | 2 / 112 |
| `list_map` | 60,000,002 / 2,880,000,112 | 2 / 112 |
| safe filter/sum | 40,000,002 / 1,920,000,112 | 2 / 112 |

`loop_sum` also reports two requests and 112 bytes, identifying these as
startup/runtime allocations rather than residual pipeline allocation. The
original division-based filter is unchanged at 40,000,002 requests and
1,920,000,112 bytes, so its timing difference is not a fusion gain.

The let-bound spellings (same drivers, the pipeline bound with a let and
consumed through the binding) measure
(`bench/2026-11-01-LIST-FUSION-LETBOUND.json`, same method):

| workload | disabled | enabled | speedup |
|---|---:|---:|---:|
| let_sum (range bound, consumed by sum) | 0.210958 | 0.070061 | 3.01x |
| let_map (map output bound) | 0.537913 | 0.094166 | 5.71x |
| let_filter (safe predicate, bound) | 0.366188 | 0.100088 | 3.66x |

These sit at the direct-nested results above (the fused loop is the same
code), which is the point: the let spelling no longer costs the pipeline.

## Compile-time and validation

`bench/2026-11-01-list-fusion-scaling.json` records cold compilations of 4, 8,
16 and 32 independent map/range/sum functions, with fresh caches in each mode.
From 8 through 32 functions, enabled compiler allocation was 1.518, 1.667 and
1.971 GB versus 1.530, 1.712 and 2.097 GB disabled; wall times were 0.837,
0.916 and 1.079 s versus 0.824, 0.938 and 1.171 s. This is a scaling probe,
not a general compile-speed claim: it shows no quadratic growth over this
family and includes the shared-catalog/contract-library implementation above.

## Remaining headroom

All four follow-up B1 rules identified in the initial review (single-use
let-bound producer floating, `map`/`filter` cross-composition, `length`
consumer fusion, and producer-only `map` over `range`) are now implemented.
Later callback specialization, inlining, representation selection and loop
optimization determine how close the fused scalar loop gets to hand-written
code.

Measured on `tests/bench/unbox` (N = 1M, 20 repetitions, median of 9 runs,
one machine): the specialised fused loop kept one `EntryTick` per inlined
callee, which `Workers.scalarWorkers` rejected, so the loop was never made a
scalar worker and paid tag/untag churn every iteration. Admitting a literal
`EntryTick` in `Workers` and `KernelKinds` lets it become a worker:
`list_sum` went from 36.4 to 31.3 ms against 25.8 ms for the hand loop (gap
1.41x to 1.21x); `list_map` stays near 47 ms. The remainder is fuel accounting:
the fused loop still pays about two ticks per iteration (three for `list_map`)
against one in the hand loop. Batching them changes fuel accounting and
belongs with the proposal's loop-tick work, so it is not done here.

Lowering fused pipelines onto the vector kernels was measured and declined
(the column materialisation costs more than the fused loop; see
[the zero-overhead confirmation](2026-11-01-ZERO-OVERHEAD-CONFIRMATION.md)).

A single-use let-bound producer is not floated into a match (`Match` or
`MatchTail`), a closure capture list (`ClosureValue`/`CodeCall`/`JoinCall`), or
a conditional branch (`If` arms): match-tail arguments and capture lists must
remain evaluated locals, and moving a producer into a conditional arm would make
its evaluation (and any trap in its callback) conditional on taking that arm.
All three boundaries are pinned in `tests/check_list_fusion.py`.

The larger zero-overhead order remains: representation-neutral fusion first;
List representation and type-directed unboxing separately; SIMD only after a
profitable dense representation exists. No default chunked/array-backed List
or loss of O(1) cons and persistent sharing is implied by this pass.
