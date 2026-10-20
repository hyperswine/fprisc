# Typed IR M1: worker metadata and Bool correctness repairs

Date: 2026-10-21. Kind: implementation and validation record.
Applies to: changes following `f9cd965`, codegen revision 67.
Status: implemented; native IR selection remains pending.

This closes the two worker-signature findings and the separate native Bool
discrepancy in the [review](2026-10-21-TYPED-IR-REVIEW.md). The
[plan](2026-10-20-TYPED-NATIVE-IR-PLAN.md) now incorporates those findings,
and the [M0 register](2026-10-21-NATIVE-IR-CONTRACTS.md) records the remaining
runtime and backend obligations.

## Ordered signatures come from the producer

`Workers.workerizeWithSignatures` returns the transformed program, notes and
the ordered scalar signatures already established by `signatureStrict` when
workers are selected. The original `workerize` API remains as a wrapper for
consumers that do not need metadata.

`Codegen` carries that map alongside normalization/reuse and passes it into
`Codegen.Lower.lowerProgram`. The separate body-based inference algorithm was
removed. This fixes alphabetical reordering of parameters and the incorrect
inference that operands of Boolean equality must be raw integers. It also
handles local aliases without rediscovering their types from rewritten Core.

Definitions and calls to scalar workers with missing representation metadata
now decline explicitly. A worker with a mismatched metadata arity also
declines. Callers cannot silently assume the public all-tagged ABI for an
unknown private worker. The actual worker ABI is unchanged.

## Native Bool discrepancy: two different sets of immutable objects

The native `$scalar.==`/`!=` operations compare raw words. Worker wrappers
normalize Bool arguments using `CMk 1 0/1 []`, but the Base emitter previously
loaded a module-local `.Lnul_1_*` object for those constructors. Inline
comparison results loaded `fpr_false`/`fpr_true` from the runtime instead.
Thus two true values could have different addresses even after normalization.

Base Bool constructor emission now loads the runtime singletons too. It is
still one address load, with no allocation or extra runtime call. All other
nullary constructors, and builtin-profile local constructor emission, retain
their existing paths. Codegen revision 67 invalidates cached generated code
for this native correctness change. `FPR_TYPED_IR` remains diagnostic and
does not change emitted assembly.

## Regression coverage

`tests/TypedIR.hs` now runs the actual worker producer and tests:

- Mixed Int/Bool parameters with both alphabetical and reverse-name ordering.
- Correct results for both Bool values through the wrapper and worker.
- Boolean equality through a local alias, with producer-owned signatures.
- Explicit refusal of missing signature metadata at worker and wrapper.
- Refusal of worker definitions and calls with malformed signature arity.

`tests/typed_ir/scalar.fpr` adds recursive equality and inequality workers
comparing an incoming Bool with a comparison-produced Bool. `boolResult`
combines both answers into a numerical oracle: true input must produce `10`,
false input `1`.

`tests/check_typed_ir.py` checks that oracle independently for three recursion
depths and three input flags, with scalar workers off/on/off/on using the
build cache. It also compares eleven evaluator results/traps with native
results, checks portable a64/x64/rv64 dumps, and verifies that the report does
not alter assembly. Fixture coverage is now 14/22 functions; this is a
different fixture from the original 9/16 and is not a corpus improvement ratio.

The existing worker suite separately exercises foreign Bool objects, one/four
worker execution, inliner/worker combinations, exact arithmetic traps,
allocation counts, large-stack behaviour, target emission and an optimized
shared module called from a general-ABI host.

## Validation record

- `make fpr`: passed after granting access to Cabal's existing external log.
  The initial sandbox denial happened after linking; it was not a source error.
- `python3 -u tests/check_typed_ir.py`: passed.
- `python3 -u tests/check_workers.py`: passed.
- `tests/check_base.py` passed its initial sections through the safety
  allow-list, then stopped because `check_specialization.py` could not locate
  Homebrew's `libarchive` pkg-config metadata in its fresh-cache environment.
  The continuation supplies the same `PKG_CONFIG_PATH` as the Makefile and
  resumes at specialization, preserving the original test body below it.
  Specialization, workers, wide workers and every remaining Base assertion
  passed on retry (exit 0). Coverage completed across the initial run and
  continuation, rather than one uninterrupted invocation.
- One expected skip: the POSIX RV64 artifact check could not run because
  local Clang has no RISC-V backend. Separate x64/RV64 QEMU self-loop checks
  passed; that does not replace the skipped artifact check.
- `git diff --check` and local documentation links/fenced blocks: passed.

The initial broad run and final focused run have separate compiler hashes in
[`base-compiler.json`](evidence/2026-10-21-typed-ir-repairs/base-compiler.json)
and [`final-compiler.json`](evidence/2026-10-21-typed-ir-repairs/final-compiler.json).
Between them, a defensive malformed-call-metadata arity refusal was added to
diagnostic lowering. Native emission did not change. The final focused suite
checks that refusal; the broad continuation uses the final compiler too.
The [evidence directory](evidence/2026-10-21-typed-ir-repairs/README.md)
contains both Base logs, focused logs and reproduction details.

The focused suites used macOS AArch64 execution. a64/x64/rv64 portable dumps
and target assembly checks do not establish native execution of the new IR
on those targets. No new native backend exists yet. No performance, energy,
QOS deployment or physical-board claim is made by this repair.

## Next implementation boundary

M0 now records Core coverage, scalar signatures, call conventions, target
constraints, profile-specific roots, and a bounds migration strategy. In
particular, actor stacks add segments without relocating live frames, and
A64 scheduler context does not preserve floating-point registers as ordinary
C calling-convention reasoning might suggest.

M2 starts with explicit target/profile policy and a selected-instruction
structure exposing temporaries, constraints, flag dependencies and slow-path
call clobbers. Then conservative A64 emission can be implemented and compared
against independent oracles. x86 execution, bounds analysis, cache selection
and legacy/new ABI interoperability remain acceptance gates.
