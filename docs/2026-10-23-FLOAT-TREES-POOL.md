# Comparison trees, F32 trees and the hosted AArch64 FP pool

Implemented in `fprisc-typed-ir-next` from
`ae507dc58fda0073b6e95445dc6211d802f7ca9e`. This follows the
[F64 tree pass](2026-10-23-TYPED-IR-PERF.md).

Comparison operands and F32 arithmetic now form trees on AArch64, x86-64
and RV64. Hosted AArch64 additionally allocates FP registers across
calls and actor safepoints. In 31 paired rounds, the pool reduced nbody
wall time by about 10%; F32 trees reduced the targeted loop's internal
time by 0.8%. The comparison-chain loop showed no measurable speedup.
The full Base suite passed all 112 jobs.

## Tree contract

`OFloatCmpTree`, `OFloat32Tree` and `OFloat32CmpTree` extend the existing
`OFloatTree`. A definition can be absorbed only when its result has one
use across the whole function and that consumer is in the same block.
F64 and F32 candidates are separate. A call, safepoint, store or other
non-pure operation clears the candidates.

Each arithmetic node retains its operation, operand order and precision.
There is no reassociation or FMA contraction. F32 rounds at every node,
as before. Comparisons retain ordered semantics, including unordered
NaN inequality. A tree exceeding the eight-register scratch budget stays
split. Comparison trees keep the left root in scratch 0 while evaluating
the right in scratch 1 and above.

The selected stream still represents one arithmetic instruction per step,
with bounded integer reload pressure. Scratch banks are `d16..d23` /
`s16..s23`, `xmm8..xmm15`, and `ft0..ft7`. In the structural oracles, the
F64 comparison has seven input moves instead of eleven total moves; the
F32 arithmetic chain has six moves instead of twelve.

## AArch64 allocation and context contract

The selected pass promotes proven FP arithmetic results into an FP
virtual-register class. The shared allocator respects classes, uses
matching spill scratch registers, and admits an FP bank only when a
target supplies one. AArch64 uses preserved `d8..d15`, caller-saved
`d2..d7`, and spill scratch `d0/d1`. Tree and SIMD scratch remain disjoint.
FP spills contain raw bits and are excluded from managed-value scanning.

Parameters, block parameters and foreign results retain the word ABI.
Word consumers receive bit-preserving moves that retain fixed-register
constraints, including return and call argument registers. This avoids
changing the language's calling convention. Values live across a call or
safepoint must use preserved registers or frame slots.

Hosted `ctx_a64.S` now saves and restores `d8..d15`. Since the larger
scheduler context shifts later hart fields, hosted AArch64 uses:

| Contract | Hosted AArch64 | AArch64 QOS apps |
|---|---:|---:|
| Context words | 24 | 16 |
| Native runtime ABI | 7 | 6 |
| Module interface revision | 16 | 15 |
| FP pool | enabled by default | excluded |

Hosted runtimes and modules must be rebuilt together. Module admission
and cache identities distinguish the new contract. QOS compilation and
assembly use `FPR_QOSAPP` and retain their existing context layout; this
pass does not change QOS's scheduler. Other architectures retain their
existing ABI and allocation behavior.

`FPR_TYPED_IR_FP_POOL=0` disables the hosted pool for diagnostic and
paired comparisons. Both unit and executable cache keys include the mode.
The generator revision is 72; selection revisions are A64 21, x64 20,
RV 14. Disabling the pool does not revert the runtime context layout.

## Correctness evidence

The [final Base log](evidence/2026-10-23-float-next/base-final.log) records
112/112 successful jobs, exit 0, using four workers. New checks include:

- Independent volatile-C arithmetic and six comparison predicates for
  F64 and F32: 5,427 edge/random triples per precision, executed on native
  AArch64, x64 under Rosetta, and RV64 under QEMU. The oracle includes
  NaNs, infinities, signed zero and random raw bits. Compilation disables
  FMA contraction; emitted assembly is checked for its absence.
- A direct context-switch oracle, 10,000 round trips, with distinct raw
  values in every register `d8..d15`. Removing the FP save/restore
  instructions makes the same oracle fail, providing a negative control.
- Generated code with twelve FP values live across forced fuel exhaustion,
  recursive calls and stack checks, exercising FP spills. Two actors
  produce `162000 168000` with both one and four harts.
- IR fusion and scratch-budget checks, register-class allocation checks,
  existing float, kernel, module, ABI/cache and compiler regression checks.

Focused final logs are
[tree oracles](evidence/2026-10-23-float-next/tree-oracles-final.log),
[pool/context oracles](evidence/2026-10-23-float-next/pool-oracles6.log), and
[IR units](evidence/2026-10-23-float-next/typed-ir-unit2.log).
The evidence directory retains exploratory failure logs with their original
names; only the identified final logs are successful validation records.

