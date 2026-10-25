# Typed closure lifting and fallthrough joins

Date: 2026-10-25. Kind: implementation and validation record.
Applies after structured diagnostics at `c323657`.

Covered native typed functions now pass through closure and join conversion
before erasure. Their generated functions retain checked parameter/capture
types, ownership shapes and unique binder identities. The
[full cleanup goal](2026-10-25-COMPILER-CLEANUP.md) remains active: this moves a
real transformation across the boundary, but layout temporaries and subsequent
optimization/region/backend passes still need migration.

## Typed code and capture contracts

`Core.Typed.Syntax` distinguishes code identities, closure code and join code.
`ClosureValue` references a code identity and lexical captures; `JoinCall` is a
direct continuation call. Code contracts keep capture **schemes** separate from
ordinary parameter/result types. A captured let-polymorphic function therefore
retains its independently instantiated uses; it is not assigned a fabricated
monomorphic arrow argument. Capture ownership shapes are copied with schemes.

`Core.Typed.Close` verifies its input, closes nested lambdas, and emits an
opaque `ClosedFunction` containing the converted root and generated code.
`verifyClosed` checks code references, capture scope/count/schemes/shapes,
closure-versus-join use, join argument/result types, binder identity uniqueness
across the generated functions, and absence of remaining lambdas or implicit
match fallthroughs. These are preserved type/shape contracts, not a new proof
of ownership properties beyond the existing source checker.

`Core.Typed.Walk` owns identity-based free-local discovery and capture-reference
renaming. Capture order follows first occurrence in the typed expression;
globals never become captures because their spelling matches a local.
Moved lambda parameters keep their identities. Captured parameters receive
fresh identities with the original schemes and shapes, and references are
renamed explicitly. Local spellings use a closure-group supply independent of
both inference identities and the unit's global code-label supply. An
unrelated root constructor therefore cannot shift cached unit code labels.
The focused regression varies both the namespace and constructor environment
and requires identical emitted unit Core, including its private labels.

## Typed pattern fallthrough

Matches become explicit `MatchTail` nodes with a typed fallback. The pass shares
nontrivial fallthroughs at the existing nested-pattern/guard boundaries and
registers their bodies as typed join code. Case arguments are evaluated once
into a typed local before matching. Alternative bindings remain scoped to
their own guards/body; the fallback captures the outer identities.

Within a converted function group, emitted local names are unique before
layout. Consequently a partially matched pattern cannot shadow a fallback's
capture after erasure. The native
regression covers a nested pattern that binds the same name as an outer value
before its next test fails.

A join with captures is already nonnullary. Only a capture-free join gets a
dummy argument, preventing it from becoming a nullary value while preserving
the runtime's 64-argument ceiling for a join with 64 captures. Tests check both
cases. Joins cannot escape through a closure-value node.

## Native pipeline and remaining seam

`Frontend.Desugar.Checked` retains both source-typed functions and their closed
products. It erases the verified closed roots and generated code with an
explicit code-contract table. Constructor entries take the same path. The
closed eraser lowers `MatchTail` without creating more untyped fallthrough
lambdas; closure values and direct joins already name their generated code.
The old lifting driver still drains the combined program, including entries
whose source forms have not migrated, but covered typed entries and their
generated code already contain no lambdas at that boundary.

The physical parameter-list view used by verification/erasure is not the type
authority for polymorphic captures: their code contract owns those schemes.
Missing/wrong code identities, wrong code kinds, capture changes and malformed
join calls are compiler errors, with no silent fallback from a selected typed
entry.

`Core.Typed.Layout` creates a verified `LayoutFunction` before closing. Record
updates become explicit shape branches, including nested updates. Each branch
owns a cloned typed replacement with fresh introduced identities; free lexical
references retain their identities. This order preserves the old layout-then-
lift behavior of closure identity: different layout branches retain distinct
code, while repeated use of the same branch retains the same code. Moving
lifting before that branching initially changed observable function equality;
the independent pre-change compiler reproduced the difference, and the native
regression now requires the original answers. Opaque row-field copies require
no invented source types. The eraser rejects stale plans against its actual
shape table, including nested branches.

Vector dictionaries/hidden layout parameters, generated wrappers and hole
expansion, recursive locals and specialization clones remain source migration
work. Generated record/layout temporaries still become plain Core during
erasure. Optimization, workers/reuse and region analysis still follow that
seam; this stage does not claim that they preserve typed evidence.

## Compatibility and validation

Generated private names, capture/join layout and code placement change
intentionally, advancing codegen revision to **107**. Old generated-unit and
module codegen identities must not be reused. Source parser Binary formats and
native physical ABIs are unchanged. This is not an instruction-identical
refactor, so the preceding stage's byte-for-byte assembly oracle is not used
as a claim of equivalence here.

`tests/TypedCore.hs` checks actual source/closed-stage coverage, code/UID/type
invariants, polymorphic capture retention, already-lifted erasure, malformed
capture/call refusals, stale-plan refusal, wide and capture-free joins. It
lowers old and new programs independently to machine IR and compares both
against fixed answers for scalar calls, simple/nested/polymorphic captures,
constructor matching, shadowed fallthrough and local functions.

`tests/typed_core/contracts.fpr` executes the native driver on one and four
harts. Its fixed answer is `typed-core 14 5 10 9 42 60 19`, covering recursive
dictionary witnesses, failed-pattern captures, records and closure calls.
`closure_layout.fpr` checks both direct and nested update branches, repeat-use
identity and callable results on one and four harts. The saved `c323657`
compiler independently produces its fixed answer:
`closure-layout False False True 7 8 9`.

Sol argument/shared-language checks and measured self/mutual tail calls passed:
3,000,000 iterations each, peak 86 MB, with TailCall and no following Ret.
The unit-label probe remains identical across namespaces and unrelated root
constructors. Hosted CI for the preceding `c323657` commit passed
([run 40150663772](https://github.com/hyperswine/fprisc/actions/runs/40150663772));
this stage requires its own hosted result.

The first corrected-layout sweep stopped at `turnroots`, whose global ARC
gauge sampled a service after its reply but before its turn cleanup. Repeated
native runs reproduced the transient extra root once in twelve four-hart runs.
The saved compiler reproduces the same result when the service deliberately
parks for 2 ms after its reply. `turnroots.fpr` now yields for a bounded number
of attempts until the **exact** expected count is reached, without sending new
requests while it polls. The delayed-cleanup control passes, while a turn
deliberately blocked forever before cleanup still fails with the bounded
refusal. No counter tolerance, runtime memory change or retry of a failed
program was introduced.

Final validation: all **136 Base jobs passed in 520.63 seconds on six workers**,
with no reused CI coverage. Compiler sources stayed frozen during the sweep;
platform/toolchain-dependent subchecks retain their explicit skips. No physical
board validation is claimed. Local
records: `/private/tmp/fpr-closures-layout-build.log`,
`/private/tmp/fpr-closures-layout-focused.log`,
`/private/tmp/fpr-closures-verified-base.{log,json}`,
`/private/tmp/fpr-closures-layout-root-probe.log`,
`/private/tmp/fpr-closures-layout-sol-{args,both,tail}.log`,
`/private/tmp/fpr-turnroots-differential.log`,
`/private/tmp/fpr-turnroots-delay-{before,after}.log` and
`/private/tmp/fpr-turnroots-negative.log`.
