# Private scalar wrappers across polymorphic library calls

Codegen 203 removes the wrapper allocation from values inserted into an imported persistent Map. Building a 512-key map and folding over it twice now uses **5,627 allocations and 343,648 bytes** with default inlining. Codegen 202 used 6,139 allocations and 360,032 bytes. Both the allocation count and the bytes match the program that stores integers directly. At 128 keys the difference is exactly 128 allocations. Both results hold with one and four workers. [Codegen 202 baseline](../bench/2026-11-05-std-map-storage-before.json) · [Codegen 203 differential](../bench/2026-11-05-map-carrier-native.json)

## What the compiler proves

A checked producer returns an imported nominal container instantiated with a local, closed, single-constructor wrapper around Int, Bool or Unit. Starting at a caller whose public type can stay unchanged, the compiler tries private versions of the local producer, wrapper constructor and consumer. A callback that originally matched the wrapper can accept its field directly. Checked named constructor calls retain a function entry, including when ordinary inlining is disabled. The polymorphic Map code still performs its comparisons, rotations and folds.

The library's type signature alone cannot authorize this change. A polymorphic function can print its argument or pass it to foreign code. The compiler follows every checked global call whose type mentions a changing parameter and checks the published calling scheme at both representations. It tracks each dependency by function and affected formal parameters so recursive groups have finite proof obligations. Ordinary control arguments can still have effects. An unproved operation, a hidden existential field, a captured partial application, or an unavailable body refuses the private group. A same-named library changed to print the value through a recursive helper retained the public wrapper in a warm cache. [Transport proof](../compiler/Core/Typed/Parametric.hs) · [Caller transformation](../compiler/Core/Typed/Carrier.hs) · [Host regression fixture](../tests/check_base_carrier.py)

Original public entries remain callable. Whole-value printing, sending a map to an actor, and using an independently attached module exercised the tagged boundary. The optimization currently targets hosted 64-bit executables. Library, plugin and QOS app image emission keep the tagged boundary. Both specialization rollback switches were tested, including a plain-integer control with product returns disabled. Public cost derivation also keeps the tagged representation. A fixture derived 56 bytes in both modes, accepted a 56-byte annotation and rejected 55. This prevents a merged analysis from promising a private layout to a separately emitted caller.

## Measured costs

The hosted benchmark builds 1,200 maps with alternating cardinalities, reads each twice, and checks the independent arithmetic sum. The timings use ordinary runtimes. Allocation counters come from separate instrumented executables. Codegen 202 and 203 used identical runtime sources. [Samples, source hashes and compiler measurements](../bench/2026-11-05-map-carrier-throughput.json)

| 1,200 maps | Codegen 202 | Codegen 203 | Explicit integers | Specialization disabled |
|---|---:|---:|---:|---:|
| Allocation requests | 1,525,201 | 1,372,201 | 1,372,201 | 1,525,201 |
| Allocated bytes | 87,744,160 | 82,848,160 | 82,848,160 | 87,744,160 |
| Median of 13 alternating runs | 22.58 ms | 22.48 ms | 22.30 ms | 22.28 ms |
| Root RV64 text | 4,104 B | 5,380 B | 3,696 B | 4,104 B |

The private version was faster in 9 of 13 pairs against the previous compiler and 6 of 13 against rollback. The allocation difference is repeatable. Elapsed time remains close across all four implementations.

With 256 independent producer/reader pairs, codegen 203 emitted exactly 256 private producers and 256 readers. The compiler allocated 8.80 GB and emitted 364,152 bytes of root text, versus 6.75 GB and 249,868 bytes for explicit integers. The absolute build gates passed at 1.61 GB, 32.90 GB and 67.63 GB. The standard-library fixture remains close to its 10% allowance. [Scaling](../bench/2026-11-05-map-carrier-scaling.json) · [Validation](../bench/2026-11-05-map-carrier-validation.json)

## Execution, memory and physical scheduling

ARM64 and x86-64 each passed 96 checks. RV64 Linux userspace passed 44 under QEMU. These include overflow, division by zero, ordered callback output, exact failure diagnostics, both rollbacks, and independent module and cache checks as applicable to each backend. A foreign fixture placed real heap strings in all 2,048 map slots under their declared Int type, read and validated them inside an explicit arena, then verified that the selected string had been copied to a different address across the arena reset. All 41 Haskell suites, prior list/materialization and tree regressions, and RV64 single-entry and sequential static-arena checks passed. [ARM64](../bench/2026-11-05-map-carrier-native.json) · [x86-64](../bench/2026-11-05-map-carrier-x64.json) · [RV64](../bench/2026-11-05-map-carrier-rv64.json)

The final compiler passed 158 physical cases in a separately staged Linux ARM64 bundle on the Pi 4B running QOS. At 512 keys the direct no-argument program used 5,625 allocations and 343,584 bytes with default inlining, exactly matching the explicit control on the board. The host fixture above also processes command-line arguments. The Pi checked the additional 512 allocations and 16,384 bytes in rollback, the arena copy, effects, failure prefixes, and both watchdogs. The installed desktop retained PID 17227 and recorded zero restarts. [Final device telemetry](../bench/2026-11-05-map-carrier-pi-qualified.json.gz)

Across nine route, worker and contention configurations, the Pi recorded 6,912 uninstrumented replies per mode. With the optimization, median and p99 were 201 µs and 1,243 µs, versus 205 µs and 1,268 µs with rollback. There were 276 versus 263 replies above 1 ms, and the maxima were 2,105 versus 2,056 µs. The host passed 333 scheduling configurations. The mixed physical results do not establish a response-time bound. The validation record identifies a separate, earlier 150-case Pi run by its own compiler hash. QOS Main boot and memory qualification remains at codegen 197. [Host matrix](../bench/2026-11-05-map-carrier-scheduling.json) · [Both runs and exact inputs](../bench/2026-11-05-map-carrier-validation.json)

## Remaining boundary

Moving the wrapper declaration to a separate unit restores the full gap. Using its exported constructor directly or calling its pack and read functions both used 6,137 allocations and 359,968 bytes at 512 keys with default inlining. The matching plain map used 5,625 allocations and 343,584 bytes. The work remaining is to prove the imported wrapper constructor or adapter and produce a private caller without changing the published unit ABI. This differs from proving that Map transports a value opaquely, which is already implemented. General scheduler admission and concurrent static-arena lifetimes also remain open. [Imported-wrapper fixture and measurements](../bench/2026-11-05-map-imported-wrapper-before.json)
