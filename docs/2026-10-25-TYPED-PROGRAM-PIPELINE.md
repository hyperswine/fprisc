# Owned typed programs and the native pipeline

Date: 2026-10-25. Kind: implementation and validation record.
Applies after local callback specialization at `83ee345`; codegen revision 116.

Native compilation now consumes an owned semantic program rather than asking
frontend desugaring to close and erase each definition. The actual driver uses
`Frontend.Desugar.Typed`, `Core.Typed.Program`, `Core.Typed.Pipeline` and
`Compiler.Native.Core`. `Frontend.Desugar.Checked` is a compatibility facade.

## Products and owners

The frontend owns source evidence, exact clause selection, semantic expressions
and generated constructor definitions. It performs no native closing or erasure
and has no native fresh-name state. Structure specialization publishes its
generated calling schemes with its function bodies. Physical source arities
come from owned definitions; logical arrows do not supply foreign arity.

The private `Program` product contains the source namespace, type/ownership
context, calling schemes, physical arities, typed definitions and scoped source
assumptions. Its constructor checks definition keys, ordinary parameter roles,
calling interfaces, global references and binder uniqueness across definitions.
Types are retained from checking rather than reconstructed from erased bodies.

`Core.Typed.Pipeline` owns layout planning, operand staging, closure conversion,
lexical resolution and local callback specialization. Its opaque `ClosedProgram`
keeps the semantic input and the layout authority alongside every closed
definition. Verification checks the complete graph: source owners/interfaces,
unique code labels and binders, code contracts and global calling evidence.

`Compiler.Native.Core` owns the explicit erasure boundary. Covered functions
already contain their typed closures and joins; erasure cannot register another
implicit untyped join or rely on untyped lambda lifting. The native product
retains the closed input, erased program, join set and compatibility causes.
Later region/optimization/machine consumers still use the erased projection;
their typed migration remains required.

Compatibility-only source clauses are separate from typed definitions and do
not borrow their old annotations. Only those clauses use legacy lowering and
lifting. The facade preserves a caller's legacy fresh supply, so two stateful
compatibility calls cannot collide on generated helper code. Ordinary native
owned selections never pair changed clauses with old evidence.

Shared clause grouping belongs to frontend traversal. Wide-tuple layout
constants/resolution belong to `Compiler.DataLayout`, with existing compatibility
exports retained. AST/Binary module identity and public native ABIs are unchanged.

## Scoped recursive assumptions

The existing source checker checks signed definitions against their signatures
while recursive references inside the SCC use provisional schemes. These can
differ from the published interface; the IRQ router's heterogeneous mailbox is
an existing user of that rule. Treating every such reference as proof of the
published signature would misrepresent what checking established.

Inference now distinguishes those references and snapshots both schemes without
changing its solver, fresh supply, source interfaces or diagnostics. The semantic
program records each assumption's source expression identity, owner and target.
Ordinary global references must match their published calling schemes. A scoped
exception requires its original checked identity or an explicit typed
instantiation, the correct target/owner and the matching published contract.
Generated references cannot borrow this permission. Ambient free variables stay
rigid when assumptions are instantiated. Closed-program verification retains
these checks after cloning/lifting.

These are explicit source assumptions, not new proofs of ABI type equality.
Structure specialization does not promote an opaque assumed call into a proven
interface. No runtime casts or broader source permissions were added. Later
typed consumers must continue to distinguish these assumptions.

## Identity and namespace compatibility

Private code labels retain their existing role prefix and add a length-delimited
source-owner suffix. Fresh supplies are local to that owner. An unrelated root,
constructor or inference namespace cannot shift a reusable unit's code identity.
Erasure temporaries use an independent owner-qualified supply. Revision 116
versions these private label/cache changes.

Source values retain their existing priority over constructor values. Constructor
layout authority remains available for patterns, while the producer omits a
conflicting constructor value stub. The saved compiler's `Box = Type Int` /
`Box = Struct { value = 7 }` control confirms this established namespace rule.

## Validation and remaining work

`tests/TypedProgram.hs` checks owned schemes/physical arities, malformed global
contracts, cross-definition binder reuse, explicit recursive assumptions and
their identity restrictions, constructor layout contradictions, independent
machine-IR answers, stable unit code, stateful compatibility helpers and
constructor/value priority. It also compiles the complete expanded prelude
through the typed pipeline with no compatibility fallback. The direct prelude
audit before driver precondition insertion contains 236 semantic definitions,
67 recorded recursive references and 248 emitted functions.

The final fresh-cache Base sweep passed all **136 jobs in 527.71 seconds on six
workers**, with no reused coverage and fixed compiler/test sources. The expanded
typed-Core job took 123.83 seconds, and existing specialization allocation/mode
checks passed. Frontend/parser/Binary identity and inference-evidence checks
passed. Saved revision-115 and new native outputs are byte-identical for the
callback identity/effect fixture and the constructor/value shadowing control.
Sol arguments/shared-language checks passed; self and mutual tail calls each ran
3,000,000 iterations with a peak of 85 MB.

Local records: `/private/tmp/fpr-program-base.{log,json}`,
`/private/tmp/fpr-program-contracts.log`, `/private/tmp/fpr-program-prelude-audit.log`,
`/private/tmp/fpr-program-controls-{before,after}.log`,
`/private/tmp/fpr-program-shadow-{before,after}.log` and
`/private/tmp/fpr-program-sol-{args,both,tail}.log`.
Hosted CI for `83ee345` passed; this integrated stage requests its own hosted run
with the push. No physical-board result is claimed.

The full goal remains active: a linked typed
owner across compilation units, global/imported callback specialization and
retirement of `Mono`, remaining source compatibility forms, typed regions and
later transformations, diagnostics and machine/call contracts are still needed.
