# Typed record and SoA kernels

Date: 2026-10-22. Base: `6951653`, branch `typed-ir-retire`.
The scalar kernel increment was committed and pushed before this work.
This extends [typed column kernels](2026-10-22-TYPED-COLUMN-KERNELS.md) under
[the current retirement acceptance](2026-10-20-TYPED-NATIVE-IR-PLAN.md#current-retirement-acceptance-2026-10-22).

## Implementation

`Codegen.Kernel.lowerRecordKernel` builds ordinary typed CFGs for record
map, filter and fold. The existing planner supplies its projection-based
Core callbacks; those callbacks use the same lowering, verification,
simplification, allocation and direct target selection as scalar functions.
There is no architecture-specific assembly in the builder. The shared cache
revision is 71; no new target instruction selection was needed.

- Record maps, including captured record/matrix-vector forms, load the
  original row's columns and calculate every output before storing any.
  Cross-field expressions therefore observe the original row. Compatible
  record-map composition already recognized by the planner is preserved.
- Record folds load only the columns their callback reads. Scalar captures
  and accumulator representations remain independent. The returned pair
  retains the original vector, including its length and contents.
- Record filters compact every column, including boxed/F32/F64 columns the
  predicate never reads. A dynamic inner loop supports arbitrary widths;
  it has a safepoint so its instruction segment remains bounded. Compaction
  preserves order and skips copies when read/write positions are equal.
- Representation, optional element shape, minimum column count, scalar
  capture/seed and used-column kind guards run before data access. Empty
  vectors do not dereference the column directory. Large column indices
  use address indexing rather than exceeding the IR load-offset limit.
- A failed guard invokes the original boxed callback through the generic
  runtime. Checked integer arithmetic keeps vector overflow diagnostics.
  Non-moving storage across safepoints is the existing hosted/QOS contract.

The planner still determines eligibility: this work does not turn arbitrary
record callbacks into specialized kernels. A callback outside its numeric
fragment continues through the generic runtime. Fallback is distinct from
emitting a legacy assembly kernel.

## Support and retirement boundary

| Feature | A64 | x86-64 | RV64 | RV32 |
|---|---|---|---|---|
| Int record maps, captured record maps, SoA folds | Typed | Typed | Typed | Typed |
| Int predicates, stable compaction of all columns | Typed | Typed | Typed | Typed |
| Mixed Int/F64 record maps and folds | Typed | Typed | Typed | Generic boxed path; typed builder refuses |
| F32 record arithmetic | Legacy | Legacy | Legacy | Generic boxed path |

`FPR_TYPED_IR_STRICT=all` accepts the supported fixture units with the
`# typed IR: no translation` marker and no `fpr_ufn_` clones. The record builder
explicitly refuses RV32 float columns. The source planner normally declines
such specializations earlier, retaining the generic boxed runtime path; this
is not itself a legacy-kernel refusal in strict-mode diagnostics. RV32 float
literals can independently require legacy scalar lowering.

The backend remains opt-in. Legacy record emitters still serve the default
backend, F32/RV32-float cases and excluded profiles. Their deletion is not
safe yet. `Vec.mapAs`, write-back fold variants, NEON/RVV specialization and
remaining profile/module contracts are still on the migration list. The typed SoA fold uses the CPU path; the legacy GPU pair-sum dispatch hook
has not been ported. Explicit RVV mode retains legacy kernels. GPU dispatch
and SIMD acceleration are unsupported typed features, not claims of parity
in accelerated performance.

## Validation and evidence

The extended `tests/check_typed_ir_kernels.py` is already registered in Base
and the Linux CI typed stage. It covers:

- Native A64 hosted execution with one and four harts, integer and mixed
  Int/F64 records, strict selection and actual allocation/runtime behavior.
- x86-64 Rosetta and RV64/RV32 QEMU: 1,500 independent integer reference
  cases per target over lengths 0–99, five capture values and widths
  9/64/300; simultaneous/captured maps, stable filter, wide captured fold,
  empty vectors, bad guards, deliberate register-clobbering fuel yields and
  a separate record addition-overflow run.
- A predicate reading column 299, testing both directory indexing and kind
  bytes beyond the IR's fixed displacement range.
- x86-64 and RV64: 500 mixed Int/F64 reference cases per target, including
  captured maps, filters over integer fields that move float columns,
  mixed captured folds, empty inputs and hostile yields.
- Existing hosted record-shape dispatch, generic fallback-frame, vector-kind
  and widths 2/4/8/9/32/65/128 regression checks.

All **106 Base jobs passed** with `FPR_TYPED_IR_BACKEND=mixed`, four test
workers and a private cache. The run completed in two parts: the first 40
jobs passed, then an older assembly-text assertion required the legacy
record-fold comment. Its runtime cases had passed. The assertion now accepts
the typed CFG header as well as the legacy specialization; resuming from
that job passed the remaining 66 jobs in 110 seconds. Compiler sources and
the measured binary were unchanged between those runs. The new kernel suite
executed every target leg; its C oracles did not skip Rosetta or QEMU.

[Prefix log, including the old assertion failure](evidence/2026-10-22-typed-record-kernels/base-prefix.txt),
[successful resumed log](evidence/2026-10-22-typed-record-kernels/base-resumed.txt),
[exact 40 + 66 job manifest](evidence/2026-10-22-typed-record-kernels/base-jobs.json),
[earlier focused record checks](evidence/2026-10-22-typed-record-kernels/focused.txt).

The freestanding RISC-V oracles substitute a small runtime and are not
physical-board or Linux-scheduler validation. Rosetta proves instruction
results, not native Linux timing. GitHub manual dispatch for `6951653` was
rejected with HTTP 403; its last successful ancestor run was `8a5de33`.
The CI push filter now includes `typed-ir-retire` for the next push.

## Paired performance measurement

Apple Silicon, one hart, 100,000 nine-field records, 31 alternating rounds.
The timer covers map, captured map, filter and captured fold; construction,
capture allocation and free are outside it. Every output is checked against
independent arithmetic. The compiler SHA-256 starts `5f21063ec55a`; the raw
record identifies its full hash and the uncommitted working tree.

| Comparison | Legacy median | Typed median | Median paired ratio | 95% bootstrap interval |
|---|---:|---:|---:|---:|
| Default legacy | 10.007 ms | 8.724 ms | 0.8700 | 0.8681–0.8873 |
| Legacy optimization opt-ins (`legacy-best`) | 10.511 ms | 8.724 ms | 0.8315 | 0.8132–0.8402 |

This workload is about **13% faster than default legacy**, winning 30/31
pairs. The historical `legacy-best` switch combination is slower than default
on this particular workload; typed is about 17% faster than that combination.
The root has 12 source functions, four kernels and 20 callback clones emitted
natively, with no legacy functions. This is one CPU workload on one host;
it does not establish native x86/RISC-V, GPU, SIMD or energy performance.

[Raw measurements](evidence/2026-10-22-typed-record-kernels/results.json),
[generated summary](evidence/2026-10-22-typed-record-kernels/summary.md).
Reproduce with:

```sh
python3 tools/bench-typed-ir-m3.py --output /tmp/typed-record-measurement \
  --variants legacy,legacy-best,typed-ir --workloads records --runs 31
```

## Remaining work

1. Lower layout-changing `Vec.mapAs` and the remaining write-back fold
   variants, preserving allocation, ownership and source failure order.
2. Add F32 column representation handling and typed SIMD, while retaining
   measured NEON/RVV fast paths until replacements are validated. Port the
   optional GPU pair-sum dispatch hook with its own execution evidence.
3. Finish the required QOS hart access and RV64 module/profile consumers.
4. Promote supported paths with a rollback option and complete platform
   CI, then delete translators only where their remaining consumers are gone.
