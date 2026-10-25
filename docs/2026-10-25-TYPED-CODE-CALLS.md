# Typed polymorphic code calls

Date: 2026-10-25. Kind: implementation and validation record.
Applies after typed structure specialization at `a258266`.

Native closure and join contracts now quantify their generic interface variables.
A call checks its capture schemes, arguments and result in one instantiation
before erasure. `Core.Typed.Resolve` consumes the checked closed product and
resolves known saturated lexical closure calls to explicit `CodeCall` nodes,
retaining the original code identity. This is a prerequisite and first consumer
for migrating function-argument specialization; it does not retire `Mono`.

## Contract ownership

`Core.Typed.Contract` owns code-contract construction and instantiation. A code
interface contains separate capture-value schemes and the ordinary parameter/
result arrow. A captured let-polymorphic function keeps its own forall, distinct
from the code entry's interface quantifiers. Ordinary root/code parameters must
be monomorphic; a checked transformer cannot publish a rank-two argument under
a rank-one arrow contract.

Variables free in referenced authoritative global schemas remain rigid. This
includes globals reached through other code entries; the code graph reaches a
fixpoint. The checked source producer supplies its calling schemas. An embedded
reference monotype is not treated as an authoritative declaration of a global's
polymorphism. The compatibility `closeFunction` entry uses embedded schemas
conservatively when no external registry is supplied.

Contract quantifiers are freshened away from all caller variables. Captured
schemes alpha-match by bound-variable occurrences with unordered record fields,
then share one type/row instantiation with the ordinary arrow. Capture-local
quantifiers become rigid skolems and cannot escape into outer code quantifiers.
A mismatched capture/result, weakened capture forall, invalid row, unknown code
identity, wrong code kind or unsaturated explicit call is refused. Shape
annotations are checked in their own scope rather than comparing the spelling
of a generic shape with its concrete instance.

The private closed product retains its global registry. `closedContracts` derives
contracts from its current code graph; `mapClosed` checks the complete transformed
product, including unique binder identities, before returning it. Native erasure
uses that product's contracts for the root and every generated entry.

## Resolution and preserved behavior

The resolver follows value aliases by `BinderId`, including source notes. A known
saturated closure call becomes `CodeCall CodeId captures arguments`, with checked
physical arity. It neither clones code per use type nor replaces escaping closure
values. Generic Int/Bool uses can therefore share a code identity, including a
helper that returns a capture-free function independently of its argument type.

Manifest immutable captures can be passed directly while retaining the original
closure binding. Callable values, owned values, type variables, open rows and
opaque containers stay on the existing call path. Arrow types alone do not prove
that a callable's environment is unrestricted; removing that gate requires the
callable-ownership evidence from the broader cleanup goal.

Stored partial applications also stay on the existing path. They may have already
evaluated effects and generalized their value types. A future staging transform
must preserve those facts before specializing them. Computed callees, global CAFs
returning functions, and indirect/escaping callbacks keep existing semantics.
The native fixture fixes default evaluation order for saturated and oversaturated
calls, computed callees and a CAF returning a function. Saved/new controls also
preserve each optimizer mode. They record an existing native discrepancy when
specialization and inlining are both disabled: an overapplication evaluates its
later argument before entering the earlier call; default native and Sol enter
the earlier call first. Resolving that existing discrepancy belongs with checked
argument staging and its explicit compatibility decision, not a silent change
in this contract migration.

Codegen revision **113** distinguishes generated code/cache entries. Module/parser
Binary formats, physical native ABIs, context switches and runtime memory
structures are unchanged. QOS requires no pin change for this compiler-only
checkpoint.

## Validation

The full Base sweep passed all **136 jobs in 475.13 seconds on six
workers**, with a fresh native cache and no reused coverage. The compiler and
test sources stayed fixed throughout that sweep. A subsequent defensive gate
tightening also checks the context's actual ownership shape, even for a familiar
scalar spelling. The complete focused typed-Core suite passed again after that
tightening with a fresh native cache; no additional full local sweep is claimed
for that last guard. Hosted validation of the committed integrated head follows
the push. The preceding `a258266` checkpoint's hosted CI passed.

Sol argument/shared-language compatibility and measured self/mutual tail calls
of 3,000,000 iterations passed (peak 85 MB); the listing ends in TailCall without
a following Ret.

The new native fixture asserts exact effect order and code identity on one/four
harts. x64/RV32/RV64 checks validate emission, not physical execution. Saved `g112`
and new `g113` compilers return identical effects and answers in each of native
and Sol, with specialization/inlining enabled and disabled. The fixture retains
an existing profile difference: native compares the returned capture-free code as
equal, whereas Sol compares those returned function values as unequal. Both
compilers agree within each profile; this pass does not change Sol's equality.

The existing specialization suite retains its 64,000-byte unspecialized and
zero-byte specialized callback allocation answers, exact effects/panics, warm
option-cache transitions and A64/x64/RV32/RV64 emission checks. The new invariant
checks cover linked capture/type/row instantiation, alpha-equivalent polymorphic
captures, quantifier escape and caller-variable refusals, transitive global
rigidity, shared generic code identity, source-producer coverage, checked-product
publication, owned/callable capture gates and malformed calls.

Local records: `/private/tmp/fpr-codecalls-{build,focused,specialization,base}.log`,
`/private/tmp/fpr-codecalls-base.json`,
`/private/tmp/fpr-codecalls-{differential,final-differential,extra}.log` and
`/private/tmp/fpr-codecalls-sol-{args,both,tail}.log`.

## Remaining full-goal work

Function-argument specialization in `Mono`, typed argument staging, callable
ownership/multiplicity evidence, remaining layout/generated forms and downstream
optimization/region transformations still need migration. Other outstanding
options/diagnostic/codegen/ABI contracts in the cleanup register also remain
required. The full compiler cleanup goal stays active.
