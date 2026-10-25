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
| Typed, uniquely named Core | Native expressions/aggregates/patterns, constructors, closure lifting, generated joins/traps, direct recursive locals, vector-layout evidence, structure specialization, checked lexical closure calls and local callback cloning implemented; layout temporaries/remaining forms and later transformations pending | Carry checked types and binder identity from inference; avoid reconstructing types after rewriting; checked handling of generated workers, joins and region helpers |
| Checked pipeline products and lint | Owned semantic/native program products, complete graph contracts, typed desugaring/closed products and checked unit ownership implemented; downstream pipeline type/scope lint pending | Each stage preserves or explicitly transforms its evidence; malformed scopes/types/worker contracts fail by name; differential evaluation |
| Frontend ownership | Implemented; grammar, normalization, lowering, paths/layouts, diagnostics and linearity have separate owners | Separate surface syntax, lexer/parser, semantic desugaring and linearity from native layout/closing/erasure, with lexical/diagnostic/cache compatibility |
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

## Typed recursive local functions

[Typed recursive locals](2026-10-25-TYPED-RECURSIVE-LOCALS.md) adds an explicit
recursive binding with checked lexical scope and initializer contracts. The
closure pass turns self into its code plus lexical captures before closing
nested lambdas. Named/direct-lambda initializers, escaping and partial self
values, polymorphic uses, nested recursion and record-layout identity cloning
retain checked schemes and unique binders.

This fixes a verified source/native gap: a captured local accumulator checked
successfully but was refused as an unknown primitive by the preceding compiler.
Cache revision 108 distinguishes the newly emitted code; physical ABIs and
runtime memory structures are unchanged. Hidden layouts, computed recursive
initializers, generated forms, specialization evidence and downstream typed
transformations remain required. The full goal remains active.

Validation: all 136 Base jobs passed in 467.51 seconds on six workers without
reused coverage. New evaluator and one/four-hart native answers, portable
x64/RV32/RV64 emission, a saved-compiler refusal reproduction, 128 fresh
root/dependent-unit emission comparisons (cache-revision-only normalization),
and Sol compatibility/bounded-tail checks passed. Hosted validation of the
integrated head follows the push.

## Typed vector layout evidence

[Typed layout evidence](2026-10-25-TYPED-LAYOUT-EVIDENCE.md) carries hidden
parameters, static/forwarded descriptors and calling schemas into selected
typed entries. Layout evidence has its own element-indexed type, local contracts
own binder identities, and vector builders have checked semantic constructors.
Closure conversion retains the evidence; erasure emits the existing String
arguments/runtime symbols.

The migration fixes verified local/global name confusion and quantified-scheme
scope failures, with saved-compiler wrong-answer/refusal reproductions. Cache
revision 109 versions changed checking/code generation; runtime/context memory
structures are unchanged. Generated forms, specialization/per-unit evidence,
typed layout temporaries and downstream transformations remain required, along
with the other outstanding table entries. The full goal remains active.

Validation: all 136 Base jobs passed in 451.99 seconds on six workers without
reused coverage. Typed layout/scheme invariants, one/four-hart native answers,
saved-compiler control/wrong-answer/refusal comparisons, imported layout and
optimization variants, repaired Rosetta/QEMU kernel oracles and Sol
compatibility/bounded-tail checks passed. Hosted CI for `605df23` passed;
integrated-head hosted validation follows this push.

## Typed generated traps

[Typed generated traps](2026-10-25-TYPED-TRAPS.md) carries anonymous holes and
holed-constructor references into checked native products. A shared private
plan owns exact argument delays and failure messages. Constructor provenance
is distinct from ordinary polymorphism; generated parameters retain identities
and types through closure conversion. Intrinsic failures preserve the tested
native effects, output and exit status of the saved compiler. Named holes still
refuse compilation with their inferred types.

Cache revision 110 versions changed private generated code; runtime/context
memory structures and native ABIs are unchanged. Specialization/per-unit
evidence, remaining generated forms, typed transformations and all other
outstanding table entries remain required. The full goal stays active.

Validation: all 136 Base jobs passed in 470.72 seconds on six workers without
reused coverage, including typed contracts/evaluation, native one/four-hart
effects, named-hole refusal and x64/RV32/RV64 emission. Saved-compiler fixed
answers and Sol argument/shared-language/bounded-tail checks pass. Integrated
hosted validation follows the push; the full cleanup goal remains active.

## Checked unit ownership

[Checked units](2026-10-25-CHECKED-UNITS.md) removes the second per-unit
inference run and its discarded errors. Prelude and dependency units consume
private owned projections of merged checking, preserving eligible definitions'
types, identities and elaboration decisions. Global calling arities share the
same producer. A versioned lowered-input cache identity includes referenced
calling contracts and reachable constructor bodies while retaining reuse across
unrelated root declarations.

