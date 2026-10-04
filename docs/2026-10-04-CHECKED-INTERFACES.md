# Checked interfaces at commit

Date: 2026-10-04. Next prerequisite after the
[MVU runner slice](2026-10-04-LIVERELOAD-RUNNER.md).

## What changed

`fpr commit` now obtains an inferred interface from the normal compiler checker
for both the candidate and the prior stored version. The interface callback
runs only after type, safety, linearity and declared cost checks have accepted
that version; there is no parallel checker or diagnostic-text parser.

The library checker compiles an empty wrapper importing the library. Loader
metadata identifies the actual library hash and its exports: the wrapper's own
root has no exported functions and must not be used as the interface. Every
export must have an inferred type; a missing inferred export is a refusal.

Type identities preserve function/tuple/application structure, sort record
fields, alpha-normalize type and row variables in separate namespaces, and
preserve repeated-variable relationships and open/closed rows. Qualified
nominal names retain their unit hashes. Changing an own nominal type's unit
version is therefore incompatible even if its written constructor shape stayed
the same: runtime tids change with that hash. Structural record identity does
not acquire a nominal unit hash.

A patch retains every old exported binding's checked inferred type, arity,
written signature and complete contract entries. Preconditions, measures,
unsafe markers, work/alloc/live/size bounds and linear type declarations all
participate. Diagnostic source offsets are erased before comparing written
contracts. New exports are allowed. Inferred equality is conservative: this
is not semantic subsumption, contract implication or budget inequality solving.

For example, an unannotated `op x = x + 1` changing to `op x = x + "!"` now
requires `--major`. Adding another export or changing a body while retaining
its interface remains a patch. Exact content remains a checked no-op.

Missing, malformed or hash-mismatched prior blobs refuse classification;
they never become an empty compatible interface. Dependency blobs are copied
into the store only when a version is actually published. Refused candidates
leave the store and version database unchanged.

## Verification

`tests/check_commit_interfaces.py` is in the Base gate. It checks type changes,
polymorphic restriction, repeated-variable relationships, record requirements,
constant representation, preconditions, unsafe markers, bounds, nominal version
identity and linear declarations. Each incompatible candidate refuses without
store mutation, then succeeds with an explicit major publication. It also checks
alpha normalization, sorted fields, export additions, checked no-op, type errors,
missing/malformed/tampered prior blobs, rejected new dependency publication,
pinned closure lookup after scratch removal, and stable contract identity after
source locations shift.

The full Base suite, signature/coverage/measure suite and cost suite passed.
QOS real-image reloads passed on one/four harts, and its existing MVU engine and
multi-client browser checks passed (focused smoke 2/2). Full QOS check-all was
not run for this checker-only increment.

## What this does not certify yet

Commit interfaces are recomputed under the current checker and prelude.
Runtime serialization and comparison are now implemented separately in
[RUNTIME-INTERFACES](2026-10-04-RUNTIME-INTERFACES.md). Those stamps include
checked types/contracts and compiler/target/prelude context, with opaque
boundaries refusing reload. They are claims for trusted images, not signed
proofs, and end-to-end content identity checking is still open. Old versions
that no longer pass the current checker must be migrated explicitly; there is
no silent inference fallback. Declared result-size bounds remain assumptions
in the existing cost system; retaining one does not prove it.