The ARM host skips execution requiring a matching native Linux x64
runtime. Apple's clang cannot produce the POSIX RV64 artifact for that
existing test, which skips; separate RV64 tree/kernel QEMU checks run.
No hosted CI, physical QOS/P4, x64 pool or RV64 pool validation is claimed.

## Paired performance evidence

The driver alternates three variants in 31 rounds on one macOS AArch64
host with one hart:

- `baseline`: preserved compiler at the starting revision.
- `typed-ir-trees`: new compiler with `FPR_TYPED_IR_FP_POOL=0`.
- `typed-ir`: new compiler with the hosted pool enabled.

All three compile against the **same new runtime/context sources**.
These measurements isolate compiler changes. They do not measure the
additional FP saves/restores against the old integer-only context.
The separate direct-switch measurement below covers that instruction cost;
scheduler-heavy throughput and hart-layout cache effects remain unmeasured.
Background load and CPU frequency are not controlled.

Ratios below are medians of paired new/old times; lower is faster.
Intervals are 95% paired bootstrap intervals.

| Change and workload | Timer | Ratio | 95% interval | Faster rounds |
|---|---|---:|---:|---:|
| Trees vs baseline: comparison chain | internal | 1.0009 | 0.9991..1.0026 | 12/31 |
| Trees vs baseline: F32 chain | internal | 0.9916 | 0.9895..0.9928 | 29/31 |
| Trees vs baseline: nbody | wall | 1.0010 | 0.9998..1.0017 | 11/31 |
| Trees vs baseline: floatcmp | wall | 1.0031 | 1.0004..1.0046 | 9/31 |
| Pool vs trees: nbody | wall | 0.9007 | 0.8997..0.9013 | 28/31 |
| Full change vs baseline: nbody | wall | 0.9009 | 0.9002..0.9022 | 30/31 |
| Full change vs baseline: F32 chain | internal | 0.9892 | 0.9887..0.9916 | 27/31 |
| Full change vs baseline: comparison chain | internal | 1.0003 | 0.9987..1.0023 | 13/31 |

The trees-only floatcmp result is a small 0.3% regression in this run;
the full change's interval includes parity. The integer controls mostly
remain near parity. Fib's full-change internal ratio is 1.0237 with an
interval of 0.9967..1.0531, so this run does not establish a regression.
No x64/RV64 timing, energy, or scheduler-throughput result is implied.

[Raw rounds](evidence/2026-10-23-float-next/paired-results.json),
[all comparisons](evidence/2026-10-23-float-next/paired-summary.md),
[pool-only paired statistics](evidence/2026-10-23-float-next/pool-vs-trees.json),
[compiler identities](evidence/2026-10-23-float-next/metadata.json), and
[measured source patch](evidence/2026-10-23-float-next/measured-source.patch)
are retained. Final changes after measurement comprise test/documentation
work and production comments; the measured and final compiler hashes are
recorded separately.

Reproduction (preserve a clean starting-revision compiler first):

```sh
PKG_CONFIG_PATH=/opt/homebrew/opt/libarchive/lib/pkgconfig \
python3 -u tools/bench-typed-ir-m3.py \
  --output /private/tmp/fpr-float-next-paired \
  --against /private/tmp/fpr-float-next-baseline \
  --variants baseline,typed-ir-trees,typed-ir \
  --workloads cmpchain64,f32trees,nbody,floatcmp,fib,sum,pipeline,helpers,sha \
  --runs 31
```


## Context-switch cost

A separate 31-round paired run of `tools/bench-a64-context.py` measures
10 million round trips per sample. It compares the current FP-preserving
sequence with the integer-only sequence selected by `FPR_QOSAPP`, using
identical 24-word storage in both variants. There are no FP calculations
in the switch loop, and both variants warm up before timing.

| Direct hot switch | Median ns per switch |
|---|---:|
| Integer-only sequence | 5.8158 |
| d8..d15 save/restore sequence | 6.8309 |

The median paired ratio is 1.1744 (95% bootstrap interval
1.1731..1.1756), with **1.0147 ns extra per switch**. This is a 17.4%
increase in the isolated routine, not in total actor or application time.
It excludes scheduler work, GC, migration and hart-layout cache effects.
The independent correctness and negative-control tests above establish
that preserving these registers is required once the pool is enabled.

[Raw context rounds](evidence/2026-10-23-float-next/context-paired-results.json)
and the [run log](evidence/2026-10-23-float-next/context-paired.log) are retained.

```sh
python3 -u tools/bench-a64-context.py \
  --output /private/tmp/fpr-float-context-paired --runs 31
```
