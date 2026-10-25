# Typed vector layout evidence

Date: 2026-10-25. Kind: implementation and validation record.
Applies after typed recursive locals at `605df23`.

Selected native typed entries now retain layout arguments and their element
types through construction, closure conversion and lint. The source handoff
no longer represents vector layout decisions as arbitrary surface expressions.
Hidden parameters and their instantiated call arguments use the same checked
calling schema, preserving the relationship between each descriptor and its
source argument/result types.

## Owned evidence and calling schemas

`Compiler.VectorLayout` owns vector-builder constructors, layout slots,
static/forwarded evidence, canonical descriptor serialization and calling
contracts. A contract identifies a global declaration or a **local BinderId**;
matching a display spelling is insufficient. Inference retains local schemes
with their quantified and captured free variables, then snapshots a calling
schema containing its layout requirements and logical function type together.
It also retains the original body requirements for defining hidden parameters.

`Infer.Elaboration` carries `OpVector`, `OpDeclaredVector` and `OpDictionary`
products with typed evidence. Its surface rewriting API remains a compatibility
renderer, using the shared builder/runtime-symbol mapping. Existing descriptor
spelling, ordering and boxed-default rules are retained.

`TLayout element` is a compiler-private type with no source syntax. It describes
immutable evidence, not an owned element value. Typed Core has layout literals
and vector-builder nodes with verified allocation/from-list/map contracts.
Literal descriptors must agree with their element type; plain strings cannot
be relabeled as evidence. Scheme instantiation links hidden layout types to
the same variables in ordinary arguments and results, so they cannot be
instantiated independently. Forwarded parameters have lexical identities and
scope checks, and retain those contracts when captured by a closure.

`Frontend.Desugar.Checked` creates hidden parameters before ordinary source
parameters and consumes the explicit evidence decisions. Ordinary pattern
parameters keep their source indices; hidden arguments do not invent source
pattern evidence. A layout-dependent `Vec.new` function value gets a typed
lambda before closure conversion. Erasure serializes evidence as the existing
runtime String argument and emits the established `Vec.*As` entry points.

## Correctness fixes exposed by the handoff

Two name/scope failures are covered by independent regressions:

- A local scalar `make = 7` shadowing a generic global `make` was incorrectly
  treated as requiring the global's layout parameters, forcing old lowering.
  The saved `605df23` compiler then returned a large incorrect integer for
  `make + 2`. Identity-owned local contracts keep the checked path and return
  **9**. A parameter named `from` likewise cannot receive a global `from`
  function's schema. Both local bindings and parameters have permanent tests.
- Environment free-variable collection zonked scheme-bound integer IDs as
  though they were solver metavariables. In a file without a prelude,
  `first x = x` became monomorphic and `(first 1, first True)` was rejected.
  Generalization now alpha-renames quantified variables in an isolated snapshot
  before applying substitutions. Free variables retain their scope. The saved
  compiler reproduces the CLI refusal; the new compiler accepts it. Captured
  generic builders test that free outer types stay linked while local arguments
  instantiate independently.

These corrections can change inferred generality and generated helper/layout
code. Codegen revision advances from **108 to 109**; old generated units and
executable identities must not be reused. The runtime calling convention and
context/memory structures are unchanged. Source parser Binary formats are
unchanged; intentional type/schema changes retain the existing checked
interface/arity mechanisms rather than promising old per-function signatures.

## Validation

`tests/TypedLayouts.hs` requires generic, forwarded, local, captured, recursive,
explicit and type-changing vector builders to use the typed/closed products.
It checks independent requirements, local-owner identities, capture and
parameter order, schema linkage, canonical record descriptors and malformed
evidence refusals. `tests/InferenceEvidence.hs` includes the standalone
quantifier-scope regression.

The native fixture executes on one and four harts with heterogeneous layout
arguments, nested captures, an outer free type, recursive construction, explicit
descriptors and name shadowing. Its fixed answer is:

```
typed-layouts 2.5 8 3.5 9 4.5 ok 5.5 6.5 0 7.5 11 9 8.5 1 8.5 True
```

The saved and new compilers agree on all answers for a control whose local
scalar has a distinct spelling. The original shadowing case separately
reproduces the saved compiler's wrong result; that result is not normalized
away as a compatibility claim. Existing generic/imported/recursive vector
limits pass with inline/specialization disabled variants and cached imports.
Sol argument/shared-language and bounded-tail checks pass: 3,000,000 self/mutual
iterations, peak 85 MB, with TailCall and no following Ret.

The first full sweep exposed a kernel-oracle extraction assumption: it excluded
hosted-only constructors by the old `lifted_` prefix. The oracle now retains its
C entry points and transitive assembly/function-object dependencies, including
callback thunks. Needed private helpers remain included regardless of names;
unreachable hosted constructors are excluded. Missing entries are refused.
The F32 Rosetta case passes all 700 map/filter/fold/fallback/yield cases with
that change. The final frozen-tree sweep passed **all 136 Base jobs in 451.99
seconds on six workers**, with no reused CI coverage. Platform/toolchain
subchecks retain their explicit execution/skipping evidence. No physical-board
validation is claimed for this compiler change.

Hosted CI for `605df23` passed
([run 40157205162](https://github.com/hyperswine/fprisc/actions/runs/40157205162));
this integrated stage requires its own hosted validation after push.

Local records: `/private/tmp/fpr-layout-evidence-build.log`,
`/private/tmp/fpr-layout-evidence-focused.log`,
`/private/tmp/fpr-layout-evidence-inference.log`,
`/private/tmp/fpr-layout-evidence-vector-limits.log`,
`/private/tmp/fpr-layout-evidence-differential.log`,
`/private/tmp/fpr-standalone-{before,after}.log`,
`/private/tmp/fpr-layout-evidence-kernel-scope.log`,
`/private/tmp/fpr-layout-evidence-final-base.{log,json}` and
`/private/tmp/fpr-layout-evidence-sol-{args,both,tail}.log`.

## Remaining full-goal work

Generated reference wrappers/holes, computed recursive initializers and
specialization/per-unit evidence still need migration. Layout temporaries,
optimization/workers/reuse and region analysis still follow erasure. Remaining
structured diagnostic producers/ranges and machine/call-convention contracts
also remain required by the [cleanup goal](2026-10-25-COMPILER-CLEANUP.md).
