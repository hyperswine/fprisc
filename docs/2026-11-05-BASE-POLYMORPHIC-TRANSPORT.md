# Checked polymorphic forwarding in hosted Base

Codegen 198 closes the measured gap for a recursive polymorphic helper that returns its original argument. At 1,000 iterations, the two calls forwarding a freshly constructed wrapper and a pair now allocate **zero objects**, matching the explicit scalar and flat-pair loops. Codegen 197 and the codegen 198 rollback allocate **2,000**. This held with normal and disabled inlining, and on one and four workers. The allocation comparison isolates the operators by disabling call and loop regions. [Before](../bench/2026-11-05-base-instance-forwarding-before.json) · [After](../bench/2026-11-05-base-instance-forwarding-after.json)

## When the compiler can remove the allocation

The checked source function must return a type variable carried by exactly one parameter. On every successful path it returns that parameter, an alias, or a saturated self-call forwarding the same local. The proof follows binder identities through matches and branches. Conditions and other arguments may print, trap, or diverge. They must be independent of the forwarded value. A successful return and a recursive edge are both required.

An eligible caller immediately matches the helper result against the known constructor or tuple it supplied. The caller evaluates arguments in source order, retaining the original constructor evaluation and field bindings. A private checked instance still executes the helper with Unit in the forwarding slot. All callers with the same helper and complete control type share that instance. The original entry serves other callers, including separately compiled modules. The optimizer keeps the original path for linear payloads, open call types, helpers that inspect the payload, and unmatched readers. The type checker verifies both the rewritten calls and the completed instance graph before erasure.

The retained-entry pass uses a finite work queue. A reserved original is enqueued once. Hosted Base admits concrete instances for demonstrated rewrites only. The global rollback is `FPR_NO_TYPE_SPEC=1`. The compiler's JSON remarks identify emitted instances and explain refusals for the inspected aggregate call sites.

## Runtime and compiler costs

One million iterations on macOS ARM64 gave the following startup-inclusive medians, with ordinary inlining and regions. Thirteen alternating runs per form used executables built without counters. The allocation column comes from separate instrumented runs. [Benchmark and samples](../bench/2026-11-05-base-transport-throughput.json)

| Form | Median | Allocation requests | RV64 root text |
| --- | ---: | ---: | ---: |
| Codegen 197 | 18.38 ms | 2,000,978 | 3,040 B |
| Codegen 198 | 15.76 ms | 0 | 2,868 B |
| Explicit loops | 16.11 ms | 0 | 3,212 B |
| Codegen 198 with specialization off | 17.30 ms | 2,000,978 | 3,040 B |

The optimized form won 13/13 pairs against codegen 197 and 12/13 against rollback. Cold compiler allocation on this fixture rose from 1.533 GB to 1.540 GB. The existing absolute gates passed at 1.61 GB for hello, 32.88 GB for std-live and 67.62 GB for pos1. Std-live is still 9.9% above its reference against a 10% limit.

All 41 Haskell suites passed. Host ARM64 and x86-64 tests exercised print order, overflow and division, heap values held across actor calls, a warm on/off/on cache, and independently loaded modules built with opposite settings. Linux RV64 userspace under QEMU passed 28 paired execution cases. The host scheduling matrix passed 261 configurations. [RV64 execution](../bench/2026-11-05-base-transport-rv64.json) · [Scheduling matrix](../bench/2026-11-05-base-transport-scheduling.json) · [Validation record](../bench/2026-11-05-base-transport-validation.json)

## Pi 4B running QOS

Two Linux ARM64 builds each passed 130 isolated cases beside the existing QOS desktop. The board ran the powersave policy at an observed 600 MHz. Each build ran the semantic and allocation checks on one and four workers, checked competitor fuel and progress, and exercised the watchdog. Each latency column below summarizes 6,912 ordinary request/reply samples across the same nine local/remote and contention configurations. The desktop finished both runs with its original executable, PID 17227 and zero restarts.

| Runtime C toolchain | Specialized p99 | Rollback p99 | Specialized max | Rollback max |
| --- | ---: | ---: | ---: | ---: |
| GCC 13.3 | 467 µs | 601 µs | 1,164 µs | 1,383 µs |
| Zig with reserved registers | 561 µs | 689 µs | 1,231 µs | 1,540 µs |

An initial Zig cross-build accepted the two fixed-register flags but emitted C instructions reassigning x28, which holds the scheduler's current worker. Both optimized and rollback binaries crashed. The qualification builder now checks emitted instructions under register pressure and rejects this configuration before packaging. Explicit Zig CPU features `-mcpu=baseline+reserve_x27+reserve_x28` passed that check and the complete on-device suite. The regular GCC build also passes the register check. These sampled maxima still exceed 1 ms. The desktop boot and longer memory evidence belongs to the separate codegen 197 run. [GCC device record](../bench/2026-11-05-base-transport-pi-gcc.json.gz) · [Corrected Zig device record](../bench/2026-11-05-base-transport-pi-zig-reserved.json.gz)

## Next measured representation gap

A recursive producer returning either of two named constructors, each carrying one Int, still allocates 1,000 objects at 1,000 calls. The same program returning an explicit Boolean and payload pair allocates zero. Both inlining modes and both worker counts agree on the answer. This provides a concrete test for private scalar-variant returns and tagged boundary fallback. Broader Base aggregate storage, general response-time bounds and concurrent static-arena lifetimes remain roadmap work. [Variant source and baseline](../bench/2026-11-05-base-scalar-variant-before.json)
