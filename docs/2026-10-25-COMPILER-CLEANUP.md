# Compiler cleanup goal

Date: 2026-10-25. Kind: active implementation goal and acceptance register.
Applies to the Core cleanup rebased on main `0f6df38` and subsequent stages.
Requested explicitly by the user after the first Core pipeline slice.

Finish the architectural cleanup from the
[review](2026-10-25-ARCHITECTURE-REVIEW.md), in independently validated commits.
Preserve valid-program behavior and established diagnostics, native ABIs and
cache formats, or explicitly version and test any intentional changes.

## Work and completion criteria

| Item | Status | Acceptance |
|---|---|---|
| Separate Core/backend responsibilities | First slice implemented: Core.Syntax, Core.Opt passes and vector plans; Codegen driver 567 lines | Preserve emission and runtime behavior; keep new passes in their owners |
| Independent type vocabulary | Type.Syntax and Ownership.Shape implemented as independent vocabularies | Infer compatibility exports, native/Base and Sol checks; no parser/inference dependency from Type.Syntax |
| Typed, uniquely named Core | Native expressions/aggregates/patterns, constructors, closure lifting and generated joins implemented; layout/remaining forms and later transformations pending | Carry checked types and binder identity from inference; avoid reconstructing types after rewriting; checked handling of generated workers, joins and region helpers |
| Checked pipeline products and lint | Structural pass result and initial typed desugaring product implemented; full pipeline type/scope lint pending | Each stage preserves or explicitly transforms its evidence; malformed scopes/types/worker contracts fail by name; differential evaluation |
| Frontend ownership | Implemented; grammar, normalization, lowering, paths/layouts, diagnostics and linearity have separate owners | Separate surface syntax, lexer/parser, desugaring and linearity with lexical/diagnostic/cache compatibility |
| Typed compiler options | Shared environment/driver/diagnostic products and CLI owner implemented; tested compatibility controls retained | Parse inputs once, pass explicit options, share canonical cache identity, remove only obsolete rollout paths with equivalent checks |
| Structured diagnostics/spans | Inference/safety/measure/linearity producers and native/Sol consumers migrated; other producers and full parser ranges pending | Own source positions and diagnostics as data through inference/safety/rendering; preserve CLI and editor locations |
| Typed codegen contracts | Vector operations/float widths implemented; remaining kernel stages, call-convention contracts and ISA instruction vocabulary pending | Constructor-based operation/payload contracts and one renderer per target; verifier/emission/execution oracles |
| Validation ownership | Existing suites retained; focused Core and frontend compatibility checks added | Maintain invariant, golden/cache and evaluator/native differential checks without multiplying redundant builds |
| Obsolete architecture descriptions and names | Module identity and frontend-owner references corrected; backend references/names still pending | Re-anchor semantic references in current IR/evaluator/runtime; document supported switches and current owners |

Allocator-quality improvements, new foreign-ABI capabilities and the region
runtime roadmap are separate projects. Typing the existing call-convention
contracts remains in scope for this cleanup.
The goal remains active until the table is resolved and required validation is
green. Finishing this first slice is not completion of the whole goal.

## Landed first slice

[Core pipeline ownership](2026-10-25-CORE-PIPELINE.md) records the original
127-job Base run and 128 emission comparisons. That validation preceded main's
new region work, so it is not proof of the integrated tree by itself.

## Next type boundary

`Type.Syntax` now owns the existing checked type vocabulary independently of
both surface and Core ASTs. `Infer` retains compatibility reexports. The next
step is to carry evidence out of inference, distinguish term binder identities
from display names, and define a checked typed-Core stage before migrating
Workers/Reuse/region analysis consumers. Do not infer an unannotated optimized
body again and call that preserved evidence.

## Integrated validation

The integrated compiler builds with `make fpr`. Full Base passed all **131
jobs in 420.47 seconds on six workers**, with no reused CI coverage. This run
includes the incoming region tests and the Core pipeline checks; its existing
platform/toolchain-dependent subchecks retain their explicit skips. The sources
and compiler binary stayed fixed throughout the run.

Sol argument handling and the shared-language fixture passed; measured self
and mutual tail calls each ran 3,000,000 iterations under the memory guard
(peak 86 MB), with the bytecode listing ending in TailCall rather than Ret.

