# Mixed scalar vector pipeline fusion

Kind: implementation and physical-target validation record.
Applies to the working changes on FP-RISC `01772b4`, code-generation revision
53, alongside the [wider accumulator workers](2026-10-20-WIDE-ACCUMULATOR-WORKERS.md).

## Behavior

Mixed `Vec.map` / `Vec.filter` pipelines, optionally ending in `Vec.fold`,
can execute in one scalar traversal. For example:

```text
Vec.fold (weighted 2) 7 (Vec.filter (above 5) (Vec.map (plus 1) vector))
```

The loop transforms each input, evaluates its filters in order, compacts
accepted values into the original column, and updates the accumulator.
Filter order is stable. Fold remains left-to-right and returns the ordinary
`(accumulator, vector)` pair, including the vector's transformed contents.
Nested expressions and adjacent single-consumer `let` bindings qualify.

This first pass requires a filter and at least one map or fold. Map-only,
filter-only and map/fold pipelines retain their existing optimization paths.
In particular, a floating map/map chain followed by a fold must not lose its
existing NEON map kernel to a new scalar loop.

Int, F32 and F64 elements qualify, with one numeric element kind throughout
the pipeline. A scalar numeric fold accumulator may have a different kind
from the elements. Scalar captures can be Int, Bool, F32 or F64. The entry
accepts at most eight arguments: seven captures/seed values plus the vector.
Admission is bounded to 16 stages and 64 reachable callback functions.
Larger or unsupported candidates retain existing calls.

Callbacks must be known, fully saturated after their captures, and accepted
by the existing arithmetic and fusion-safety analyses. Cyclic callback graphs
are declined. Captures and the seed must already be local values or literals;
effectful computations cannot move ahead of a producer. A retained intermediate
prevents the adjacent-let rewrite. Division, effects and unknown callbacks
retain separate passes.

The existing [Int-overflow exception](2026-10-03-FUSION-EFFECT-ORDER.md)
also applies: pure checked Int arithmetic can fuse, so the first reported
overflow can differ from materialized pass order. This is not a new claim of
strict overflow-order preservation. Floating operations keep their per-element
order; fold arithmetic is not reassociated.

Entry guards check capture representations, vector representation and numeric
kind. A mismatch executes the original complete passes using saved boxed
arguments and reconstructed closures. The fast path calls the existing raw
callback entries. Each callback retains its fuel safepoint, so every loop
iteration reaches at least one tick, including rejected elements. The kernel
also ticks on entry; it does not duplicate that tick on every element.

`FPR_NO_VEC_FUSE=1` disables this pass and the older map/write-back-fold fusion.
The latter previously escaped that switch. The new flattened entry arguments
are included in frame-slot sizing. Arguments seven/eight are copied out of
x64's thread-local argument cells before representation checks or untagging.
Revision 53 invalidates generated-unit caches; the runtime ABI is unchanged.

This implements vector traversal fusion. It does not implement immutable-list
fusion, allocation reuse, record-valued pipeline kernels or new SIMD kernels.
Existing specialized scalar passes already update vectors in place, so the
benefit sought here is fewer traversals, loads and stores, not wholesale
elimination of intermediate heap vectors.

## Validation

`tests/check_vector_pipelines.py` checks independent expected values for lengths
0 through 99, stable compaction, returned vectors, no-fold and empty results,
captured predicates, seven captures/seed arguments, and boxed-vector fallback.
It covers F32/F64, a cancellation-sensitive left-to-right fold, and IEEE values
including signed zero, subnormals, infinities and NaNs against C arithmetic.
Effectful callbacks, a failing division and an effectful seed retain their
original order. The native matrix combines inlining and register allocation
on/off with an off/on/off fusion cache cycle, running each with one/four harts.

Emission checks cover RV64, A64, x64 and RV32; RV32 retains its existing float
fallback. `tests/check_x64_vectors.py` executes an eight-argument mixed pipeline
under Rosetta for 100 lengths, forcing fuel callbacks and allocation calls to
clobber temporary SIMD registers. The vector-kind suite preserves native A64
NEON execution and its C IEEE reference checks. Existing fallback-frame,
specialization, register, worker and wider-worker suites also pass.
The complete Base suite was not run.

Linux ARM64 binaries were executed on the Pi 4 at `192.168.0.233`, and Linux
RV64 binaries on the STAR64 at `192.168.0.215`. Both passed the same
correctness/effect/float cases with fusion on/off and one/four runtime harts.
SSH used pinned host identities; executable hashes were checked after upload.
Task-created board files were removed afterward. Tests ran alongside the
existing QOS services; QOS itself was not repinned or redeployed.

## Measurements

One million Int elements: map `x + 1`, retain values above 500,000, then fold
`acc + 2*x` from 7. Every run checked sum `750000500007` and 500,000 retained
elements. Timing excludes vector construction, final length inspection and
freeing. Seven samples per mode alternate off/on and on/off, using one runtime
hart and otherwise normal compiler settings.

| Board | Fusion off median | Fusion on median | Interpretation |
|---|---:|---:|---|
| Pi 4 | 98.328 ms | 98.198 ms | Effectively unchanged |
| STAR64 | 74.549 ms | 69.553 ms | 6.7% less time, 1.072x speedup |

The initial implementation ticked fuel redundantly on each element and measured
98.705 → 102.269 ms on Pi and 74.178 → 73.155 ms on STAR64. Moving that extra
tick to kernel entry, while retaining every callback tick, produced the final
results above. Correctness and physical measurements were repeated afterward.

These are a single arithmetic microbenchmark with live services and unpinned
CPU clocks. They establish a modest STAR64 improvement, not a general QOS
speedup or a memory-use reduction. Callback calls, frame setup and checked
arithmetic remain in the loop. Bounded callback inlining into the fused body
is a candidate for follow-up measurement, with fuel accounting and failure
semantics preserved.

The [evidence JSON](evidence/2026-10-20-mixed-scalar-pipelines.json) records
source/compiler/executable hashes, board identities, correctness-call status
and output hashes, all timing samples, local check results and cleanup status.
