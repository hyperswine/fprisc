# Eight-word Base results on x86-64

Codegen 183 and x64 selector revision 32 extend the private hosted Base result
convention from two to eight words. Eligible three-through-eight-field returns
now avoid their constructor allocation on x86-64 as they already do on AArch64
and RV64. This is abstraction removal in the generated program; it does not
establish canonical Base aggregate layouts or unbox the component values.

## ABI and register placement

Fields return in `rax, rdx, rcx, rsi, rdi, r8, r9, r10`, in that order. The
first two positions retain the existing pair convention. `r11` remains reserved
for expansion scratch and the frame-restoring epilogue. `r10` is eligible as
an explicitly fixed result, but remains outside the allocator's ordinary
register pool. The selector, transfer checker, physical operand validator and
renderer agree on every position and the eight-word limit.

This is a private generated-code convention. Public and foreign entries keep
their existing tagged ABI, nine-field results stay boxed, and escaping values
still materialize. The source-shape admission and hosted worker body-size
policy are unchanged. `FPR_NO_PAIR_RETURNS=1` rolls the pass back. The compiler
and selector revisions invalidate cached units without changing the public
module ABI. QOS product admission is unchanged.

Using a scratch register as a result exposed a parallel-copy hazard: after
placing a destination, the old resolver could reuse that register to break a
later cycle. Identity copies removed from its pending work had the same risk.
The resolver now reserves all original register destinations until the entire
copy packet finishes. An independent snapshot oracle covers all 256 mappings
of four registers, including a scratch destination. Restoring the old resolver
in an isolated negative control makes that test fail.

## Qualification

The [backend execution record](../bench/2026-11-05-x64-products-oracle.json)
covers 2,100 independent C-reference answers for each width from two to eight,
plus an eight-field result repeating the same source value: 16,800 in total.
It links the actual emitted reader and worker without an
allocator. A fuel shim destroys every volatile register, and the generated
save/restore path must preserve all results. This harness substitutes modeled
TLS cells; it does not itself qualify platform TLS or actor scheduling.

Separate real-runtime checks cover eight-field non-tail recursion in three
actors, with the pass enabled/disabled on one and four workers. Scheduler
observation requires actual fuel-exhaustion events, and every returned answer
is checked independently. Each configuration records 150 fuel exhaustions.
These are continuation-correctness checks, not
scheduling-latency or physical-time bounds.

The [source execution record](../bench/2026-11-05-x64-products.json) covers all
widths through the nine-field fallback, 96 live fields across calls/effects,
mutual tail calls, heap-valued fields, tagged escapes, strict effect order,
unused-field division failure, overflow and the Int lower endpoint. The
isolated allocation check removes 1,000 constructor allocations for every
supported width on one/four runtime workers. Runtime execution here uses
macOS x86-64 under Rosetta; native Linux/Intel execution is required by the
registered CI configuration but is not claimed as a new local result.

## Measured allocation and throughput

The [benchmark record](../bench/2026-11-05-x64-products-benchmark.json) uses
default optimizer/region settings, five million calls and one worker. Allocation
probes are separate from uninstrumented executables; thirteen timing pairs
alternate order and verify every result. No other compiler build or regression
was running during these timing samples.

| Fields | Allocations, rollback → enabled | Median ms, rollback → enabled | Faster pairs |
| --- | ---: | ---: | ---: |
| 3 | 5,003,661 → 0 | 101.788 → 78.429 | 13/13 |
| 4 | 5,003,661 → 0 | 107.157 → 84.758 | 12/13 |
| 8 | 5,006,098 → 0 | 137.214 → 110.504 | 13/13 |

These Rosetta process-time results show approximately 19–23% lower medians on
these fixtures. They are not native Intel throughput, board timing, universal
speedups or WCET. The rollback is the same compiler with product returns
disabled, not a separate historical-compiler benchmark.

## Remaining roadmap work

All 41 Haskell suites, existing native AArch64 source regressions, the RV64
product oracle, local x86-64 scalar/self-loop/vector regressions,
controlled static-arena tests and registry checks pass. The unchanged compiler
budget passes at 1.59/32.68/68.98 GB allocated for hello/std-live/pos1, with
std-live peaking at 433 MB. The [C2 cost record](../bench/2026-11-05-x64-products-cost.json)
retains exact code/function parity through 256 helpers and 1.000–1.001x
compiler allocation versus explicit monomorphic twins. See the
[validation manifest](../bench/2026-11-05-x64-products-validation.json) for final
compiler, input and evidence hashes. No baseline or limit was relaxed.

Checked Base storage and generic/module boundaries, broader escaping aggregate
layouts, allocating-loop resource bounds and physical scheduling qualification
remain unfinished. Completing the result register bank removes an existing
target restriction while preserving those separate obligations.