Make question-mode checks prove a change confined to Core/Opt/Pipeline.hs or
Type/Syntax.hs invalidates fpr. A binary-only installed-tree presence check is
quiet without compiler sources; its existing machine/runtime files remain
available. The installed-tree guard was checked separately after Base; it does
not change the compiled compiler.

Local records: `/private/tmp/fpr-cleanup-integrated-build.log`,
`/private/tmp/fpr-cleanup-integrated-base.{log,json}` and
`/private/tmp/fpr-cleanup-sol-tail.log`. Hosted CI is requested by the push;
no physical board validation is claimed for this cleanup.

## Frontend ownership stage

[Frontend ownership and compatibility](2026-10-25-FRONTEND-OWNERSHIP.md) records
the extraction of FPRISC into owned modules and the independent ownership-shape
vocabulary. It passed 132 Base jobs on six workers, 128 emission/unit comparisons,
parser/cache ABI oracles and Sol checks. The full typed-Core/type-scope goal
remains pending.

The preceding CI job at `0f6df38` could not start its coverage runner because
Git rejected container checkout ownership. Commit `04206f1` trusts only the two
explicitly checked-out repository paths. A local different-owner reproduction
failed before the exact-path trust and succeeded after it; hosted CI then moved
past that step into native backend validation. This fixes infrastructure, not a
compiler or runtime behavior.

The same hosted run then passed native/RISC-V checks but failed the classifier
suite's obsolete collector assertion. [The region gate repair](2026-10-25-CI-REGION-GATE.md)
records the actual counters, the replacement contract, negative tests and the
fresh RV32 QEMU run. Neither CI repair changes runtime semantics. Hosted CI for
`3be6efa` passed. Subsequent checkpoints still require their own hosted validation
before the overall goal can finish.

## Inference evidence stage

[The checked handoff](2026-10-25-INFERENCE-EVIDENCE.md) retains final source
types, local identities and scopes, declaration schemes, layout requirements
and elaboration choices in a named result consumed by native compilation.
It is a producer for typed lowering; source checking occurrences are not yet
typed Core, generated Core is not annotated, and optimization does not yet
preserve this evidence. The full typed-Core, options, diagnostics and codegen
contract items remain active.

Validation: all 133 Base jobs passed in 422.37 seconds with six workers and no
reused CI coverage; 128 fresh root/dependent-unit emission comparisons remained
byte-identical to the saved pre-frontend baseline, including cache keys; Sol
argument/shared-language and bounded self/mutual tail-call checks passed. The
historical register-allocation design now identifies its old pipeline and links
to the current native owners.

## First typed expression consumer

[Typed-Core lowering](2026-10-25-TYPED-CORE-LOWERING.md) now constructs and
verifies typed expressions on the native desugaring path for its covered
source forms. It retains local identities, types and ownership shapes up to
an explicit erasure boundary before closure lifting. Full aggregate/pattern
lowering, specialization and typed transformations remain required; the bridge
is a migration stage, not the requested final architecture.

Validation: all 134 Base jobs passed in 420.73 seconds on six workers with no
reused CI coverage; 128 fresh emission/unit-key comparisons, parser/cache
compatibility and Sol compatibility/tail-call checks passed. The goal remains
active across the erasure boundary and all other pending table entries.

## Typed aggregate and pattern stage

[Typed aggregates and patterns](2026-10-25-TYPED-CORE-PATTERNS.md) extends the
native typed product to semantic aggregate/record operations, nested patterns,
multiple clauses and guards, result pipes, interpolation, nonrecursive local
functions and constructor entries. Inference retains exact pattern types and
binding identities. Shared type relations and Core lint check these contracts
before explicit layout/erasure.

The stricter consumer exposed unconstrained dictionary member calls and late
written-signature promises. Source inference now constrains members before
generalization, retains lexical dictionary witnesses and rechecks final
promises. The MVU callback signature states its existing environment
relationship explicitly. This intentional dispatch correction advances the
codegen cache revision to 106; physical native ABIs remain unchanged.

Generated layout joins, closure lifting and subsequent passes still cross the
untyped boundary. Vector dictionaries, generated wrappers, recursive locals,
specialization evidence, options, diagnostics and codegen contracts remain
required work. This stage does not complete the goal.