Saved-compiler probes reproduce a transitive F64 operation emitted as integer
arithmetic and an imported recursive local refused as an unknown primitive.
The checked path returns the fixed independent answers. Cache revision 111
versions these changes; physical ABIs and runtime structures are unchanged.
Root specialization, downstream typed transformations and the remaining table
entries stay required. The full cleanup goal remains active.

Validation: all 136 Base jobs passed in 452.84 seconds on six workers without
reused coverage. Focused unit ownership/composition, native one/four-hart answers,
warm type/context/flat-curried arity transitions, unrelated-root cache reuse and
x64/RV32/RV64 emission pass. Saved/new fixed-answer controls and Sol
argument/shared-language/bounded-tail checks pass. Integrated hosted validation
follows the push; the full cleanup goal remains active.

## Typed structure specialization

[Typed structure specialization](2026-10-25-TYPED-STRUCTURE-SPECIALIZATION.md)
instantiates checked functions before layout and closure conversion. Clone
contracts retain polymorphic ordinary/provider/capture schemes, fresh identities
and instantiated ownership shapes. Owned source products prepare the pass once;
source parameter identities no longer depend on backend label allocation.

The migration fixes verified local/global callee confusion and loss of captured
layout arguments when a record field was flattened to a raw global. Shared
surface scope handling also keeps Sol and compatibility analyses consistent.
Cache revision 112 versions changed code; physical ABIs and runtime structures
are unchanged. Function-argument specialization in `Mono`, downstream typed
transformations and all other outstanding table entries remain required. The
full cleanup goal stays active.

Validation: all 136 Base jobs passed in 666.05 seconds on six workers with a
fresh native cache and no reused coverage. Typed contracts/evaluation,
one/four-hart native answers, saved/new controls and x64/RV32/RV64 emission pass.
Sol scope/compatibility/bounded-tail checks pass. Hosted CI for `84fda39` passed;
this integrated checkpoint requires its own hosted validation after push.


## Typed polymorphic code calls

[Typed code calls](2026-10-25-TYPED-CODE-CALLS.md) checks each closure/join's
capture schemes, ordinary arguments and result in one fresh type/row
instantiation. Ambient global variables stay rigid through the code graph;
capture-local foralls retain scope. Private closed transformations recheck code
identity, binder scope and parameter-role invariants before publication.

Known saturated lexical closure calls now resolve before erasure while retaining
their original code identity. Captures require manifest immutable types and
unrestricted ownership shapes. Callable/owned/unknown captures and stored partial
applications retain the existing path until their ownership/staging evidence is
available. Codegen revision 113 versions generated code; native ABIs and runtime
structures remain unchanged.

The fresh-cache 136-job Base sweep passed in 475.13 seconds on six workers with
no reused coverage. After a defensive capture-shape gate tightening, the complete
focused typed-Core suite passed again with a fresh native cache. The record
separates that final focused validation from the earlier full local sweep.
Saved/new native and Sol effect/identity controls, existing specialization
allocation/mode regressions and Sol compatibility/bounded-tail checks pass.
Hosted CI for `a258266` passed; this integrated checkpoint requires its own hosted
validation after push.

Typed argument staging, `Mono` callback specialization and callable ownership
remain required. The saved-compiler controls also record an existing
optimizer-disabled overapplication ordering discrepancy for that staging work.
All other outstanding table entries remain required; the full cleanup goal stays
active.


## Typed native call staging

[Typed call staging](2026-10-25-TYPED-CALL-STAGING.md) gives native application
groups checked operand/saturation boundaries before erasure. The source pass
runs after layout planning and before closure conversion, retaining lexical
arity inside nested lambdas and recursive bodies. A closed-graph product serves
later typed transformations. Both products check types, scope, ownership shapes
and staging invariants; neither guesses physical arity from logical arrows.

This fixes verified optimizer-dependent effect/trap priorities. Known prefixes
now execute before arguments applied to their result, while operands of unknown
native groups remain ahead of later specialized callbacks. Stored partials and
CAFs retain their initialization behavior and arity evidence; foreign signatures
keep their existing lowering. Codegen revision 114 versions these corrections;
physical ABIs and runtime memory structures are unchanged.

Validation: the final fresh-cache Base sweep passed all 136 jobs in 485.47 seconds
on six workers, with no reused coverage and fixed compiler/test sources. Source
and closed staging invariants, independent machine-IR counterexamples, captured/
recursive arity evidence, all four optimization modes, one/four-hart native
answers, imported entries and x64/RV32/RV64 emission pass. The saved compiler
reproduces both ordering bugs; numeric answers and the Sol-compatible control
remain unchanged. Existing specialization allocation/mode checks and Sol
argument/shared-language/bounded-tail checks pass. Hosted CI for `aa6e738`
passed; this integrated checkpoint requires its own hosted validation after push.

