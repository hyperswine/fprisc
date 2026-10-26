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
| Typed, uniquely named Core | Native expressions/aggregates/patterns, constructors, closure lifting, generated joins/traps, direct recursive locals, vector-layout evidence, structure specialization, checked lexical calls, local/global/imported callback cloning, region control, checked Base inlining, pair-free vector reads and normalization implemented; layout temporaries/remaining forms, ARC and other later transformations pending | Carry checked types and binder identity from inference; avoid reconstructing types after rewriting; checked handling of generated workers, joins and region helpers |
| Checked pipeline products and lint | Owned semantic/native and linked artifacts, region input/cost views, typed region control bodies and protocol/helper contracts, complete graph/imported interfaces and checked inlining round snapshots and checked normalization products implemented; other later pipeline type/scope lint pending | Each stage preserves or explicitly transforms its evidence; malformed scopes/types/worker contracts fail by name; differential evaluation |
| Frontend ownership | Implemented; grammar, normalization, lowering, paths/layouts, diagnostics and linearity have separate owners | Separate surface syntax, lexer/parser, semantic desugaring and linearity from native layout/closing/erasure, with lexical/diagnostic/cache compatibility |
| Typed compiler options | Shared environment/driver/diagnostic products and CLI owner implemented; tested compatibility controls retained | Parse inputs once, pass explicit options, share canonical cache identity, remove only obsolete rollout paths with equivalent checks |
| Structured diagnostics/spans | Inference/safety/measure/linearity producers and native/Sol consumers migrated; other producers and full parser ranges pending | Own source positions and diagnostics as data through inference/safety/rendering; preserve CLI and editor locations |
| Typed codegen contracts | Vector operations/float widths, symbol visibility/private imports, native ISA operations, instruction annotations/accounting, word/C-export calls, selected code/address roles, shared checked entry/apply/panic contracts and checked column/record/layout kernel plans implemented; other source/data/linker interfaces pending | Constructor-based operation/payload contracts and one renderer per target; verifier/emission/execution oracles |
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


## Linked native input ownership

[Linked native program ownership](2026-10-25-LINKED-NATIVE-PROGRAM.md) retains
root/prelude/dependency typed artifacts, emitted exports/elisions, source
calling schemes/physical arities and private code contracts in one checked
product. Actual root/unit emission and imported specialization projections
consume those retained owners. Exported and artifact-local symbols have distinct
identities; constructor elision requires exact generated-stub provenance, even
when a source value shares a constructor's name. Imported published interfaces,
physical arities, layouts, exports and binder identities are checked before
assembly reuse or emission.

Validation: all 136 Base jobs passed in 589.73 seconds on five workers with a
fresh cache and no reused CI coverage. The complete typed/native and registered
RV QEMU gates, expanded linked-contract refusals and independent evaluator
answers passed. All 128 fixed-binary root/dependent-unit emission and cache-key
comparisons were byte-identical without normalization. Sol arguments,
shared-language execution and 3,000,000-iteration self/mutual tail calls passed
(peak 85 MB). Codegen revision 116 and the public ABI/cache formats are unchanged.
Hosted validation for this checkpoint follows the push.

This resolves the linked input-owner prerequisite from the preceding stage.
Explicit private import declarations/visibility and stable closure/PAP identity
are next requirements for typed global/imported callback specialization and
`Mono` retirement. Region/cost provenance, remaining compatibility forms, later
typed transformations, diagnostics and machine/call contracts remain required.
The complete compiler cleanup goal remains active.


## Home-owned private code imports (2026-10-26)

[Private code imports](2026-10-26-PRIVATE-CODE-IMPORTS.md) derives explicit
home/source/code/capture contracts from the linked checked graph and prepares
native emission through an owned program/import/template/symbol-policy product.
Checked helpers and static PAPs retain their home identity rather than being
copied by imported callback cloning. ELF hidden and Mach-O private extern
visibility share one typed policy across native code and data. Read-only
contexts preserve imported inlining and vector map/pipeline planning; generated
kernel implementations remain local to their artifact.

A saved-compiler reproducer returned unequal capture-free function objects with
specialization enabled and equal objects with it disabled. The corrected path
preserves identity across both paths, while distinct captured closures still
compare unequal and stored aliases compare equal. Revision 117 versions this
behavior correction and changed linkage/cache contents, with no physical ABI,
context or runtime-object-layout change.