Validation: all 134 Base jobs passed in 440.75 seconds on six workers without
reused CI coverage. The expanded invariant and one/four-hart native fixtures,
MVU suite, 128 fresh emission comparisons with explicit revision-only
normalization, and Sol compatibility/tail-call checks passed. Hosted CI for
the preceding `b983812` stage passed; each subsequent checkpoint still needs
its own hosted result.

## Shared options and command-line ownership

[Compiler options and cache contracts](2026-10-25-COMPILER-OPTIONS.md) consolidates
native environment controls and their cache renderers in `Compiler.Options`,
and moves argument parsing/host resolution to `Compiler.CommandLine`. Lowering,
unit caching and executable caching consume the same parsed controls. The
executable cache now distinguishes receive-region modes and changed foreign
contracts; the saved pre-fix compiler reproduces the stale-mode failure.

Generated-unit key spellings and codegen revision 106 remain unchanged. The
executable cache intentionally adopts the versioned canonical options identity.
Report controls remain separate; compatibility aliases retain their tested
defaults/refusals. Typed transformations, structured source diagnostics and
machine/ABI contracts remain outstanding full-goal work.

Validation: 135 Base jobs passed in 435.19 seconds on six workers with no
reused CI coverage, alongside 128 fresh emission/unit-key comparisons, the
pre-fix cache-bug reproduction, native mode/contract cache transitions and Sol
compatibility/bounded-tail checks. The complete architecture goal stays active.

## Structured checking diagnostics and ownership obligations

[Structured checking diagnostics](2026-10-25-STRUCTURED-DIAGNOSTICS.md) introduces
independent source coordinates, semantic diagnostics and located rendering.
Inference, safety/measure checking and linearity construct these products;
native compilation and Sol consume them directly. Legacy string formatting is
restricted to compatibility APIs. Checking evidence and typed Core retain typed
source offsets.

Ownership violations and unrestricted type-variable obligations now have
separate constructors. The named linearity product contains the completed
constraint table and diagnostics. A verified 64-round truncation bug was fixed:
the old compiler accepted a 90-wrapper path to duplication of an owned value;
the true fixpoint rejects it at the call. Deferred operator errors also retain
their original function/statement context.

Remaining diagnostic producers, full surface ranges/generated origins and
imported Sol context are still required. The typed-Core transformation seam,
machine/ABI contracts and other outstanding table entries remain full-goal work.

Validation: all 136 Base jobs passed in 435.56 seconds on six workers without
reused CI coverage. The structured product/CLI regressions and independently
verified pre-fix ownership counterexample, 128 fresh emission/unit comparisons,
parser Binary/cache compatibility and Sol compatibility/bounded-tail checks
passed. Codegen revision 106 and native ABIs are unchanged.

## Typed closure lifting and joins

[Typed closures and joins](2026-10-25-TYPED-CLOSURES.md) moves actual closure and
pattern-fallthrough conversion before erasure for covered typed entries.
Opaque closed products retain code identities, polymorphic capture schemes,
parameter/result types and binder identities. Native erasure consumes those
products and does not regenerate their joins as untyped lambdas. Typed record
update plans precede lifting so distinct layout branches keep their existing
closure identities, including nested updates; stale shape plans are refused.

New local spellings prevent pattern shadowing from capturing fallback values.
Capture-free continuations stay nonnullary, while a 64-capture continuation
does not acquire a 65th argument. Differential machine-IR evaluation and
one/four-hart native answers exercise both captures and joins. Generated code
changes intentionally advance the cache revision to 107; physical ABIs remain
unchanged.

The layout/optimization/region seam and the remaining source forms still need
typed migration. All other outstanding full-goal items remain required.

Validation: all 136 Base jobs passed in 520.63 seconds on six workers without
reused coverage. Typed invariant/differential evaluation, native one/four-hart
closure/layout answers, unit-label stability and Sol compatibility/bounded-tail
checks passed. A global-root sampling race in `turnroots` now waits boundedly
for the exact expected count; a saved-compiler delayed-cleanup reproduction and
a persistent-root negative control validate that test correction. Hosted CI for
the preceding `c323657` stage passed; this stage still needs its hosted result.
