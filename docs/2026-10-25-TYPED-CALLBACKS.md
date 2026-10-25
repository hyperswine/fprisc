# Typed local callback specialization

Date: 2026-10-25. Kind: implementation and validation record.
Applies after typed call staging at `18b3c26`; codegen cache revision 115.

Native emission now specializes local callback applications while their checked
types, capture schemes and binder identities still exist. `Core.Typed.Callback`
consumes and publishes an opaque closed-function product. The frontend passes
an explicit mode from the shared compiler options; `FPR_NO_SPEC` and ARC retain
their existing behavior. Cost and source-region analysis retain their existing
unspecialized input.

## Contracts and ownership

Role analysis follows lexical identities through pattern aliases, capture
forwarding and recursive groups. Templates are owned local code entries.
Checked globals can supply callback identities; root/global/imported bodies
are not cloned here. Their migration requires a checked program owner and
receive-region provenance, rather than moving the existing erased pass ahead
of region construction.

Clone keys describe code identities, parameter roles and already supplied
argument counts. They do not create separate copies for Int and Bool uses of
the same polymorphic callback. One fresh type/row solution spans the selected
callback interface, captures, ordinary parameters and result. Capture-local
foralls retain scope. Cloned term identities avoid existing namespaces, and
display names remain independent of inference IDs. Primitive references whose
calling schemas differ by occurrence remain intact when the available schema
does not match; arrow counts do not establish runtime arity.

The pass requires evidence that a callback's actual environment is unrestricted:
manifest immutable data, or recursively known callable environments. An arrow
type by itself supplies no such proof. Unsupported environments retain the
original path. Removal of unused callback bindings and PAP temporaries requires
this recorded proof as well as a pure initializer; arbitrary unused closures
are not discarded by this pass.

Original callback objects remain parameters wherever their identity escapes:
returning, comparing, storing or capturing the callback does not reconstruct its
PAP. A least-fixpoint liveness pass removes forwarding-only callback fields.
Strict operand snapshots retain left-to-right effects, including the arguments
of newly constructed partial applications. Stored aliases retain their original
object and already evaluated operands. Nested lambdas keep their original code
identities across callback clones. Pattern aliases with unsaved partial operands
retain their original path, so a stored prefix is never evaluated again.

Private computation entries have an explicit `EntryCode` kind. Removing a sole
callback parameter can produce a nullary computation, which is invoked directly
and cannot escape as an immutable callable value. Continuations retain
`JoinCode`; a continuation with no remaining fields receives a fresh dummy
argument. Full-graph verification checks call kinds, capture/parameter schemes,
unique binders, code keys and root/code label collisions before publication.

Clone budgets retain the original path: depth 12, 256 clones, 60,000 template
nodes and 64 final physical fields. Provisional callback fields are removed
before enforcing the final arity. If an escaping callback makes an entry too
wide, the graph restores its original call and recomputes liveness. Exported
root arities stay unchanged.

## Compatibility correction

The saved revision-114 compiler reproduces an identity bug in erased `Mono`:
rebinding a stored partial application rebuilt the PAP, and substitution could
also reconstruct a returned callback. The same fixture answers True with
specialization disabled and False with it enabled. The compatibility pass now
preserves stored aliases and declines callback roles that escape as values,
including through forwarding functions. Typed clones retain those original
objects while still specializing their invocations.

Revision 115 versions changed private code and the corrected identity behavior.
Native ABIs, runtime memory structures and context-switch layouts are unchanged.

## Validation

`tests/TypedCallbacks.hs` exercises polymorphic clone sharing, independent
machine-IR answers without `Mono`, fresh identities, ownership refusals,
nullary entries, joins, label collisions, projected 64-field entries and
overflow restoration. The evaluator uses structural PAP representations;
native execution separately checks observable pointer identity.

`tests/check_typed_callbacks.py` checks independent native answers, returned
and aliased function identity, shared nested code, captured polymorphic
functions, partial effects and panics, stable/changing recursive callbacks,
all four specialization/inlining modes, one/four harts, imported owned units,
and A64/x64/RV32/RV64 emission containing actual typed clone labels. The existing
specialization allocation/mode tests remain required. These checks are included
in the existing typed-Core Base job, without a separate redundant build job.

The final fresh-cache Base sweep passed all **136 jobs in 503.92 seconds on six
workers**, with no reused coverage and fixed compiler/test sources. The complete
typed-Core job took 113.89 seconds and existing specialization checks took 31.45
seconds in that sweep. Sol arguments/shared-language checks passed; self and
mutual tail calls each ran 3,000,000 iterations with a peak of 85 MB. The final
saved/new native control differs only in the corrected callback identity result.

Local records: `/private/tmp/fpr-callbacks-base.{log,json}`,
`/private/tmp/fpr-callbacks-focused.log`, `/private/tmp/fpr-callbacks-native.log`,
`/private/tmp/fpr-callbacks-final-{old,new}.log` and
`/private/tmp/fpr-callbacks-sol-{args,both,tail}.log`.
Hosted CI for the preceding `18b3c26` passed; this integrated checkpoint requests
its own hosted validation with the push. No physical-board result is claimed.

The full compiler cleanup goal remains active: program-wide typed
specialization and retirement of `Mono`, callable ownership evidence, later
typed transformations, remaining diagnostics and machine/call contracts are
still required.
