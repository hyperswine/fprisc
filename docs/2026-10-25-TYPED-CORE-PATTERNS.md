# Typed Core aggregates and patterns

Date: 2026-10-25. Kind: implementation and validation record.
Applies after `b983812`, the first native typed-expression consumer.

This stage extends the actual native typed lowering path to aggregates and
pattern matching. It also fixes a source-inference error exposed by the new
Core verifier. The [cleanup goal](2026-10-25-COMPILER-CLEANUP.md) remains active:
closure lifting and subsequent transformations still follow an explicit
erasure boundary.

## Checked producers and consumers

`Infer.Pattern` retains each pattern's inferred input type, child types and
immediate binder scope. Parameter, guard, case-arm and local-binding sites
have constructors rather than positional string keys. Scopes are recorded
when the bindings are introduced, before a later expression can shadow them.
`InferenceResult` is now a private record with ordinary readers; it also
carries constructor schemes and explicit local codegen-name assignments.

`Frontend.Desugar.Checked` constructs typed tuples, lists, atoms, records,
field paths, updates, multiple clauses, nested constructor/tuple/record
patterns, guards, interpolation, result pipes and nonrecursive local functions.
It retains semantic patterns and record operations until layout. Constructor
entry points are themselves verified typed functions, and their erased bodies
are the bodies emitted into the native Core program.

`Core.Typed.Verify` checks aggregate fields, constructor instantiation and
arity, pattern input and binding types, guard scopes, unique identities,
reference contracts and ownership-shape consistency. Shared `Type.Relation`
owns type equality, scheme instantiation and field-path lookup independently
of either AST or the inference solver. Shape consistency still does not prove
exactly-once usage; source linearity checking remains responsible for that.

`Core.Typed.Erase` lowers these nodes directly into the existing Core layout,
with explicit constructor/record layout and fresh-name/join callbacks. It
does not reconstruct surface expressions or infer them again. The lexical
identity-to-name check rejects capture when crossing this boundary. Existing
evaluation order, fresh-name order and pattern failure continuations are
preserved.

Missing or inconsistent checking evidence is a compiler error. Recognized
unmigrated forms are explicit migration declines. Plans are reused only for
the exact surface input checked by inference; specialization/per-unit rewrites
still need their own evidence-preserving migration.

## Dictionary constraints and written promises

A generic `(s : Sig)` arithmetic site could previously choose `s.(+)` without
constraining an unannotated member's type before generalization. The typed
projection verifier exposed this on a valid generic function. Inference now
constrains the selected member before SCC generalization and retains a
lexically scoped dictionary witness for the emitted call. Mutually recursive
functions can use different parameter names without selecting another
function's dictionary. A matching member with an incompatible result is
rejected at the provider call.

Written signatures are rechecked against the final solved types after delayed
operator constraints/defaulting. These checks run in isolated solver state,
retaining only their diagnostics, so they do not perturb the checking fresh
supply. Existing early checks and error ordering remain in place. This exposed
the MVU `applyLiveEvs` callback's unspecified `_` parameter: its declaration now
states the relationship already required by its implementation, consuming and
returning the same `env` type.

The dictionary dispatch correction can change emitted programs. The codegen
revision is deliberately **106**, invalidating g105 generated-unit cache keys.
The native physical ABI is unchanged. The MVU source change also intentionally
changes that module's content identity. This is not a claim that source
inference is completely regularized: the older row-only written-generality
limitation and full global definition-contract checking remain open.

## Remaining boundary

Vector layout dictionaries/hidden entry parameters, recursive local bindings,
generated wrappers/hole expansion and specialization clones remain migration
work. Generated layout temporaries and fallthrough joins become untyped at
erasure. Closure lifting, optimization, workers/reuse, region analysis and
backend planning still consume the old Core. Carrying identities and evidence
through those transformations, and eventually removing this bridge, remains
required by the full goal.

## Validation

The expanded Haskell contract fixture checks typed-path coverage, including
constructor stubs; exact erased Core, fresh supply and closure/join output
against ordinary desugaring; stale-plan handling; and malformed aggregate,
pattern, guard, scope, type and ownership-shape rejection. Source-inference
regressions check dictionary member types, lexical witnesses, incompatible
providers and signatures invalidated by numeric defaulting.

An independent native fixture in `tests/typed_core/contracts.fpr` checks
dictionary recursion, failed nested patterns with shadowed captures and record
updates on one and four harts. It prints `typed-core 14 5 10 9` in both runs.
The focused MVU reload suite passes with the explicit callback contract.

The 128 fresh root/dependent-unit assembly comparisons against the saved
pre-frontend baseline pass after normalizing only the intentional g106/g105
revision identity in interface comments, unit filenames and their generated
specialization symbols. The comparison does not normalize instructions or
arbitrary constants. Sol argument/shared-language checks and bounded
3,000,000-iteration self/mutual tail calls pass (peak 86 MB).
All 128 `.abirev` sidecars carry the expected codegen revision transition
from 105 to 106; that sidecar records the codegen revision, despite its name.

Full Base passes **134 jobs in 440.75 seconds on six workers**, with no reused
CI coverage, on the final repaired tree. The existing host/toolchain-dependent
subchecks retain their explicit skips. Hosted CI for the preceding `b983812`
stage passed; this stage's hosted validation follows its own push.
Local logs are `/private/tmp/fpr-aggregate-native-contracts.log`,
`/private/tmp/fpr-aggregate-mvu-repair.log`,
`/private/tmp/fpr-aggregate-g106-parity.log`,
`/private/tmp/fpr-aggregate-final-sol-{args,both,tail}.log` and
`/private/tmp/fpr-aggregate-repaired-base.{log,json}`. No physical-board
execution is claimed.
