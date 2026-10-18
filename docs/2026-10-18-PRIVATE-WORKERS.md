# Private scalar and two-field workers

Date: 2026-10-18. Kind: implementation and measured acceptance record.
Base: FP-RISC `66b79999328387c66f253a5be522ba748bd48ebe`.
Branch: `codex/scalar-workers-20261018`; code generation revision 49.

## Implemented

`compiler/Workers.hs` adds a bounded Core-to-Core worker/wrapper pass after
source safety, ownership, precondition and cost checking, after inlining and
vector fusion, before ordinary native function emission.

A closed arithmetic call graph containing recursion can use private workers
whose `Int` parameters, intermediate values and results are raw signed machine
words. Public entries check the representation, untag arguments once, call the
worker, and tag its result once. They retain their original body as fallback.
Bool values use immutable singleton objects; public entries validate and
normalize foreign Bool objects so equality retains structural Bool semantics.
Unresolved polymorphic equality supplies no evidence for an integer worker.

A recursive function with a two-field constructor accumulator can instead take
the two fields as separate ordinary value arguments. Statically known,
saturated calls with a matching constructor pass the field expressions directly,
in their original evaluation order. The recursive path stops allocating the
intermediate tuple or record. General entries check shape and split fields;
unknown and partial calls still use their original callable representation.
An explicit final tuple/record is still constructed. Returning the existing
whole accumulator, inconsistent constructor arities, unsupported uses, too many
arguments and budget exhaustion decline the optimization.

Field splitting runs first, allowing scalar specialization to consume its
arithmetic workers. Scalar selection requires a resolved `Int`/`Bool` signature,
no allocation or managed projections, only supported arithmetic/conditions and
known saturated calls, and a closed candidate call graph. Recursive components
and their reachable scalar helpers qualify; isolated small helpers do not.
Existing vector callback call graphs are excluded so their kernel analysis
continues to see the original arithmetic bodies.

Workers reuse the normal stack-growth, tail-call, register-slot and fuel-check
emitter. Integer arithmetic still traps at the signed 63-bit limits. Cold paths
retag the original operands and enter the original primitive, preserving its
exact overflow or division-by-zero reason. Private workers have no PAP object
or public module-table export. Source function arities and public/native ABI
representations are retained.

The first version is enabled for the 64-bit native Base representation on
RV64, A64 and x64. Builtin, ARC and RV32 retain their previous paths; Sol is unchanged.
No floating-point, I32/Word, arbitrary product-width or general multiple-result
calling convention is introduced. Split managed fields remain ordinary values;
this change does not add raw managed-pointer slots or change ownership rules.

Each pass admits at most 128 workers with at most 1,024 original Core nodes per
body; scalar cloning also has a 20,000-node total budget. Split functions need
fewer than eight original arguments; scalar workers accept at most eight.
Fallback entries and additional frames/code have a cost. Source-level cost
proofs continue to describe the original checked program; they are not a new
machine-cycle bound for wrappers. Generated fuel segments remain bounded.

`FPR_NO_SCALAR_WORKERS=1` and `FPR_NO_FIELD_WORKERS=1` independently disable the
passes. Both switches are in native unit and run-cache keys. Revision 49 forces
rebuilding compiled units/modules and matching hosts; existing QOS installations
were not repinned or redeployed by this experiment.

## Measurements

See [the JSON evidence](evidence/2026-10-18-private-workers.json) for every sample,
allocation ledger, exact failure reason, binary hash and source hash.
The allocation probe brackets only the selected operation. At 10,000 iterations,
on macOS ARM64, Linux Pi 4 ARM64 and Linux STAR64 RV64:

| Witness | Both passes off | Both passes on |
|---|---:|---:|
| Scalar sum | 0 allocations / 0 B | 0 / 0 B |
| Tuple accumulator returning a tuple | 10,002 / 480,096 B | 1 / 48 B |
| Two-field record returning a record | 10,002 / 480,096 B | 1 / 48 B |
| Tuple accumulator returning a scalar | 10,001 / 480,048 B | 0 / 0 B |

`Int` was already an immediate value. Its worker changes arithmetic and call
representation, rather than removing a heap box. Field splitting supplies the
large allocation reduction in these witnesses.

| Host | Scalar off → on | Tuple off → on | Tuple-to-scalar off → on | Record off → on |
|---|---:|---:|---:|---:|
| macOS ARM64 | 3.18 → 2.57 ms | 7.04 → 2.31 ms | 7.07 → 2.31 ms | 7.04 → 2.34 ms |
| Pi 4 Linux ARM64 | 37.40 → 32.50 ms | 261.58 → 48.52 ms | 260.21 → 42.22 ms | 255.14 → 49.15 ms |
| STAR64 Linux RV64 | 26.84 → 27.59 ms | 179.39 → 33.75 ms | 177.53 → 35.08 ms | 182.12 → 34.57 ms |

Times bracket one million iterations with an external monotonic-clock probe,
without allocation counters. Seven alternating off/on samples on macOS and five
on each board; all results are checked. One runtime hart, ordinary inlining on,
callback specialization off in both variants. These are small synthetic loops,
not an end-to-end QOS latency result. Board background workloads are not paused.
The STAR64 scalar-only witness does not establish a speed improvement; its tags
are cheap and instruction/branch costs can outweigh eliminating them.

The macOS benchmark executable grows from 447,352 to 464,216 bytes (3.8%).
RV64 assembly text, including comments and names, grows from 49,407 to 60,903
bytes for the root and from 486,548 to 498,044 bytes including linked units.
These assembly-file sizes are not executable text-section sizes.

## Verification and reproduction

`python3 tests/check_workers.py` checks independent switches, inlining on/off,
off/on/off warm caches, one/four runtime workers, dynamic calls, exact output,
strict constructor/argument effects and failure order, integer boundary cases
against a C `__int128` reference, noncanonical foreign Bools, invalid general
entries, managed String fields, actor messages, 10,000 levels of non-tail
recursion, allocation ratchets, four-backend emission, Builtin exclusion, private descriptors,
bounded generated fuel segments and an optimized shared module called by a
host compiled with both passes disabled. `tests/Workers.hs` checks conservative
admission, lexical shadowing, escaping values, unknown kinds, vector callback
exclusion and the worker-count budget. The script is registered in check_base.
On Homebrew setups Cabal may need the libarchive pkg-config path already used
by the compiler build.

The following focused suites passed during implementation, before the final
Bool-entry normalization (the complete worker matrix and physical checks were
rerun after it): specialization; registers; floating-point
inline arithmetic; vector kinds, vector limits and x64 vectors; byte Strings;
view construction; real POSIX module replacement and MVU reload; higher-order
contracts; contract rewrites; structural ownership; and cost equations.
The complete Base suite was not run.

The final Linux compiler was built in an isolated Ubuntu ARM64 container;
standalone test programs were built with native GCC and RV64 cross GCC and run
on the physical Pi and STAR64 over checked-host-key SSH. Binaries were copied to
private `/tmp` directories and checked by SHA-256. Both boards passed one/four
hart output, arithmetic, foreign Bool, fallback, managed-field, stack-growth,
allocation and exact-panic tests. Running QOS files/services were not replaced.
x64 worker code was emitted but this new worker suite did not execute x64 workers;
the existing x64 vector and register tests did execute their own paths.

Reproduce uninstrumented local timings with:

```sh
make fpr
python3 tests/check_workers.py
python3 tests/bench/measure_workers.py
```

The next useful extension is a similarly checked floating-point worker path,
then wider products or multiple results where profiling shows enough repeated
construction. Real QOS profiling is still required before attributing shell or
application improvements to these new conventions.
