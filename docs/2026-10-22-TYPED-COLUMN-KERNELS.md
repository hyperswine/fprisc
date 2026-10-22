# Typed column kernels: first retirement increment

Date: 2026-10-22. Base: `8a5de33`, branch `typed-ir-retire`.
This record supersedes the statement that all vector kernel bodies are legacy
in the [retirement inventory](2026-10-22-TYPED-IR-RETIREMENT.md).

Update after `6951653`: [typed record/SoA kernels](2026-10-22-TYPED-RECORD-KERNELS.md)
now cover the numeric record map/filter/fold plans. The evidence and table
below describe the first scalar-column increment.

## Acceptance for the remaining migration

The requested acceptance criterion is working major features on AArch64,
RV64, RV32 and x86-64, with unsupported features explicitly recorded. Retire
legacy paths per supported target/profile as that evidence becomes available.
An unsupported bare-metal profile does not prevent retiring a hosted path;
it remains an explicit legacy consumer. Performance is measured and material
regressions are reported. Hardware execution, hosted runtime execution and
instruction oracles are different evidence and must be labelled separately.

The typed backend remains opt-in during this increment. The new kernel route
is automatic when that backend is selected; no additional experimental switch
is needed. The default and the translator modules have not been removed.

## Implemented

`Codegen.Kernel` builds ordinary typed control-flow graphs for scalar map,
filter and fold, and fused map/filter/fold pipelines over a single column.
The same CFG is verified, simplified, selected, allocated and rendered by the
AArch64, x86-64, RV64 and RV32 backends. It contains no target registers or
assembly snippets. Supported kernel bodies and their callback clones no
longer pass through the RISC-V text generator or the assembly translators.

New memory operations distinguish a tagged value from an address, index an
address by the target's word size, and load/store an explicit representation.
Byte loads read the column-kind descriptor. Mutable loads have a `Reads`
effect and stores have `Writes`, preventing pure-expression sharing or dead
pure elimination from treating them as immutable. The verifier checks operand
and result representations, portable displacements and word alignment.

Object/representation, capture and column-kind guards precede every column
access. Empty columns need no directory or element pointer. Filter compaction
is stable and in place; a standalone fold leaves its column unchanged. A
failed guard reconstructs the original boxed callbacks and runs the generic
runtime operations in source order. Floats retain their IEEE bits as values;
RV32 float columns continue through the existing boxed path.

Small callbacks inline as typed blocks, including their branches and fuel
ticks. Helpers, recursion, large callbacks and the pipeline no-inline switch
use typed callback clones with the generated-code calling convention. Clones
preserve kernel-specific overflow and zero-divisor traps through nested calls.
`OKernelArith` selects checked native arithmetic, including RV32/RV64 high-half
multiplication checks, rather than changing the runtime ABI or panic text.
Kernel loops retain bounded safepoint segments. Invalid IR/selection is a
compiler error; supported-target refusals remain named legacy fallbacks.

A unit containing only native functions and these native kernels now starts
`# typed IR: no translation`. Each specialization reports either
`typed-ir-kernel: <symbol> native` or a specific `legacy: <reason>`.
`FPR_TYPED_IR_STRICT=all` includes kernel fallbacks, so it cannot report full
native coverage while silently retaining a legacy kernel.
Cache identities changed for the shared generator and all direct selectors.

## Support boundary

| Feature | This increment |
|---|---|
| Int single-column map/filter/fold and fused pipelines | Typed on all four targets |
| F64 single-column kernels and pipelines | Typed on the 64-bit targets, except retained SIMD map candidates |
| Int/F64/Bool captures, captured fold seed, wide pipeline arguments | Typed; existing argument cells/spills and verifier apply |
| Mismatched or boxed vector layout | Guarded generic runtime fallback; no legacy assembly required for that fallback |
| F32 kernels | Legacy, explicitly reported |
| Record SoA folds/filter compaction, record maps and matrix-vector kernels | Legacy, explicitly reported |
| `Vec.mapAs`, write-back fold variants | Legacy, explicitly reported |
| Existing NEON map candidates | Retained until equivalent typed SIMD lowering is validated |
| Explicit RVV mode | Legacy kernels retained |
| Builtin/ARC, ESP-IDF, x86/RISC-V QOS apps, RV64 modules | Existing profile exclusions remain; see retirement inventory |

The Core evaluator deliberately does not model unmanaged column storage.
Verifier tests and independent executable C oracles cover these operations;
ordinary typed arithmetic and control-flow evaluator tests remain in place.

## Validation

Focused execution on this Apple Silicon Mac:

- Native AArch64 hosted Int/F64 pipelines, F32 legacy compatibility, boxed
  fallback, eight arguments, exact compaction/results, effects and failure
  order, with one/four harts and callback inlining enabled/disabled.
- x86-64 under Rosetta, RV64 and RV32 under QEMU: 700 independent C reference
  cases each, plus separate add overflow, wide multiply overflow, minimum
  Int divided by -1, and zero-divisor runs. Fuel yields deliberately clobber
  argument and temporary registers. RISC-V harnesses are freestanding runtime
  substitutes, not proof of a Linux scheduler or a physical board.
- Five kernel CFGs (including division) emitted with no legacy assembly on
  all four selectors; the primitive/float coverage suite also passes.
- Existing Int overflow tests pass with the typed backend, retaining the
  exact kernel diagnostic. IR verifier/evaluator checks pass.

The complete Base suite passed **106/106 jobs in 409 seconds**, with
`FPR_TYPED_IR_BACKEND=mixed`, four test workers, a private cache and Homebrew's
libarchive pkg-config path supplied. This run preceded the final one-line
emission fix: a unit with no native scalar functions must still append native
kernels referenced by its legacy callers. `tests/KernelIR.hs` reproduces this
boundary across all four selectors. After that fix and the cache bump to
`codegenRev` 70, the complete kernel suite, float/kernel coverage suite and
three focused Base jobs (`intovf`, `vecfuse`, `veccaps`) passed again.
[Base log](evidence/2026-10-22-typed-column-kernels/base.txt),
[final kernel log](evidence/2026-10-22-typed-column-kernels/kernels.txt),
[final coverage log](evidence/2026-10-22-typed-column-kernels/coverage.txt),
[final focused log](evidence/2026-10-22-typed-column-kernels/focused.txt).

Strict mode accepts the five supported kernel CFGs without translation on
all four targets and refuses an unsupported F32 kernel with its reason.
Native Linux CI and the full QOS suite have not been rerun for this increment;
no physical-board validation or native x86/RISC-V performance is claimed.
Four existing tests now explicitly select legacy only when inspecting or
extracting legacy assembly (`check_vector_kinds`, `check_vector_pipelines`,
`check_vector_fallback_frames`, `check_x64_vectors`). Their hosted behavior
checks retain the selected backend; the new kernel oracle checks direct
emission and execution independently.

The new `tests/check_typed_ir_kernels.py` is part of the Base suite and the
Linux CI typed-backend stage. CI requires x86-64 and both RISC-V execution
legs instead of accepting an unavailable-tool skip.

## Performance on the final build

Apple Silicon, one hart, one million elements, 31 alternating paired rounds,
construction/free excluded from the internal timer, every output checked.
Compiler SHA-256 starts `2c0b4e862440`; the raw record identifies the full
binary hash, flags, uncommitted working tree and platform. The revision field
is the base commit, not a claim that these changes are already committed.

| Comparison | Legacy median | Typed median | Median paired ratio | 95% bootstrap interval |
|---|---:|---:|---:|---:|
| Default legacy | 3.090 ms | 2.641 ms | 0.8567 | 0.8213–0.8971 |
| Best legacy opt-ins | 3.007 ms | 2.641 ms | 0.8968 | 0.8485–0.9180 |

Against the best legacy settings the fused pipeline is about **10% faster**
(28/31 faster pairs). Process wall time improves about 4% by paired ratio.
This is one workload on one host, not an across-the-board speedup or energy
measurement. The earlier measurement before the final emission fix also
favoured typed kernels by about 11%; neither run establishes native x86 or
RISC-V timing. Existing NEON maps remain selected to preserve their current
performance until typed SIMD is ready.

[Raw measurements](evidence/2026-10-22-typed-column-kernels/results.json) and
[generated summary](evidence/2026-10-22-typed-column-kernels/summary.md).
The summary's eight native root entries include four source functions, one
kernel and three callback clones. Reproduce with:

```sh
python3 tools/bench-typed-ir-m3.py --output /tmp/typed-kernel-measurement \
  --variants legacy,legacy-best,typed-ir --workloads pipeline --runs 31
```

## Next removal steps

1. Lower record SoA operations, `mapAs` and write-back folds through typed
   memory operations, preserving wide-column and ownership checks.
2. Add typed SIMD operations and selection for the currently retained NEON
   and RVV kernels; keep scalar differential execution for each form.
3. Complete x86/RISC-V QOS hart access and RV64 module emission where those
   profiles are required. List remaining unsupported profiles explicitly.
4. Promote the supported typed paths with an explicit legacy rollback, run
   their complete platform suites, then remove translator consumers that
   have no remaining supported use. Retain the RISC-V generator only for
   the documented unmigrated profiles until their contracts are implemented.
