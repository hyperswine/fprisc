# Checked open-record boundaries

Codegen 185 / ARC revision 23 gives open record rows a stable tagged fallback
in builtin ARC code. A row such as `{x : Word | r}` no longer needs an invented
fixed native layout. Concrete callers convert using their complete checked
shape; the generic entry operates on tagged fields. Lists and other finite
containers of open rows keep their surrounding checked layout, with a tagged
slot for each open record.

This supplies a previously missing C2 boundary contract. It is not an
allocation-elimination or runtime-speedup claim. General Base representation
lowering remains separate work.

## Representation and shape contract

The row variable's identity does not choose storage. An open record always
uses the uniform tagged representation, independent of observed caller order
or the compiler's row-variable ordinal. Closed records retain their complete
checked layouts. Canonicalizing the physical fallback does not change source
type identity or the checked type-instance key.

Record operations dispatch over the compilation unit's complete nominal shape
catalog. Candidates must contain every checked row label and every requested
field. A closed row admits exactly its checked label set. Open rows retain a
tag test even when the catalog has only one candidate. A shape mismatch takes
the next branch; it does not invoke a trapping nominal conversion. The new
consuming tag-test helper releases its input reference and allocates nothing.
Explicit scalar, field and aggregate conversions keep their checked failures.
Checked Bool expressions also retain nominal validation before Boolean use.
Thus matching a hidden payload against `True` can fall through, while using a
hidden Word as an `if` condition still fails rather than silently becoming
false. Checked Bool evidence survives erasure separately from shape matching.

Open updates establish the tagged representation inside each branch, before
unrelated native layouts join. Every constructed field is converted to the
tagged contract, including nested updates. Strict lets and argument evaluation
retain their original order; an unused field can still print or fail.

Typed record-update planning and erasure share the checked shape rule. An
originally open plan may narrow after type substitution or inlining. Erasure
requires every now-admissible branch to be present and every recorded branch
to match the physical catalog, then omits unreachable alternatives. Missing
required branches and foreign nominal shape facts remain errors. Nested
planning follows the checked field type rather than inventing a type variable.
This also prevents concrete Base updates from carrying unrelated record
alternatives into later lowering.

## Boundary limits

The supported schemas are the shapes present in the compiled catalog. This
is not runtime field-name reflection and does not promise interoperability
with arbitrary record shapes created by an independently compiled foreign
library. Missing shapes retain an explicit compile-time refusal or named
runtime shape failure, as appropriate to the operation.

Public open-row entries use the existing tagged object convention. Owned
fields and shared originals retain their reference counts; full-width scalar
fields use checked tagged wrappers. Raw allocation-free exports refuse open
rows before emission. No uniform conversion is silently admitted into raw or
interrupt code.

The static-arena analyzer does not admit the new tag-test call. Updating its
audited runtime-source hash records the changed runtime identity; it does not
extend the admitted adapter set or prove an open-row activation fits an arena.
Existing scalar and nested-product arena recipes require requalification.

## Focused evidence

The [boundary matrix](../bench/2026-11-05-open-rows.json) binds both compiler
hashes and the test source. With specialization disabled, the saved
codegen-184 compiler refuses the public open-row exports and a separate
internal two-shape generic selector. The new
compiler accepts both supported boundary forms.

The matrix covers specialization on/off, soft/hard float ABIs, and C/FPR
allocators: eight successful configurations and 24 expected failure cases.
Each successful configuration checks 128 inputs, including full-width Word
bits, retained originals, extra String/list fields, nested record updates,
recursive helpers, lists of records, F64/F32 signed zero and NaN payloads,
nominal tag/variant mismatch, and complete reclamation. Expected failures
cover wrong scalar kinds, raw field metadata at a tagged boundary, and invalid
tag-test descriptors. Both specialization modes refuse raw open-row exports.

Eight semantic cases agree with specialization enabled and disabled: ordered
nested effects, unused-field and nested unused-field division failures, dead
branches, generic scalar/String payloads, pattern fallthrough across hidden
nominal types, and both integer-overflow endpoints. Hosted Base runs the Int
analogues on one and four workers with ordinary inlining. Base has no builtin
Word HAL, so those host runs are not a same-source raw-Word comparison.
Typed unit checks independently execute closed and nested updates, verify
open-plan narrowing after inlining, and reject missing/foreign shape plans.

The expanded pattern check also found an existing hosted Base crash: lowering
treated a Bool tag test as a truth operation even when its hidden payload was
an integer. The saved codegen-184 executable exits with signal 11; the current
compiler returns `0, 1, 2, 0` for integer, True, False and list payloads in the
[same-source comparison](../bench/2026-11-05-open-rows-bool-pattern.json).
Only a proven IR predicate now uses the Boolean shortcut. Other tagged values
use the existing guarded nominal test, including the immediate-integer guard.
An independent IR oracle checks both Boolean variants against integers and
objects of other types.

## Final qualification

All **41 Haskell suites** and **15 qualification groups** pass. The
[validation manifest](../bench/2026-11-05-open-rows-validation.json) binds the
compiler, source files, test logs and evidence. Coverage includes existing
specialization, aggregate conversion, hidden fields, scalar wrappers, owned
products, raw libraries/interrupts, native Base integration, heap geometry,
heap budgets and registry checks. The production conversion/tag helpers pass
ASan/UBSan coverage. Existing nested-product zero-allocation gates are retained.

The [arena rerun](../bench/2026-11-05-open-rows-arenas.json) passes exact-budget
execution, complete reclamation, guards, short-budget refusals and publication
preservation. This requalifies the existing controlled recipes; it does not
admit the new open-row operations or general application arenas.

The unchanged absolute compiler-allocation gate passes at **1.60 / 32.64 /
67.14 GB** for hello/std-live/pos1. Std-live peaks at **420 MB**. Hello and
std-live remain close to the existing +10% ceilings, at +9.4% and +9.1%; broad
Base activation still needs to meet these limits. The
[C2 scaling gate](../bench/2026-11-05-open-rows-cost.json) retains exact assembled
code-size/function-count parity through 256 helpers, with **1.000–1.001x**
compiler allocation versus explicit monomorphic twins. No baseline or budget
was relaxed.

These are local host, emulator and sanitizer checks, not physical-board timing
or remote CI evidence. Broader Base canonical layouts, one-field owned builtin
wrappers, general variants, scheduling time bounds and general-application
arena admission remain unfinished roadmap work.

The subsequent [codegen-186 milestone](2026-11-05-OWNED-WRAPPER-PAYLOADS.md)
implements the one-field owned-wrapper item using private payload results.
