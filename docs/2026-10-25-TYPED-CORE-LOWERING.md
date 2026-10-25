# First native typed-Core lowering

Date: 2026-10-25. Kind: staged implementation record. Applies after `ba8304b`;
part of the [compiler cleanup goal](2026-10-25-COMPILER-CLEANUP.md).

## Actual native consumer

Native compilation prepares `Frontend.Desugar.Checked` plans from the existing
inference result. Covered source groups construct `Core.Typed.Syntax.Function`
values during desugaring, verify them, and erase through `Core.Typed.Erase`
before the remaining untyped closure-lifting and optimization passes. The
emitted code comes from this checked lowering for covered groups; it is not a
second analysis whose result is discarded before the old lowerer runs.

Typed local references contain `BinderId`, separate from their display names.
Binders carry checked schemes and ownership shapes. Expressions carry final
checked types, ownership shapes, source checking occurrence IDs and offsets;
generated argument aliases, sequencing temporaries, arithmetic applications
and Bool tests have explicit types. Generated binders use a separate namespace
including the owning function, and the existing desugarer's fresh-name supply.

`Core.Typed.Verify` checks scope and binder uniqueness, scheme instantiation,
application/lambda/let/branch types and the consistency of ownership shapes
with types. Row fields compare independently of order; quantified row tails
match residual fields while free type variables stay rigid. Erasure resolves
local identities through the lexical environment and refuses display spellings
that would capture a different local or a global.

Ownership shapes are now derived by `Ownership.TypeShape`, shared by inference
and Core lint. That rule is independent of the inference solver. Consistent
shape annotations are not a proof of exactly-once use or capture safety; the
existing source linearity checker still owns those checks.

`Infer.Elaboration` owns the existing operator/layout target vocabulary,
marker application and marker spelling. Evidence also retains each checking
occurrence's immediate rewritten expression, so lowering can distinguish a
plain reference from a synthesized wrapper without re-inferring it. The
checker verifies source/local-reference spelling consistency when sealing.

## Stage product and migration boundary

The opaque `Desugared` product exposes the Core program, the typed functions
actually used at this stage, and their type context through ordinary accessors.
`prepareChecked` separately reports planned entries and migration declines.
Constructor stub construction and clause grouping have a shared implementation
with ordinary desugaring, preserving the existing fresh-name sequence.

Covered forms are single, unguarded variable-parameter clauses containing
variables, integer/string literals, applications, lambdas, ordinary value
bindings, resolved binary calls, pipes, sequencing and exhaustive two-arm Bool
cases. The focused fixture checks that these entries actually appear in the
typed stage product, including shadowed/captured locals and an owned parameter.

The bridge uses an exact surface-input comparison before reusing a plan. A
specialization or per-unit rewrite that changed the body has not preserved
typed evidence yet, so that input uses its own existing lowerer. Unsupported
source forms are recorded as migration declines. A selected typed function
that fails its verifier is a compiler error, not a silent fallback.

**The full typed-Core migration remains incomplete.** Aggregate patterns,
records/updates/projections, constructors/lists/interpolation, pattern guards,
multiple clauses, recursive/function local bindings, vector dictionaries,
hole wrappers and specialization clones still require typed lowering. Closure
lifting, worker creation, reuse, region helpers and subsequent Core passes
still operate after the explicit erasure boundary. This stage is not evidence
that any of those transformations preserves types or binder identities.

The next steps must move those forms and transformations across the boundary,
retain their generated types/identities, and remove the compatibility bridge.
Neither a subset of migrated functions nor a green existing backend verifier
completes the architecture goal.

## Validation

`tests/check_typed_core.py` checks actual typed-path coverage, exact Core
erasure, unchanged fresh-name state and unchanged closure/join lifting against
ordinary desugaring. It checks the stale-plan boundary separately. Malformed
scope identities, reference/application/lambda/let/branch types and weakened
ownership annotations are refused; polymorphic and row instantiation have
positive and negative checks. An erasure test refuses identity capture by a
display spelling.

Build and native scalar compilation passed. Full Base passed **134 jobs in
420.73 seconds on six workers**, with no reused CI coverage. The three existing
host/toolchain-dependent subchecks retain explicit skips.

Fresh output/unit directories matched the saved pre-frontend compiler at
`04206f1` for **128 root and dependent-unit assembly comparisons**, including
unit cache keys, across RV32/RV64/A64/A64mac/x64/x64mac/qx64/qa64. This cumulative
oracle covers default, worker/reuse-disabled and selected fusion-disabled
configurations. The original parser Binary/module-identity oracles also passed
within Base; there is no cache-format or codegen-revision change.

Sol's argument/shared-language fixtures and 3,000,000-iteration self/mutual
tail-call checks passed (peak 86 MB). Local records:
`/private/tmp/fpr-typed-core-{focused,evidence,build,base,parity}.log`,
`/private/tmp/fpr-typed-core-base.json` and
`/private/tmp/fpr-typed-core-sol-{args,both,tail}.log`.
No physical-board execution is claimed.

## Subsequent stage

[Typed aggregates and patterns](2026-10-25-TYPED-CORE-PATTERNS.md) records the
next implemented source forms, typed constructor emission and the dictionary
inference repair with codegen revision 106. Coverage and unchanged-revision
statements above describe this first stage at `b983812`; the newer record
states the current boundary and intentional cache identity change.