Typed callback cloning and replacement of `Mono` remain required, as do callable
ownership/multiplicity evidence, downstream typed transformations and the other
outstanding table entries. The full cleanup goal remains active.


## Typed local callback specialization

[Typed local callbacks](2026-10-25-TYPED-CALLBACKS.md) now clone owned local code
before erasure, retaining type/row solutions, capture-local foralls and fresh
binder identities. Invocation-only callback fields disappear through checked
liveness; returned/compared/captured callback objects and shared nested code keep
their original identities. Partial operands are snapshotted once, pattern aliases
with unsaved prefixes retain their original path, and temporary removal requires
explicit evidence of unrestricted captures. Unknown callable environments remain
on the existing path.

An explicit computation-entry kind permits private nullary calls without
pretending they are immutable callable values. Joins keep their continuation
role. Arity budgeting runs after provisional callback fields are trimmed; an
overflow restores the original call graph. The legacy specializer now preserves
stored PAP aliases and refuses escaping callback substitution. Saved revision-114
native code reproduces the identity discrepancy; the integrated compiler returns
the independently expected result. Cache revision 115 versions these changes;
physical ABIs and runtime/context memory structures remain unchanged.

Validation: all 136 Base jobs passed in 503.92 seconds on six workers with a fresh
native cache, no reused coverage and fixed compiler/test sources. Typed graph,
independent evaluator, ownership, nullary/join, schema, identity and 64-field
boundary checks pass, alongside native one/four-hart optimizer modes, imported
units, all four native emission targets and existing specialization allocation
checks. Sol argument/shared-language and 3,000,000-iteration self/mutual tail-call
checks pass (peak 85 MB). Hosted CI for `18b3c26` passed; integrated-head hosted
validation follows this push.

The next specialization boundary is a checked program owner spanning roots and
imported units, including calling schemas and receive-region provenance. That is
required before global/imported callback specialization can move and `Mono` can
retire. Callable ownership/multiplicity evidence, later typed transformations,
remaining diagnostics and machine/call contracts also remain required. This
checkpoint does not complete the full cleanup goal.


## Owned typed programs and native pipeline

[The owned program pipeline](2026-10-25-TYPED-PROGRAM-PIPELINE.md) moves actual
native layout, closing and erasure out of frontend desugaring. Semantic source
selections retain checked schemes, physical arities, types/ownership shapes and
unique identities; the closed program retains its input and layout authority.
Complete graph checks cover definition ownership, interfaces, binders, code
labels and calling evidence. Covered definitions no longer use untyped lambda
lifting. Compatibility-only clauses remain explicit and separate, with their
own causes and correctly shared legacy fresh supply.

Signed recursive references now carry the provisional and published schemes
that source checking actually used. The program records source identity,
owner/target and scoped permissions; ordinary globals still require compatible
published interfaces. This models the existing heterogeneous IRQ protocol
without silently claiming its assumptions prove ABI type equality or changing
the inference solver. Later typed consumers must retain the distinction.

Owner-qualified private labels preserve existing role markers and unit reuse
across unrelated roots/constructors and inference namespaces. Source value
bindings keep their established priority over constructor value stubs. Structure
specialization publishes generated schemes with its bodies. Codegen revision
116 versions private naming/cache changes; public native ABIs, source Binary
identity and runtime/context structures are unchanged.

Validation: all 136 Base jobs passed in 527.71 seconds on six workers with a fresh
cache, no reused coverage and fixed compiler/test sources. Expanded program
contracts, independent evaluator/native answers, source assumptions and malformed
permissions, imported-unit cache transitions, all native emission targets,
frontend/inference compatibility and existing allocation/mode checks pass. The
direct complete-prelude audit has 236 semantic definitions and 248 emitted
functions with no compatibility fallback. Saved/new native identity/effect and
constructor-shadow controls match exactly. Sol argument/shared-language and
3,000,000-iteration self/mutual tail-call checks pass (peak 85 MB). Hosted CI for
`83ee345` passed; integrated-head validation follows the push.

A linked typed owner across artifacts, declaration/visibility contracts for
private code references, global/imported callback specialization and `Mono`
retirement remain required. Region provenance, remaining source compatibility
forms, later typed transformations, diagnostics and machine/call contracts also
remain active full-goal work. This program handoff is a prerequisite and an actual
native consumer, not completion of the requested cleanup.
