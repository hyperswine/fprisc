# Finite hosted worker admission

A group of 131 mutually recursive scalar functions lost every private worker under codegen 193. Selecting the first 128 names cut the cycle, so call-graph validation discarded the partial group. A separate producer with 300 strict additions also exceeded a 1,024-node cutoff and allocated a one-field wrapper on every call.

Codegen 194 removes the 128-function, 20,000-node aggregate and 1,024-node body cutoffs from hosted scalar workers, along with the 1,024-node cutoff from constructor returns. Codegen 195 solves scalar kinds once per recursive call group. The program contains at most one private worker per eligible source function in each pass. The existing absolute compiler-cost gates apply to hosted profiles. Builtin image admission uses its own target manifest.

## Representation and fallback

Constructor-return admission visits the function's return paths. Within a recursive component, all members can reach one another. A worker is sound when the constructors directly returned by the component and the results of all its external tail calls agree. Calls must be saturated, and their private names must remain free at the call site. Error-only cycles supply no result representation. Only workers reachable from a qualifying reader are emitted. Unary workers use the ordinary tagged payload convention. Wider workers retain the target register-width constraint.

Scalar admission records the lexical calls in the eligible arithmetic and Boolean fragment, processes callees before callers, and follows dependencies from recursive loops. For each recursive group, the kind solver shares constraints among its members and imports already-proved external signatures. A caller cannot impose its preferred representation on a polymorphic callee. A conflicting or unresolved group falls back together. Reachability from the successfully typed loops is checked again so a refused loop cannot leave an unused helper worker behind. Public entries retain their original guard and tagged fallback.

The native regression checks the escaping constructor and the printed effect before an overflowing addition as well as the successful sum. With ordinary inlining disabled and allocations isolated from regions, the 300-addition producer changes from **1,000 allocations to zero**. All 131 scalar workers are emitted. The saved compiler emits none for that group. Results agree on one and four workers. A Core regression also forwards through 160 helpers into an oversized return producer, checks private-name collisions and capture, and verifies that contradictory scalar signatures refuse the whole recursive group.

The physical Pi measurements in the [separate target report](2026-11-05-PI-QOS-PHYSICAL-QUALIFICATION.md) used codegen 193. This change affects private worker admission and leaves broader Base storage representation and application static-arena admission as separate roadmap work.

## Cost and runtime results

The [compiler and throughput benchmark](../bench/2026-11-05-hosted-worker-components-cost.json) covers groups of 16, 32, 64, 128 and 256 functions. At every size, codegens 194 and 195 emitted identical disassembly including relocations. At 256 functions, sharing the kind solution reduced whole-compiler allocation **3.408 → 2.993 GB**. Both emitted **142,548 bytes** of root RV64 text. Codegen 193 emitted **61,652 bytes** at this size because it dropped all 256 workers. The extra private copies have a measurable code cost. The absolute compiler gates passed at **1.61 / 32.87 / 67.58 GB** for hello, std-live and pos1. Std-live measured 9.9% above its baseline against its existing 10% limit.

The native throughput runs used ordinary inlining and regions, one worker and thirteen alternating samples. Allocation probes and all builds finished before timing.

| Workload | Saved compiler | Codegen 195 | Explicit source | Optimization disabled |
| --- | ---: | ---: | ---: | ---: |
| 20 million steps through 131 recursive functions | 63.03 ms | 62.30 ms | 24.34 ms | 62.90 ms |
| 500,000 calls returning a wrapper around 300 strict additions | 48.66 ms | 48.45 ms | 49.51 ms | 47.84 ms |

The scalar group won 12/13 pairs against the saved compiler. Its explicit source uses one self-recursive loop. All four forms allocated zero. The wide return removed **500,245 allocation requests**, matching the explicit payload's zero. It won only **7/13** pairs against the saved compiler and **5/13** against rollback. The arithmetic-heavy case therefore demonstrates removal of the allocation cost with little change in elapsed time.

All 41 Haskell suites passed, along with native ARM64 and x86-64 source regressions, RV64 and x86-64 execution against C oracles, exact lifetime and overflow differentials, C2 code-size comparisons, and the controlled static-arena regressions. The [host scheduling matrix](../bench/2026-11-05-hosted-worker-components-scheduling.json) includes the large recursive group and the wide producer in enabled and rollback forms. It verified fuel, competitor progress, route and watchdog behavior across 207 configurations and 158,976 ordinary replies. There were 124 observations above 1 ms, including 52 with the wide return and 49 with its rollback. The largest observation across the matrix was 2.300 ms. The [validation manifest](../bench/2026-11-05-hosted-worker-components-validation.json) binds the tested inputs and results.
