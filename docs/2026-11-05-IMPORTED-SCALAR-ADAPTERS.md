# Scalar wrappers defined in another module

Codegen 204 removes the extra allocation when a program uses an imported scalar wrapper as a Map value. For 512 keys, both the direct constructor and the exported pack/read API now use **5,625 allocations and 343,584 bytes**, equal to the plain-integer map. Codegen 203 used 6,137 allocations and 359,968 bytes. With inlining disabled the corresponding counts were 6,136 and 5,624; the same 512 objects and 16,384 bytes disappeared. Both modes produced the independent sum on one and four workers. [Before](../bench/2026-11-05-map-imported-wrapper-before.json) · [After](../bench/2026-11-05-map-imported-wrapper-after.json)

## Ownership of private entries

The importing artifact can instantiate a generated unary constructor from its complete checked declaration. Local and imported constructors share the same constructor-function builder. For a named pack or read adapter, the caller needs the checked source body, matching published type and arity, and a successful rewrite of every affected dependency. A foreign observer or an adapter that prints the wrapper requires its public tagged argument. An adapter that prints its scalar field can retain that operation in its private body. [Carrier admission](../compiler/Core/Typed/Carrier.hs) · [Constructor construction](../compiler/Core/Typed/Instantiate.hs)

A private copy of an imported definition belongs to the importing root or content-addressed unit. Repeated uses in one unit share the copy. Two other independently compiled clients and the root were linked in one executable, producing three distinct homes for the same imported pack adapter. Rebuilding after a source edit that printed the wrapper forced the tagged path, and restoring the original source restored specialization. Attached modules, a foreign reader, a caller returning a Map to an actor, and an arena copying one of 2,048 managed foreign values all exercised the public or ownership boundary. Public budget derivation again accepted 56 bytes and refused 55 in both compiler modes. [Regression fixture](../tests/check_imported_carriers.py) · [Wrapper module](../tests/base/carrier_meters.fpr)

## Cost of 1,200 maps

Paired uninstrumented medians are based on 13 alternating runs per mode. Each map is read twice. The separate instrumented executables used 1,525,201 allocations before specialization and 1,372,201 afterwards for both source forms. The explicit map also used 1,372,201. [Samples, compiler cost and emitted text](../bench/2026-11-05-imported-carrier-throughput.json)

| Source form | Codegen 203 | Codegen 204 | Explicit integers | Tagged rollback | Wins vs 203 |
|---|---:|---:|---:|---:|---:|
| Imported pack/read | 21.64 ms | 21.41 ms | 21.65 ms | 21.70 ms | 11/13 |
| Direct imported constructor | 21.74 ms | 21.54 ms | 21.66 ms | 21.63 ms | 9/13 |

Root RV64 text grew from 3,944 to 5,504 bytes for pack/read and from 3,880 to 5,156 bytes for the direct constructor. With 256 producer/reader pairs in one unit, the compiler emitted 256 of each private entry and shared three imported adapters across them. The compilation used 8.62 GB and 357,420 root text bytes, versus 6.78 GB and 249,572 bytes for explicit code. The three absolute compiler-cost gates passed at 1.61, 32.90 and 67.63 GB. The standard-library case remains near its 10% allowance. [Scaling data](../bench/2026-11-05-imported-carrier-scaling.json) · [Validation record](../bench/2026-11-05-imported-carrier-validation.json)

## Physical qualification

Two separately staged ARM64 Linux runs alongside QOS passed 166 cases apiece on the Pi 4B. Both confirmed the explicit byte and allocation counts and passed the two scheduler watchdogs. Each run measured 6,912 ordinary replies per mode across nine routing, worker-count and contention configurations.

| Pi run | Median, private / tagged | p99, private / tagged | Maximum, private / tagged |
|---|---:|---:|---:|
| First | 200 / 206 µs | 1,228 / 1,283 µs | 1,986 / 2,357 µs |
| Second | 199 / 205 µs | 1,251 / 1,336 µs | 2,053 / 1,956 µs |

On the second run 252 versus 268 replies exceeded 1 ms. The QOS desktop retained PID 17227 and recorded zero restarts. The host scheduler suite passed 351 configurations. Native ARM64 and x86-64 each passed 80 focused checks, and RV64 Linux userspace passed 48 under QEMU. All 41 Haskell suites passed. [Device runs, compiler identity and hashes](../bench/2026-11-05-imported-carrier-validation.json) · [Host scheduling](../bench/2026-11-05-imported-carrier-scheduling.json)

The linked Pi pack adapter can call the stack-growth runtime before its fuel decrement. The validation record includes the disassembly and hash of the exact board executable showing that branch. A Pi response bound must establish adequate stack room or account for that path, then account for the fuel policy, scheduler and operating system. The new [linked callback instruction budget](2026-11-05-STATIC-APPLICATION-SEQUENCES.md#linked-callback-instruction-budget) covers controlled RV64 builtin execution. Main boot and memory qualification on the Pi remains at codegen 197.
