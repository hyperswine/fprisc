# Private scalar variant returns in hosted Base

Codegen 199 removes the allocation of a nominal sum when a native producer returns one of several scalar constructors and the caller reads its tag and fields. The two-constructor loop now makes **zero allocations per 1,000 calls**. Codegen 198 and both rollback switches make 1,000. The explicit tag-and-payload loop also makes zero. This held on one and four workers, with ordinary inlining on and off. [Baseline](../bench/2026-11-05-base-scalar-variant-before.json) · [ARM64 cases](../bench/2026-11-05-base-variant-native.json) · [x86-64 cases](../bench/2026-11-05-base-variant-x64.json)

## Representation and boundaries

The complete checked declaration determines the private layout. Each constructor field must resolve to Int, Bool or Unit. The first word identifies the alternative, followed by enough words for the widest declared alternative. Binary sums use a Bool tag, larger sums use the declaration's integer variant numbers, and shorter alternatives pad unused words. The layout must fit the native result registers, currently eight words including the tag. Adding an unused wider or heap-valued alternative can therefore rule out a worker. The entry's checked parameters and return layout participate in the unit cache identity.

All successful paths through the producer and its mutually recursive callees must construct a permitted variant or call a proven producer. A reader may inspect a field only where it exists in every alternative still possible on that branch. A whole result that escapes, is captured, or crosses a module boundary uses the normal tagged entry. Standing constructor calls retain their entry fuel. Unused fields still evaluate in order, including their prints, division and overflow. The independent module check invokes a public constructor-returning function, retains its result in the client, and passes it back to a separately bound reader that checks all seven fields.

A pending call region may reclaim the storage containing a field. The private path checks the region after the call. An inactive region closes while all words stay in registers. An active region takes one temporary tuple containing all result words through the runtime's ordinary copy or adoption operation. Only the surviving words return to the reader. A foreign-boundary regression deliberately supplies a heap reference at a declared Int slot, forces a region to open, and checks that the field moved and retains its original bytes after the close.

## Measurements

At five million calls on macOS ARM64, the optimized loop won 12 of 13 paired runs against codegen 198 and 10 of 13 against rollback. Ordinary regions and inlining were enabled. Counter runs were separate from the timed binaries. [Samples, compiler allocations and code sizes](../bench/2026-11-05-base-variant-throughput.json)

| Form | Median | Allocation requests | RV64 root text |
| --- | ---: | ---: | ---: |
| Codegen 198 | 37.15 ms | 5,002,442 | 2,436 B |
| Codegen 199 | 33.38 ms | 0 | 2,924 B |
| Explicit tag and payload | 33.03 ms | 0 | 2,932 B |
| Codegen 199 with type specialization disabled | 37.26 ms | 5,002,442 | 2,436 B |

Private workers cost 488 bytes of root text on this fixture. Cold compiler allocation rose from 1.526 to 1.530 GB. The existing absolute compile gates passed at 1.61 GB for hello, 32.90 GB for std-live, and 67.62 GB for pos1. Std-live is 9.9% above its reference against a 10% limit.

With inlining disabled, generated programs with 16, 64 and 256 independent producers each received one private result worker per producer. At 256, variant returns used 4.889 GB of compiler allocation and 270,208 bytes of root text. Explicit tag-and-payload source used 4.550 GB and 227,480 bytes. The rollback used 4.006 GB and 153,240 bytes. Preserving a tagged public entry for every producer has a measurable code-size cost. [Scaling measurements](../bench/2026-11-05-base-variant-scaling.json)

The final native suites ran 280 cases on each of ARM64 and x86-64. RV64 Linux userspace under QEMU ran 72 cases. The suites cover mixed and oversized declarations, mutual recursion, disabled specialization and product returns, unused fields that print or fail, both successful Int endpoints, public module calls, and the active-region heap reference. [RV64 execution](../bench/2026-11-05-base-variant-rv64.json)

## Physical Pi 4B running QOS

The first isolated run passed 186 cases. The final run added 32 endpoint and unused-field comparisons and passed all 218. Each run collected 6,912 ordinary replies per mode across nine routing, worker-count and contention configurations. Separate probes checked competitor progress and fuel. The installed desktop finished both runs with the same executable, PID 17227 and zero restarts.

| Run | Mode | Median | p99 | Maximum | Replies over 1 ms |
| --- | --- | ---: | ---: | ---: | ---: |
| First | Specialized | 171 µs | 1,331 µs | 2,223 µs | 352 |
| First | Rollback | 193 µs | 1,336 µs | 4,730 µs | 336 |
| Final | Specialized | 171 µs | 1,391 µs | 2,153 µs | 371 |
| Final | Rollback | 194 µs | 1,334 µs | 2,419 µs | 344 |

The median fell in both runs. The direction of the p99 difference changed, and more specialized replies exceeded 1 ms in both runs. These results support allocation removal and comparable median throughput to the explicit source. They leave a general latency or deadline guarantee open. [First device record](../bench/2026-11-05-base-variant-pi-initial.json.gz) · [Final device record](../bench/2026-11-05-base-variant-pi-final.json.gz)

## Next storage case

A shared persistent list read twice still pays for its elements' wrappers. At 1,000 elements, both a single-constructor `Meters Int` list and a two-constructor signed-contribution list use **2,000 allocations and 64,000 bytes**. Explicit storage takes **1,000 allocations and 32,000 bytes** for the same two answers. This holds with either inlining mode and on one or four workers. That gap is in stored elements across a whole collection, beyond a private function return. [Sources and storage counters](../bench/2026-11-05-base-persistent-storage-before.json)


The [qualification record](../bench/2026-11-05-base-variant-validation.json) binds the exact compiler, tests, raw device results and benchmark files. All 41 Haskell suites and the 279-configuration host scheduling matrix passed. [Host scheduling samples](../bench/2026-11-05-base-variant-scheduling.json)

To repeat the allocation and semantic checks, run `python3 tests/check_base_variant_returns.py` from the repository root. The paired timing command is `python3 tools/bench_base_transport.py --family variant --count 5000000 --before /path/to/saved/codegen198/fpr --record /tmp/variant-times.json`. Use `python3 tools/bench_base_variant_cost.py --record /tmp/variant-scale.json` for the independent compiler-cost series.
