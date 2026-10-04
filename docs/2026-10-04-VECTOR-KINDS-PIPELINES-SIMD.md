# Vector callback kinds, pipeline composition and initial A64 SIMD

Date: 2026-10-04. Kind: implementation and measurement record. Based on
`da36568`; compiler codegen revision 35, A64 lowering revision 12. Follows
[VECTOR-LIMITS](2026-10-03-VECTOR-LIMITS.md) and the
[VECTOR-AUDIT](2026-10-03-VECTOR-AUDIT.md).

## Independent callback kinds

`KernelKinds.signature` solves raw-word kinds for each callback argument and
result across its admitted arithmetic call graph. Int, F64, F32 and Bool are
separate kinds. A single float opcode no longer decides the representation of
every capture, input and accumulator. The selected plans record those kinds and
emit `# vector kinds` comments for inspection.

This admits float scalar captures, checked Bool captures, mixed integer/float
record folds, float record predicates and kind-aware record field kernels.
Int captures are checked and untagged; Bool captures check the object tag and
variant before loading raw 0/1; float captures retain their IEEE bits under the
checked source type. Accumulators use their own result kind when unpacked and
returned. Used record columns compare their descriptor kind bytes to the plan.
These are compiler optimizations within the existing trusted native ABI.

Unsupported/conflicting kinds retain the ordinary callback implementation.
The ordinary tagged `mapAs` path retains its explicit output-layout descriptor;
this change does not make it an arbitrary unboxed type-changing kernel.
Unconstrained raw kinds conservatively default to Int and require the Int path;
identity-only float fields can therefore still miss a record kernel. Passing
full inference/layout evidence to the kernel planner remains useful follow-up.
Boxed vector elements and record-valued accumulators retain generic execution.
The existing scalar capture/register and wide-call argument budgets remain.

Stricter field guards also exposed a capture-free record-map fallback that
incorrectly applied its dummy capture. It now restores the actual one-argument
callback before entering the generic scheme.

## Pipeline expansion

Pure map/map and filter/filter chains now compose arbitrary admitted capture
lists, up to seven combined scalar captures. Filter composition short-circuits:
the second predicate runs only when the first accepts the row. Captures remain
in their original argument order. Float literal construction is recognized as
pure instead of mistakenly refusing arithmetic maps that use constants.

Both callbacks and capture expressions must be free of observable effects and
failures. An adjacent let is substituted only when fusion is legal. Previously,
even a declined candidate could have its let converted to a nested application,
moving outer capture evaluation ahead of the inner pass. A printing-capture
regression now fixes that order. Printing/trapping callbacks still run their
complete passes in the original order, with a named decline explanation.

Synthesized scalar map callbacks are normalized before raw emission and SIMD
selection, avoiding nested callback calls. The normalization has bounded depth;
SIMD also has a bounded vector register budget. Entry fuel charges account for
the callbacks removed by normalization. Register/depth failures keep the scalar
implementation.

Cross-stage map/filter/fold fusion, type-changing map fusion, zipped inputs and
direct column builders remain further pipeline work. Existing integer
write-back fold-of-map support is retained. This is an expansion of legal
composition, not a blanket promise of one pass for every pipeline.

## Initial AArch64 SIMD

Hosted A64 targets now use two-lane NEON for admitted capture-free straight-line
Int add/subtract and F64 add/subtract/multiply maps, including normalized fused
maps. These instructions are part of the hosted AArch64 target's baseline.
`FPR_NO_VEC_SIMD=1` selects the scalar path. `FPR_NO_VEC_FUSE=1` preserves separate
passes. Both switches participate in compiled-unit cache keys.

The loop uses caller-saved vector registers, checks fuel before loading them,
charges callback work per two-element chunk, and uses the existing scalar clone
for the final odd element. Nothing live in a vector register crosses a scheduler
call. There is no FMA contraction or floating reduction reassociation. Empty
and short vectors remain valid. Unsupported expressions keep scalar kernels.

Captured SIMD, record SIMD, F32 SIMD, vectorized filtering and x64 SIMD remain
future work. Existing RVV selection is unchanged. The native runtime ABI stays
at 2 because this change does not change runtime object layout.

## Verification

`tests/check_vector_kinds.py` joins `tests/check_base.py`. It checks selected
plan kinds and executes:

- F64/F32 captures, mixed record folds and captured map/filter compositions;
- 100 lengths, empty/short inputs and odd tails for F64 and integer maps;
- native Apple Silicon NEON versus scalar and separate-pass modes;
- independent C IEEE reference results, including signed zeros, subnormals,
  overflow, infinities and NaNs (classification for NaN payload differences);
- printing/trapping callback and capture-evaluation order;
- forced chunk fuel exhaustion on four harts, with unchanged results.

The focused suite passed, as did the existing vector-limit and x64 kernel
execution suites. The mixed-kind fixture also executed under RV64 QEMU and
printed `floats=11.5 mixed=12 pipeline=4,38 f32=8`. QEMU execution is not hardware
performance evidence. No QOS SDK pin was changed in this backend slice.

## Measured map workload

`python3 bench/vector-kernels.py --output /tmp/vector-kernels.json` reproduces
the benchmark. The retained result is
`bench/2026-10-04-vector-kernels.json`. It uses 500,000 F64 elements, one hart,
one warmup and nine interleaved samples per mode, checking the same checksum.
Construction and the subsequent ordered reduction are outside the timed region.

On this macOS arm64 host the median map times were:

| Mode | Median microseconds |
|---|---:|
| Fused NEON | 193 |
| Fused scalar | 2,025 |
| Separate scalar passes | 1,934 |

NEON is approximately 10 times faster than the two-pass scalar reference for
this particular workload. Scalar fusion alone is slightly slower here, despite
one fewer pass: normalization and register/frame costs still matter. These
figures are host observations during development, not general speed or WCET
claims, and are not a performance threshold in the regression suite.

The complete Base suite passed after the compiler changes, including the eight
ideal examples, typing/layout refusals, specialization differentials, admission
rollback, descriptor widths through 128 fields, x64 execution and runtime actor/
network/failure paths. The historical Bool-capture fixture label now describes
its checked unboxed path; its updated fixture output was verified separately.
