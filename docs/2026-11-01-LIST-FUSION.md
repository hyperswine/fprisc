# Checked typed-core List fusion (B1)

Date: 1 November 2026. Status: implemented; enabled by default for native
compilation. This lands the first slice of B1 from
[the zero-overhead proposal](2026-11-01-UNBOXING-ZERO-OVERHEAD-PROPOSAL.md),
with the representation boundary confirmed in
[the companion analysis](2026-11-01-ZERO-OVERHEAD-CONFIRMATION.md).
The change does not alter List's representation or introduce SIMD on cons
cells.

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
- `map` after `map` and `filter` after `filter` compose their callbacks;
- `sum` and `product` work through those supported producer chains.

The composition rules also accept an existing List as the innermost source;
they eliminate the intermediate List, not the source List itself. Nested
chains are rewritten to a fixed point. Captures and leading callback arguments
are retained in fresh typed closures, with the existing combined capture
budget.

`foldRange`/`foldRangeGo` in `std/list.fpr` are the checked ascending loop
used for range/fold fusion. No new source-language construct is exposed.

## Identity, safety and diagnostics

A global name is not enough evidence: user code may define its own `map`,
`fold` or `range`. Candidate wrappers and workers are structurally matched
against their catalog templates, including generated function-match wrappers,
closure-conversion aliases and the expected Nil/Cons control flow. A
same-named user function without the standard combinator shape is left alone.

Composition reuses `Core.FusionPolicy`/`FusionSafety` evidence for both
callbacks and capture evaluation. Effects and traps therefore cannot be
reordered merely to obtain fusion. Declines use the existing `FusionNote`
machinery and `--remarks` reporting; `Compiler.Remarks` now renders both
vector and List notes rather than dropping the latter. For example, a callback
containing `/` is declined because division can trap. The original
`tests/bench/unbox/list_filter.fpr` deliberately retains this behavior.

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

- differential output for fold/sum/product over range, capture composition,
  map/map, filter/filter and composition over a literal List input;
- allocation-request counts with fusion enabled and disabled;
- refusal of same-named user combinators;
- identical output/trap behavior for a division callback, plus its decline
  remark;
- the documented `foldRange` maxInt overflow edge.

With allocator probing restricted to the pipeline (`FPR_NO_LOOP_REGIONS=1` and
`FPR_NO_CALL_REGIONS=1`), the enabled sum, map and filter cases make zero
allocation requests. Their disabled equivalents make respectively 1,000,
3,000 and 2,000 requests for 1,000 source elements.

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

## Compile-time and validation

`bench/2026-11-01-list-fusion-scaling.json` records cold compilations of 4, 8,
16 and 32 independent map/range/sum functions, with fresh caches in each mode.
From 8 through 32 functions, enabled compiler allocation was 1.518, 1.667 and
1.971 GB versus 1.530, 1.712 and 2.097 GB disabled; wall times were 0.837,
0.916 and 1.079 s versus 0.824, 0.938 and 1.171 s. This is a scaling probe,
not a general compile-speed claim: it shows no quadratic growth over this
family and includes the shared-catalog/contract-library implementation above.

The final compiler passes `make unit-tests`, `tests/test_check_registry.py`,
`tests/check_compile_budget.py`, and the List regression suite. The base suite
was run in bounded batches because the full parallel run exceeded the command
window. Every B1-relevant and other executed job passed except the existing
`panic_actors_std` stdout assertion: both this tree and an independently built
unchanged main put the expected `deliberate` panic on stderr and exit 1. That
unrelated pre-existing assertion was not changed in this work.

## Remaining headroom and deferred rules

This is deliberately a narrow, checked first slice. It does not yet handle
let-bound producer pipelines, map/filter cross-composition, `length`, or
map-over-range without a fold consumer. Those need their own shape and safety
evidence rather than broad pattern matching. Later callback specialization,
inlining, representation selection and loop optimization determine how close
the fused scalar loop gets to hand-written code.

The larger zero-overhead order remains: representation-neutral fusion first;
List representation and type-directed unboxing separately; SIMD only after a
profitable dense representation exists. No default chunked/array-backed List
or loss of O(1) cons and persistent sharing is implied by this pass.
