# Typed structure specialization

Date: 2026-10-25. Kind: implementation and validation record.
Applies after checked unit ownership at `84fda39`.

Native structure specialization now transforms checked Core functions before
record-layout planning and closure conversion. It instantiates existing checked
signatures and expression annotations, clones introduced binder identities and
rewrites calls to verified clones. It does not reconstruct types from rewritten
surface syntax or erased Core.

## Owned stages

Inference retains the signature/structure tables belonging to its checking run.
`CheckedPlans` owns those tables, its exact source clauses and the semantic
specialization context. The private `SpecializedSource` product prepares the
typed transformation once and retains the surface result required by existing
analyses and compatibility-only entries. Native consumers select owners from
that product rather than supplying replacement bodies with old annotations.

Checked source parameter identities and names are now local to their function,
independent of the backend label supply. Pure typed-function construction can
therefore be shared across root/cost projections. Units keep their separate
checked projections and versioned lowered-input cache contracts.

`Core.Typed.Specialize` owns the worklist and checked clone contracts. It uses
global reference identity, signature parameter positions, concrete structure
schemas and the source application's provenance. Repeated calls with the same
structure share a clone; unrelated ordinary arguments remain polymorphic.
Recursive/mutually recursive clones register their contracts before walking
their bodies. An unavailable typed callee defers the containing entry without
publishing partial clones. Compatibility-only clones are retained only when
needed by compatibility entries.

The existing source application gate, clone names, dictionary-argument removal
and template-selection policy are retained. Aliases and pipelines do not gain a
new specialization policy here. Multi-clause templates still follow the source
pass's existing last-clause selection. Function-argument specialization in
`Mono` remains a separate, not-yet-typed transformation.

## Type and identity transformation

`Type.Substitution` operates on already checked types with an explicit flexible
variable set. Ambient variables stay rigid. Type/row cycles and incompatible
closed rows are refused, open rows share a fresh residual tail, and fresh
supplies avoid source variables. Substitution alpha-renames quantified local
schemes away from its images, preserving captured free variables.

`Core.Typed.Instantiate` applies that substitution throughout expressions,
binders and patterns. Every introduced term identity gets a fresh clone
namespace; free references retain their meaning. Ownership shapes follow the
instantiated types. Ordinary and provider polymorphism, hidden layout evidence
and captured local schemes retain their relationships. Clones pass Core lint
before layout/closure conversion, and their closed products are verified too.

Member projections become checked direct globals only when the flat global's
calling schema matches the checked member value. A member that already captures
hidden layout arguments retains its typed record-field access. Checked
precondition entries remain the selected direct targets.

## Verified correctness changes

Saved-compiler probes establish intentional corrections:

- A local function named like a generic global was rewritten to the global's
  clone. The saved compiler prints **4** where the local function returns
  **102**. Typed references distinguish the bindings. The shared surface pass
  now also tracks parameters, lambdas, recursive/block bindings, case patterns
  and left-to-right pattern-guard scope, fixing Sol and compatibility analyses.
  Its existing traversal/error ordering is retained.
- A record field can hold a function with its layout argument already applied.
  Replacing that value with the raw global loses an argument. The saved native
  compiler builds the probe but panics with **Vec.get: not a Vector**. Retaining
  the checked field value returns element **3** and length **1**.
- A specialized function containing a captured recursive local previously lost
  its checked binding during surface cloning and was refused as an unknown
  `$localVector.loop` primitive. The saved compiler reproduces that refusal;
  the typed clone retains its recursive identity and returns **9** in the fixture.

Codegen revision advances from **111 to 112**, versioning generated code,
native cache identities and checked interface stamps. Native calling
conventions and runtime/context memory structures are unchanged. Source parser
Binary data and module content hashes are unchanged. Sol retains its bytecode
pipeline and executable-identity cache invalidation.

## Validation

`tests/TypedStructs.hs` requires typed/closed clones and checks exact evaluator
answers, fresh identities, rigid/cyclic/row refusal, capture avoidance, ordinary
and provider polymorphism, hidden layouts and compatibility deferral. Its scope
cases include a later pattern guard shadowing an earlier global call.

The native fixture exercises transitive/mutual specialization, a captured
recursive local, F64 carriers, polymorphic local captures, nullary clones,
layout-dependent closure identity and both forms of layout evidence. One/four
hart answers and x64/RV32/RV64 emission pass. The new fixture's execution proof
here is host-native A64. The isolated shadowing case also returns 102 under Sol.
Existing higher-order contract tests cover guarded structure-member calls.

The focused suite passes. The final sweep passed **all 136 Base jobs in 666.05
seconds on six workers**, with no reused CI coverage and a newly created native
cache directory. The expanded Core job took 75.1 seconds. Existing platform and
toolchain subchecks retain their explicit execution/skipping evidence; no
physical-board validation is claimed. An initial sweep was deliberately stopped
to correct a new test's record ownership annotation; the final run kept its
compiler/tests frozen throughout.

Saved/new controls agree on the fixed structure answers, including ordinary and
provider polymorphism, F64 carriers, captures, hidden layout parameters and
closure identity. The three corrections above are tested separately rather
than normalized away. The shadowing probe changes from 4 to 102 in both native
and Sol. Sol argument/shared-language compatibility and bounded tail calls pass:
3,000,000 self/mutual iterations, peak 85 MB, with TailCall and no following Ret.

Hosted CI for `84fda39` passed
([run 40164304562](https://github.com/hyperswine/fprisc/actions/runs/40164304562));
this integrated checkpoint requires its own hosted validation after push.

Local records: `/private/tmp/fpr-struct-build.log`,
`/private/tmp/fpr-struct-contracts.log`, `/private/tmp/fpr-struct-focused.log`,
`/private/tmp/fpr-struct-{base.log,base.json,cache-path.txt}`,
`/private/tmp/fpr-struct-differential.log`, `/private/tmp/fpr-struct-sol-{args,both,tail}.log`,
`/private/tmp/fpr-struct-shadow-{before,after}-{build,run}.log` and
`/private/tmp/fpr-struct-layout-member-{before,after}-{build,run}.log`.

## Remaining full-goal work

Function-argument specialization, remaining generated/computed-recursive forms,
typed layout temporaries and optimization/worker/reuse/region passes still cross
the compatibility boundary. Full pipeline lint, remaining diagnostic/span
producers, calling-convention/machine contracts and obsolete references remain
required. This stage does not complete the compiler cleanup goal.
