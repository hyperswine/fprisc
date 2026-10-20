# Review of the revised native IR plan and initial implementation

Date: 2026-10-21. Kind: review / status report.
Reviewed revision: `f9cd96552a9b138fdf940b479f13e17818cefe5d`, compared with
`c328232`. Scope: revised plan, five new Codegen modules, integration and tests.
Status at reviewed revision: two confirmed issues in worker-convention recovery,
plus a separate native scalar-worker discrepancy. Resolution is recorded in
[M1 repairs](2026-10-21-TYPED-IR-M1-REPAIRS.md); this review preserves the
original findings and evidence.

## Findings in the initial implementation

### P2: Boolean equality operands are inferred as raw integers

Location: [Lower.hs](../compiler/Codegen/Lower.hs), `workerSignatures.demands`,
lines 167–170 at the reviewed revision.

Every `$scalar.*` binary operation contributes `KInt` demands for its direct
parameter operands. This includes `$scalar.==` and `$scalar.!=`, although
scalar workers also compare Bool objects. The existing worker pass preserves
the Bool representation and uses equality on normalized objects.

The retained [source fixture](evidence/2026-10-21-typed-ir-review/bool-equality.fpr)
contains a recursive `boolEq n b` whose base case is `b == (n < 1)`.
Through the normal compiler pipeline, the new IR reports the worker, wrapper
and `run` as lowered. Its verifier accepts the program, but the worker entry
has two `TInt` parameters instead of `TInt, TVal`. Evaluating `run 2` stops with:

```text
typed-ir: eval run 2 stuck: untag of an object RObj 1 1 [] (2 safepoints, 2 calls)
```

This is a valid scalar program for which the accepted IR does not model
execution. It is currently a reporting/evaluator defect: native emission is
still the legacy path. It must be repaired before native selection consumes
these signatures.

Recommended correction: carry the ordered representation signature already
established by `Workers.scalarWorkers` into IR lowering. If recovery remains,
equality must constrain its operands to compatible representations without
assuming integer operands, and conflicting/unknown evidence must remain an
explicit unresolved state. Add mixed Bool/Int equality and inequality cases
through the real compiler pipeline, including recursive workers.

### P2: Signature recovery changes parameter order

Location: [Lower.hs](../compiler/Codegen/Lower.hs), `workerSignatures.finish`,
lines 160–163 at the reviewed revision.

`M.elems pk` enumerates parameters in name order, whereas calls and entry
blocks use the source Core parameter list. A worker with parameters
`["z", "a"]` and representations `[TInt, TVal]` is assigned `[TVal, TInt]`.
Integer-only fixtures cannot detect the permutation.

The retained [Core probe](evidence/2026-10-21-typed-ir-review/WorkerReview.hs)
uses the actual `Workers.workerize` pass, then `lowerProgram`. It reports the
wrong ordered signature for `$worker.scalar.mixed`, refuses the worker with
`a TInt where a TPred is needed`, accepts the wrapper, and the wrapper's
evaluation attempts to untag a Bool. See the
[captured output](evidence/2026-10-21-typed-ir-review/worker-review.txt).

Scope qualification: this probe calls lowering on valid Core directly.
The ordinary source pipeline's generated positional parameter names masked
this particular ordering bug in the source fixture checked here. It is still
an incorrect assumption in the lowering API, and no invariant in that API
requires alphabetically ordered parameters.

Recommended correction: retrieve each parameter's representation in the
original `ps` order, or pass the worker pass's ordered signature directly.
Test equivalent functions with renamed and reordered mixed-type parameters.

## Separate native discrepancy found by the review

The same Boolean-equality source fixture also gives different native results
when scalar workers are enabled and disabled:

| Execution at reviewed revision | Observed result |
|---|---|
| Legacy native backend, default scalar workers | `0` |
| Legacy native backend, `FPR_NO_SCALAR_WORKERS=1` | `1` |
| New IR reference evaluator, scalar workers enabled | `Stuck`: untag of Bool object |

The source's `run 2` should return `1`: the recursion reaches `n == 0`
with `b` true, and compares it with `0 < 1`. The native discrepancy merits
high-priority investigation independently of M2. Its root cause was not
isolated in this review. The worker transformation and native instruction
implementations are unchanged by `f9cd965`; do not attribute this native
behaviour to the new diagnostic IR path.

