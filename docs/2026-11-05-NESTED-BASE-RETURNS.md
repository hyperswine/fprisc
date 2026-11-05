# Nested Base results in private return registers

Codegen 197 removes the two inner pair allocations in `((w,x),(y,z))` when a local caller immediately destructures both pairs. The producer returns four ordinary payload words through the existing private register convention. A caller that keeps the whole result can still call the original entry. An escaping inner object can use the existing shallow return worker.

At 1,000 calls, the [saved compiler](../bench/2026-11-05-nested-base-results-before.json) made 2,000 allocation requests for the nested pair and 1,000 for `Cell (Cell n)`. The revised compiler makes **zero** for both, matching the explicit four-field result. Disabling return workers restores 3,000 and 2,000 requests respectively. Ordinary and disabled inlining give the same isolated counts. This removes intermediate constructors at a private call boundary. The heap representation of a published value continues to follow its nominal declaration.

## Admission

The planner examines the return paths of functions that already qualify for constructor returns. It processes mutually recursive groups together and requires evidence for every successful path. Literal constructors and exact constructor functions contribute shape information. Strict local bindings retain that information through aliases. When branches disagree about an inner constructor, the common plan retains that field as an ordinary value. An over-wide node can retain boxed children, and its parent can still flatten an eligible sibling. A private plan must fit the selected backend's return capacity.

The producer evaluates fields once in their original left-to-right order. A local binding can acquire a flat representation only when all its uses agree. Opaque or effectful uses that require the nominal value refuse that plan. Exact constructor helpers can take already evaluated words through a private identity adapter, preserving their calls and entry fuel even with inlining disabled. Only workers reachable from an admitted reader are emitted.

The reader maps each proven projection to its word offset. It can eliminate matching tag tests and follow local aliases. A conflicting nominal tag, an escaping virtual subobject, or a capture of a packet declines the rewrite. A call-region adapter that handles one ordinary value still follows its tagged contract. The shared-module test exercises that path alongside an owner-local loop that qualifies for the flat worker. The independent caller receives `((7, 8), (9, 10))` from the public entry with either optimization setting.

## Execution checks

Native ARM64 and x86-64 regressions cover normal and isolated regions, both inlining settings, rollback, and one/four workers. They check successful integer endpoints, overflow, division by zero, early failure before a later print, and strict fields that the reader never uses. Real list and closure payloads remain live across allocating calls. Two actors send distinct results with shared list payloads. Width eight qualifies for a flat result, while the tested nine-word result keeps its inner objects. Core regressions cover lexical capture, mixed ordinary/flat uses, worker-name collisions and lower target capacities.

The independent RV64 oracle links the emitted caller and transitive worker closure without an allocator. It executes **6,300 C-reference cases** across one, four and eight returned words, with volatile registers overwritten at fuel exhaustion.

## Throughput and compile cost

| Five million calls | Saved compiler | Nested worker | Explicit flat result | Rollback | Wins versus saved compiler |
| --- | ---: | ---: | ---: | ---: | ---: |
| Double scalar wrapper | 20.81 ms | 18.26 ms | 23.29 ms | 24.96 ms | 13/13 |
| Two pairs | 38.94 ms | 31.03 ms | 33.41 ms | 45.01 ms | 12/13 |
| Two four-field products | 59.79 ms | 47.78 ms | 47.81 ms | 70.47 ms | 13/13 |

The native ARM64 benchmark uses uninstrumented programs, alternating runs and ordinary inlining and regions. Separate counters report **5,002,442 / 10,004,883 / 10,007,321 → zero** requests respectively. Root RV64 text falls from 2,224 to 2,056 bytes, 3,180 to 2,844 bytes, and 4,272 to 3,932 bytes. Cold compiler allocation on those fixtures stays within 0.002 GB of the saved compiler. The unchanged absolute compiler gates pass at 1.61 / 32.88 / 67.62 GB. [Sample series, worker identities and assembled sizes](../bench/2026-11-05-nested-base-returns-throughput.json)

All 41 Haskell suites pass. The host matrix covers 243 configurations and 186,624 uninstrumented replies with one observation above 1 ms. The new nested-return and boxed variants had maxima of 222 and 314 µs respectively in that run. Independent progress and watchdog probes passed. [Host latency observations](../bench/2026-11-05-nested-base-returns-scheduling.json)

## Physical Pi 4B with QOS Main

All **1,198** codegen-197 runtime cases passed on the selected Pi. The physical bundle contains 71 ARM64 executables. ELF symbol checks on the transferred binaries distinguish the nested worker from its rollback. In the isolated pair test, 1,000 calls changed from **3,002 to 2 allocation requests**, including the two requests shared by the command-line harness. The double wrapper changed from **2,002 to 2**. List and closure payloads survived region exits, allocation churn and actor transport, and the exact effect and trap comparisons passed.

The physical matrix timed 186,624 ordinary replies across 243 configurations. At the sampled powersave frequency of 600 MHz, the pooled median was 237 µs, p95 was 4,414 µs, p99 was 9,282 µs and the largest observation was 24,848 µs. There were 42,548 observations above 1 ms. The nested workload's p99 was **1,943 µs with flat results versus 3,011 µs with boxed results**. The corresponding counts above 1 ms were 1,638 and 2,308 of 6,912 each. Every 4,096-element copy still exceeded 1 ms. This expanded workload mix differs from the codegen-193 matrix.

The matched QOS Main candidate passed Files, Logs and Browser cycles on physical V3D graphics. The two memory probes each ran 17 UI cycles with 38,400–38,592 KiB reserved and 17–19 ARC roots after warmup. All three runs passed storage-draining quit and a second boot with signal shutdown. Final checks found the original installed executable, PID 17227 and zero restarts. [Physical qualification and Main measurements](../bench/2026-11-05-pi-qos-197.json), [all per-process results and latency samples](../bench/2026-11-05-pi-197-runtime.json.gz)