The linked-owner baseline `5b52aed` passed hosted CI run 40194815858. All 136
Base jobs for this checkpoint passed in 515.82 seconds on six workers, with a
fresh cache, no reused CI coverage and fixed sources. The expanded home-import
invariants and native identity/effect/cache checks pass, root/provider objects
assemble in all six native formats, and imported map/fused pipeline plans remain
specialized. Sol arguments/shared-language execution and self/mutual 3,000,000
iteration tail calls pass (peak 85 MB). Integrated-head hosted validation follows
the push; the private-import stage page records the evidence and platform skips.
Global cloning still uses `Mono`; typed global clone/source provenance and
region/cost provenance remain the next major requirements. Compatibility/erased
region helpers, later typed transformations, source diagnostics and machine/call
contracts remain required. This stage does not complete the compiler cleanup.


## Checked physical region interfaces (2026-10-26)

[Region interfaces and provenance](2026-10-26-REGION-INTERFACES.md) supplies
region placement from the owned checked native graph, including private code,
hidden physical arguments, binder IDs, ownership shapes and result types.
Unchanged compatibility clauses may keep a checked source declaration; changed
clauses cannot borrow it or a same-named context interface. Checked constructor
schemes replace source-AST type conversion in copyability/boundedness analysis.
Cost equations retain their exact scoped analysis projection, with compatibility
counters separated across local/context views. Shared artifact region results
retain generated helper roles, source interfaces, state and physical parameters.
The rewrite verifies helper/entry/scope contracts and physical argument limits.

A saved-compiler private receive loop reports 196,480 bytes of heap growth
against its 4 KiB bound on one and four harts; the corrected path places a
receive region and passes.
Revision 118 versions placement/emission/cache changes. Runtime structures and
physical ABIs are unchanged. Fresh-cache integrated Base validation passed all
136 jobs in 509 seconds on six workers, with no reused results. Focused region,
typed-Core and Sol checks passed; the stage page records host/toolchain skips.
Baseline `38673d2` passed hosted CI run 40198814856; that result precedes this
stage. The integrated region-interface commit `bd2830b` passed hosted CI run
40205756522.

This is checked provenance and a structural contract for the existing erased
region rewrite. Typed helper bodies and global callback clone/source provenance
remain required before `Mono` retirement. The later typed transformations,
remaining compatibility forms, diagnostics and machine/call vocabulary remain
part of the full active cleanup goal.

## Typed global callback cloning (2026-10-26)

[Checked global cloning](2026-10-26-TYPED-GLOBAL-CLONING.md) moves global and
imported callback specialization before region placement and erasure. A checked
catalog owns template bodies, schemas, code contracts and shared role analysis.
Clones instantiate checked annotations with fresh binder identities, retain
source/template/physical-parameter provenance and preserve escaping callback
objects. Imported private code remains a home-owned declaration; the linked
verifier checks it against its actual emitting contract. Ambient rigid variables
propagate through those imports. Region interfaces retain clone provenance.

Revision 119 versions specialization/emission/cache changes without changing
runtime structures or physical ABIs. The erased specializer is restricted to
compatibility definitions and remaining generated region helpers. Typed region
helper bodies are still required before `Mono` can be removed; later typed
optimizations, compatibility forms, diagnostics and machine/call contracts
remain part of the full active goal. Final validation passed all 136 Base jobs
in 540.74 seconds on six workers, with an empty cache, no reused results and
unchanged timeouts. Sol arguments/shared fixture and three million tail-call
iterations pass too; the stage page records platform skips and the compile-time
regression correction. Baseline `bd2830b` is green in hosted CI run 40205756522;
the integrated global-cloning commit `134a992` passed hosted CI run 40210518302.

## Typed region control (2026-10-26)

[Typed region control](2026-10-26-TYPED-REGION-CONTROL.md) preserves checked
source expressions and fresh helper identities through loop, receive and call
region transformation. Marks, sequences, ticks, state bundles and receive-step
results have dedicated internal sorts. Verification checks physical interfaces,
lexical scope, call witnesses, source ownership and state proofs. Changed helper
bodies re-establish liveness/invariance/effect/cycle obligations. Typed helpers
retain home code/PAP declarations across artifacts.

The planner's scoped cost projection and mixed compatibility-group rewrite
remain explicit. `Mono` still serves compatibility code; later transformations,
layout temporaries, remaining frontend forms, diagnostics and machine/call
contracts remain required. Revision 120 changes emission/cache identity without
changing runtime structures or physical ABIs. The full cleanup goal stays active.

