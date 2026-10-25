# Typed native call staging

Date: 2026-10-25. Kind: implementation and validation record.
Applies after polymorphic code contracts at `aa6e738`.

`Core.Typed.Stage` owns native application grouping and operand snapshots while
checked types and lexical identities still exist. Native lowering runs layout
planning, **source staging**, closure conversion, lexical call resolution and
explicit erasure, in that order. The erased callback specializer still remains;
its operands now have staging boundaries supplied by a checked producer.

## Evidence and stage products

The private `StagedFunction` contains a checked function and its calling registry.
A separate `StagedCalls` product serves later transformations of closed graphs.
Both verify scope, types, shapes and group invariants before publication. A
source-stage function cannot borrow a closed graph's code registry.

Physical arity comes from owned, elaborated source definitions, typed structure
clones, constructor fields, canonical core primitives and explicit lambda/code
parameters. Vector builders retain their remaining argument count after their
layout-evidence operand. An arrow count is not physical arity: a nullary
computation or a one-argument entry can answer another function. Foreign
signatures, including opaque QOS signatures, do not supply runtime callable
arity; their existing native lowering remains authoritative.

Source staging inherits lexical arity through nested lambdas, aliases, stored
partial applications and direct recursive bindings. It runs after layout cloning
so distinct record layouts retain distinct closure identities. It runs before
capture conversion because a captured parameter's scheme alone no longer proves
the outer binding's physical arity. An independent evaluator regression proves
that staging only the closed graph loses that fact and selects the wrong trap.

New temporaries have checked monotypes, type-derived ownership shapes and fresh
`BinderId`s. They neither consume inference variables nor backend label supply.
Freshness checks include existing identities and display/global spellings;
unreferenced calling metadata does not perturb generated locals. Captured
polymorphic schemes and original code identities remain intact. Operands move
through their snapshots once; this does not establish the broader callable-owner
or multiplicity proof still required by the cleanup goal.

Lifted callable entries require an ordinary parameter. Nullary source computations
remain separate entries and evaluate before using their returned value; they are
not silently treated as immutable function descriptors.

## Native call groups

A known entry saturates at its physical parameter count. Its result is explicitly
bound before evaluating operands applied to that result. Stored partials retain
their already evaluated arguments and remaining arity; they are not substituted
back into later call sites.

Unknown callable groups retain the native `applyN` contract: evaluate the head,
snapshot the whole argument group left to right, then invoke it. The snapshots
remain outside later callback specialization/inlining, preventing those passes
from moving an argument after callback execution. Computed heads and CAFs are
snapshotted before their arguments. Runtime primitive/foreign globals retain
established lowering; no arity is guessed from a logical signature.

Exactly saturated known calls retain their ordinary expression form. Layout
builders retain their typed operation, so nested vector pipelines remain visible
to fusion. Staging does not impose blanket administrative normal form on every
scalar operation or nested vector call.

This intentionally fixes two optimizer-dependent behaviors, versioned by codegen
revision **114**. The saved compiler evaluates an extra argument before entering
a known saturated prefix when inlining is disabled. Its default callback
specialization/inlining can instead enter a callback before evaluating a later
argument of an originally unknown group. The new stage fixes both boundaries
before optimization. Numeric results are unchanged in the controls.

Sol bytecode keeps its existing curried application behavior. In particular,
unknown native `applyN` groups and Sol's individual applications need not have
identical interleavings; this work does not migrate Sol or silently claim profile
equality. Saved/new Sol controls agree after substituting Sol's argument reader
for the native fixture's `Sys.args`.

## Validation

The final full Base sweep passed all **136 jobs in 485.47 seconds on
six workers**, with a fresh native cache and no reused coverage. Compiler/test
sources remained fixed throughout that completed run. The focused typed-Core
and specialization suites also passed.

Sol argument/shared-language checks and self/mutual tail calls of 3,000,000
iterations passed (peak 85 MB), with the listing ending in TailCall without a
following Ret. Hosted CI for `aa6e738` passed. Hosted validation of this
integrated checkpoint follows the push.

The native fixture checks known prefixes, stored partials, captured outer
functions, unknown/computed heads, a CAF whose logical type has multiple arrows,
imported checked entries and exact panic priorities. It runs all four
specialization/inlining mode combinations on one hart and both extreme modes on
four harts, reusing cache modes deliberately. x64/RV32/RV64 validate emission;
these fixture checks do not claim physical execution on those targets.

Independent machine-IR evaluation checks before/after trap priorities, optimizer
operand motion, initializer call counts, source-before-capture placement, recursive
scope, retained code identity, monomorphic snapshot types, ownership transfer,
freshness, idempotence and invalid phase/arity refusals. The existing specialization
suite retains the 64,000-byte unspecialized and zero-byte specialized callback
allocation answers, effect/panic checks and warm option-cache transitions.

Local records: `/private/tmp/fpr-staging-{build,focused,native,specialization}.log`,
`/private/tmp/fpr-staging-base.{log,json}`,
`/private/tmp/fpr-staging-{invariants,controls}.log` and
`/private/tmp/fpr-staging-sol-{args,both,tail}.log`.

## Remaining full-goal work

Typed callback cloning and replacement of `Mono` remain required. Callable
ownership/multiplicity evidence, remaining generated/layout forms, downstream
optimization/region transformations, and the other diagnostic/options/machine
contract entries in the cleanup register are also still required. Physical
native ABIs, parser/module Binary formats, context switches and runtime memory
structures are unchanged. QOS needs no compiler-pin change for this checkpoint.
The full compiler cleanup goal stays active.