This is also a concrete reason to retain independent semantic cases alongside
legacy/new differential tests. Agreement with a legacy result alone cannot
establish correctness.

## Assessment of the revised plan

The reduced scope is reasonable: A64 first, x86 inside M2, conservative
placement before allocation, explicit coverage accounting, and a decision
about further backend investment after M3. The current implementation keeps
physical register and frame choices out of the portable representation and
leaves emitted code unchanged.

Before continuing, tighten these points in the plan:

1. **Make worker conventions an explicit M0 deliverable.** The producer
   already knows them; reconstructing them in another pass has now caused
   two defects. A missing signature for an internal worker must not silently
   become an all-`TVal` signature in `calleeOf`, particularly when calls to
   legacy fallback functions are introduced.
2. **Clarify the selected-instruction representation.** The pipeline still
   says “machine IR” while the prose says one IR. A small selected-instruction
   structure is sufficient, provided allocation sees every introduced
   temporary, fixed/tied operand, flag dependency and call clobber. The design
   should specify that information flow without making the number of IRs an
   architectural restriction. `Frame.hs` should not become the owner of all
   instruction-selection constraints just because another module was removed.
3. **Finish the runtime inventory before M2 emission.** The report explicitly
   says M0's register page is unwritten. Roots, stack relocation, call shapes
   and bound provenance remain prerequisites for correct native code, even
   if M0 is kept small. The present lowering inserts stack checks and ticks
   without receiving target/profile policy; M2 must make that policy explicit.
4. **Distinguish a performance decision from a timing cutoff.** The M3 kill
   criterion is useful as a review point. Require repeatable evidence and
   uncertainty assessment; one 2% median boundary should not decide whether
   an architecture is worthwhile. Maintainability, compile time, code size
   and target-specific results should remain visible in that decision.
5. **Correct the evidence wording and milestone status.** The plan says
   “All stages are pending” beside completed M1 tasks. The M1 page/test output
   also say tick counts agree with the legacy binary. The Python test compares
   native results/traps, but checks evaluator tick counts against constants;
   it does not observe native fuel counters. That is useful structural
   evidence, not measured native tick-count parity. Target-independent dumps
   likewise demonstrate portable lowering, not execution on three backends.

## Fresh validation and reproducibility

`python3 -u tests/check_typed_ir.py` passed at the reviewed revision:

- Nineteen verifier refusals and the handwritten Core tests passed.
- The scalar fixture reported 9/16 functions lowered for a64/x64/rv64.
- Nine evaluator results/traps agreed with the native legacy fixture.
- Dump determinism and report-on/report-off assembly parity passed.
- RV32 explicitly reported that M1 lowering is unavailable.

The first attempt was stopped by sandbox access to the existing compiler
cache. Rerunning with that filesystem access passed. This was an environment
failure, not an implementation failure.

From the repository root, reproduce the extra Core cases with:

```sh
cabal exec -- runghc -w -icompiler docs/evidence/2026-10-21-typed-ir-review/WorkerReview.hs
```

Reproduce the source-pipeline and native cases with:

```sh
FPR_TYPED_IR='dump eval:run:2' ./fpr --target=a64 --prelude=core/prelude.fpr docs/evidence/2026-10-21-typed-ir-review/bool-equality.fpr /tmp/typed-ir-review.s
./fpr build docs/evidence/2026-10-21-typed-ir-review/bool-equality.fpr -o /tmp/typed-ir-review-default
/tmp/typed-ir-review-default
FPR_NO_SCALAR_WORKERS=1 ./fpr build docs/evidence/2026-10-21-typed-ir-review/bool-equality.fpr -o /tmp/typed-ir-review-no-workers
/tmp/typed-ir-review-no-workers
```

No full `check_base.py`, Linux native execution, QOS or board validation was
run for this review. No native speed improvement is established by M1.

Recommended order: repair and test worker-convention handling, investigate
the native Boolean discrepancy, complete the remaining M0 contracts, then
start conservative A64 selection with the planned x86 operand constraints.

## 2026-10-21 follow-up

The [M1 repairs](2026-10-21-TYPED-IR-M1-REPAIRS.md) address both signature
findings and identify/fix the native Bool cause. The reproduction source and
captured output above remain the reviewed `f9cd965` evidence; the old Core
probe uses that revision's lowering API. Current automated regressions are
in `tests/TypedIR.hs` and `tests/check_typed_ir.py`.