Final fixed-source validation passed all 136 Base jobs in 572.64 seconds on six
workers with a fresh cache, no reused results and unchanged timeouts. Sol
arguments/shared-language and three-million-iteration self/mutual tail calls
pass, with an 86 MB reported peak. The stage page records the platform skips,
compile-time overhead and preceding hosted CI result. This stage requires its
own hosted result after push.

## Constructor-based x64 selected operations (2026-10-26)

[x64 operation contracts](2026-10-26-X64-OPCODE-CONTRACTS.md) carries opcode,
condition and float-width constructors through selection, placement/allocation
and rendering. Shared entry, self-tail transfer and argument-cell protocols
also retain constructors. A dedicated x64 form checker verifies operand roles,
control/flag/call metadata, fixed banks and ties before allocation and on the
final physical stream. Other ISA-specific operations remain explicit migration
inputs and are refused by the x64 path.

The saved-compiler differential oracle passes 120 byte-identical root/unit
outputs and cache identities across six targets. Independent hosted/QOS x64
scalar/vector and float-tree oracles pass under Rosetta; real Mach-O runtime
programs match native AArch64. This architecture-only stage retains revision
120 and physical ABIs. A64/RISC-V operation vocabularies, call conventions,
typed later optimizations and the remaining table entries are still required.

Final validation passed all 136 Base jobs in 577.36 seconds on six workers,
with fixed sources, a fresh cache, no reused results and unchanged timeouts.
Sol arguments/shared-language and three-million-iteration self/mutual tail
calls pass, with an 86 MB reported peak. The stage page records exact-emission
and execution coverage and platform skips; its own hosted result follows push.

## AArch64/RISC-V selected operation contracts (2026-10-26)

[The remaining native ISA vocabularies](2026-10-26-RISC-OPCODE-CONTRACTS.md)
now use constructors through selection and rendering. Separate per-ISA modules
own operations; shared types own protocols and scalar/SIMD payloads. A64 FP
pooling changes explicit word/FP banks, and RV raw adapters retain typed
arithmetic/comparison/memory operations. Form checkers verify physical banks,
operand roles, control/flag effects and call metadata; synthetic/cross-ISA
instructions cannot enter native rendering. Shared save markers and redundant
move identity also use constructors.

The expanded differential gate passes 167 byte-identical root/unit outputs and
cache identities across 85 configurations on eight targets, including hosted
A64 FP pooling, RVV plugins and builtin ARC/raw. Independent IEEE and real
ownership-runtime oracles pass. Revision 120 and physical ABIs remain unchanged.
Existing call-convention, symbol-role and annotation contracts, later typed
transformations and all other outstanding table entries remain required.

Final fixed-source validation passes all 136 Base jobs in 586.74 seconds on six
workers, with a fresh cache, no reused results and unchanged timeouts. Sol
arguments/shared-language and three-million-iteration self/mutual tail calls
pass, with an 86 MB reported peak. The stage page records exact-emission,
execution coverage and platform skips. The complete compiler goal stays active.

The preceding integrated head `d190e1a` passed hosted CI run 40222451310,
including the earlier region-control implementation. Its region-only run was
cancelled when superseded. The new ISA-constructor stage still needs its own
hosted result after push.

## Typed instruction annotations and allocation events (2026-10-26)

[Selected-instruction annotations](2026-10-26-INSTRUCTION-ANNOTATIONS.md)
replace `siNote` with semantic entry/save/restore payloads and independent
allocator event data. Shared entry-label roles drive both rendering and scope
checks. Native consumers check annotation roles, internal/local label
collisions, physical event operands and final-frame save-group bounds; no
renderer decodes an integer or protocol tag from text. Self-loop splitting and
shrink-wrap preserve the typed payloads. Labels named `copy`, `reload` or `spill`
cannot alter real allocation statistics.

All 167 root/unit outputs and cache identities remain byte-identical across 85
configurations on eight targets. Final fixed-source Base validation passes all
136 jobs in 584.02 seconds on six workers, with a fresh cache, no reused results
and unchanged timeouts. Sol compatibility and three-million-iteration
self/mutual tail calls pass with an 85 MB peak. Revision 120 and physical ABIs
remain unchanged. The preceding `9c12c6b` checkpoint passed hosted CI run
40225611701; the annotation checkpoint `4dc7acd` passed hosted CI run
40228013834. Existing call
conventions/symbol roles and all remaining table entries stay in the full
active cleanup goal.

## Explicit native word calling conventions (2026-10-26)

[Native word call contracts](2026-10-26-CALLING-CONVENTIONS.md) separate generated
entries from existing C runtime adapters and retain arity, fuel policy and result
mode on every selected direct call/tail transfer. Shared ABI data drives
selection and arrival; native checkers validate register/result placement,
complete clobber sets, events and hart-cell staging before and after allocation.
x64's private argument cells and renderer TLS roles use constructors rather
than symbol strings. Missing/duplicate cells or staging across a call, safepoint
or control boundary are refused.

Existing C export trampolines, embedded call boundaries, general symbol roles,
remaining kernel stages, later typed transformations, compatibility/layout
forms and the other outstanding table entries remain full-goal work. This
checkpoint does not complete the compiler cleanup. Final validation evidence
is recorded on the stage page.

All 167 root/unit outputs and cache identities are byte-identical across 85
configurations on eight targets. The final fixed-source, fresh-cache Base sweep
passes all 136 jobs in 584.39 seconds on six workers, with no reused coverage or
timeout changes. Sol compatibility and three-million-iteration self/mutual tail
calls pass with an 85 MB peak. Revision 120 and physical/runtime ABIs remain
unchanged. The `871845e` checkpoint passed hosted CI run 40231567763.

## Checked C exports and retained ARC representations (2026-10-26)

[C export/ARC contracts](2026-10-26-EXPORT-ARC-CONTRACTS.md) separate declaration
admission, checked argument/conversion/schedule/frame plans and final RV64
rendering from `Compile.hs`. Native argument placement is shared with the word
calling contract. The supported soft/hard ABI limits are unchanged.

The independent C probe reproduced an old ARC panic: an unconstrained erased
`Addr` parameter defaulted to managed despite its checked interface, causing
ARC to retain/release an interior address. Concrete representation evidence
now flows from checked closed functions and compatibility declarations into
ARC before inference/defaulting. Kinds and primitive signatures use
constructors; field tags are serialized only for the runtime. All 3,200
position-specific soft/hard C calls pass under QEMU with the real ARC runtime.
The saved compiler reproduces the failure. ARC cache revision 6 versions the
corrected ownership code; general codegen revision 120 and runtime ABIs remain.

This is a retained interface boundary for the existing erased ARC solver and
ownership rewrite. Full typed expression transformations, compatibility/layout
forms, embedded call contracts, general symbol roles, remaining kernel stages
and source ranges/diagnostic producers remain required. The whole compiler
cleanup goal is active.

Final fixed-source validation passes all 136 Base jobs in 582.59 seconds on six
workers with a fresh cache and no reused configurations. The saved-compiler
oracle preserves 168 complete outputs/cache identities plus 25 exact C adapter
bodies across 88 configurations on eight targets. Independent real-runtime
execution proves the intentionally corrected ARC bodies. Sol compatibility and
three-million-iteration self/mutual tail calls pass with an 86 MB peak. The
preceding `871845e` checkpoint passed hosted CI run 40231567763; the export/ARC
checkpoint `ce77e9f` passed hosted CI run 40235445898.

## Selected runtime protocols and symbol references (2026-10-26)

[Selected runtime contracts](2026-10-26-SELECTED-RUNTIME-CONTRACTS.md) replace
`OS String` with callable/address roles and Boolean call-event pairs with
explicit callee-entry/runtime-C/fuel effects. Shared runtime identities own
helper spellings. One protocol owner supplies and checks entry/tick/apply/
panic/push events, registers, clobbers, result/preservation constraints, flags
and control before and after allocation. Apply additionally checks its staged
head/argument packet and refuses count or lifetime violations. Entry forwarding,
loop splitting, shallow entries and allocator metadata retain the contracts.

Selected/allocation invariants pass, and all 170 complete root/unit outputs
and cache identities remain byte-identical across 88 configurations on eight
targets. General codegen revision 120, ARC revision 6 and physical/runtime ABIs
are unchanged. Target frame/TLS expansions retain their current owners; this
does not claim their complete planning migration. Remaining source/data/linker
interfaces, kernel stages, typed Core transformations, compatibility/layout
forms and source-range/diagnostic producers stay in the full active goal.

The final fixed-source, fresh-cache Base sweep passes all 136 jobs in 602.42
seconds on six workers, without reused configurations or timeout changes. Sol
compatibility and three-million-iteration self/mutual tail calls pass with an
86 MB peak. The preceding export/ARC checkpoint `ce77e9f` passed hosted CI run
40235445898; this selected-runtime stage needs its own hosted result after push.
The complete compiler cleanup goal remains active.

## Checked column-kernel plans

[Column-kernel plan contracts](2026-10-26-KERNEL-PLAN-CONTRACTS.md) retain
semantic operation constructors into native lowering and check plan/callback
evidence before CFG construction. Remaining typed Core transformations,
record/layout kernel plan ownership and the other open table items remain
full-goal work.

## Checked record and layout-kernel plans

[Record/layout kernel plan contracts](2026-10-26-RECORD-PLAN-CONTRACTS.md)
extend the checked plan owner across all three native kernel builders.
Record callback interfaces, descriptor/capture references and layout-map
entry boundaries are checked before building CFGs. Later typed Core
transformations and all other pending table entries remain full-goal work.

## Checked Base inlining

[Typed Base inlining](2026-10-26-TYPED-BASE-INLINING.md) carries checked
instantiations, ownership shapes and fresh lexical identities through the
inliner before region placement/erasure. Entry ticks retain scheduling and
nonallocation contracts; linker visibility and original private code homes
remain authoritative. Unscoped erased Base inliner entry points are retired.
ARC and the other later transformations, plus all remaining table entries,
remain required. Codegen revision 121 intentionally invalidates older
optimized artifacts while physical calling conventions remain unchanged.

The final fixed-source fresh-cache sweep passes all 136 Base jobs in 666.50
seconds on six workers, without reused results or timeout changes. Saved/new
compilers pass eight runtime and 32 emission comparisons across eight targets;
fresh-cache QOS host/application/plugin admission and Sol compatibility/tail
checks pass. Full call-cycle exclusion preserves generated-join receive loops
and their original heap bounds. The stage page records the initial regressions,
their fixes, explicit platform skips and preceding hosted CI; this checkpoint
requires its own hosted result after push. The whole cleanup goal remains active.

## Checked pair-free vector reads

[Typed vector reads](2026-10-26-TYPED-VECTOR-READS.md) retains the logical pair,
tuple pattern, ownership shape and original identities through read planning.
The verifier refuses escaped physical values, nonlocal handles and malformed
operation contracts. Shared ordinary/region erasure snapshots the original
handle before pattern binders can shadow it. The erased pass is restricted to
explicit compatibility owners; ARC/raw keep their current boundary. Revision
122 versions earlier planning and changed physical temporaries. Remaining
layout/ARC/optimization/interface/diagnostic work stays in the complete goal.

The shared callback driver now builds one verified catalog per linked pass,
preserves per-artifact original/elided stubs, checks clone provenance and
relinks the result. Inlining admission is an explicit cached product with
budget-bounded weighing; hygiene preserves unchanged binders. This addresses
the preceding hosted POS compile timeout without raising its 180-second limit.
The isolated cold compile improves from 87.02 to 69.09 seconds with all 61
assembly outputs and unit identities byte-identical. Hosted confirmation is
still required; the `5ac6b4d` run is recorded as failed, not green.

Final fixed-source Base validation passes all 136 jobs in 657.10 seconds on six
workers with fresh caches and no reused results or timeout changes. The
saved/new vector-read oracle passes 16 executions, 80 traps and 64 emission
configurations across eight targets. Fresh QOS and Sol compatibility checks
pass. The stage page records the evidence, explicit platform skips and
remaining complete-goal work.

Hosted follow-up: `d14fe58` passed
[Linux CI](https://github.com/hyperswine/fprisc/actions/runs/40260883874),
including the unchanged POS compile timeout.

## Checked Base normalization

[Typed normalization](2026-10-26-TYPED-NORMALIZATION.md) moves literal/local
alias elimination, strict let sinking and let/conditional commuting into
verified closed Core before region planning and erasure. It preserves checked
types, ownership shapes, lexical snapshots and surviving binder identities.
Revision 123 versions changed physical optimization products; ARC/runtime ABIs
are unchanged. Late generated/layout normalization remains explicit, alongside
all other pending rows of this full-goal register.

The final fresh-cache fixed-source Base sweep passes 136/136 jobs in 667.98
seconds on six workers, without reused results or timeout changes. Saved/new
compilers pass 16 native executions, 32 trap checks and 64 emissions across
eight targets. Fresh QOS admission and Sol compatibility/tail-call checks pass.
The first sweep exposed a fusion-diagnostic regression; preserving explicit
vector-producer bindings restores the original diagnostic, effect order and
zero-allocation pure fusion assertions. The stage page records this boundary,
the failed run, final evidence and remaining full-goal work. This checkpoint
still requires its own hosted result after push.
