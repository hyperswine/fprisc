# Static function optimization and experimental defunctionalization

Date: 9 November 2026. Status: design and implementation phases, not implemented.
The proposed defunctionalization flags below do not exist yet. The initial
[census and shared callable summaries](2026-11-09-CALLABLE-CENSUS-AND-SUMMARIES.md)
are implemented as opt-in, analysis-only `--callables` diagnostics. Keep this experiment opt-in until its
semantic, performance, compiler-budget and QOS pairing gates pass.

## Intent and limits

Keep lambdas, higher-order functions and partial application convenient in source,
while removing as much generic function machinery as possible from native code.
Combine existing specialization, lifting and inlining with defunctionalization
of the function values that survive. Measure the outcome before choosing whether
to broaden the experiment or promote any part of it.

Defunctionalization replaces a finite family of possible function values with
ordinary tagged data and a generated dispatcher. It can remove generic PAP
objects and generic application without removing all runtime state: captured
values still need storage, and a tag may still select the code to execute. A
finite set of constructors does not bound how many values are allocated, the
size of recursive environments, recursion depth or execution time.

Track these distinct achievements separately:

- Fewer dynamic PAP/closure allocations.
- No reachable generic application calls in the selected application domain.
- No PAP descriptors or values at its remaining runtime boundaries.
- No dynamic callable dispatch at all: every call has a statically selected target.

The final property is stronger than defunctionalization. A generated case dispatch
is acceptable in the defunctionalized mode but would fail a future direct-call-only
profile. Neither property alone proves finite WCET or QOS admission.

## Six-part direction

1. **Specialize higher-order calls.** When a callback is known, generate or reuse
   a checked worker with a direct call. Share equivalent specializations and cap
   code growth. Carry callback identity and captures across imports instead of
   rediscovering them after erasure. Unknown targets remain explicit.
2. **Keep partial application symbolic during optimization.** Represent the
   known callee, remaining parameter schema and already evaluated arguments in
   typed IR. Materialize a runtime value only when a surviving use requires one.
   Supplied expressions retain their original evaluation point and multiplicity.
3. **Lift captures into ordinary parameters.** Rewrite eligible local calls to
   direct code calls with captures supplied explicitly. Preserve capture
   ownership/multiplicity; an arrow type alone is not evidence that its hidden
   environment can be copied or discarded. Remove a binding only when its uses
   and lifetime obligations permit removal.
4. **Propagate facts across imports, returns and containers.** Solve call-target
   flow through parameters, results, branches, tuples, records and supported
   recursive containers. Preserve declaration ownership and contract provenance.
   Unsupported/open flows report unknown, rather than treating the visible
   lambdas as an exhaustive target set.
5. **Choose capture storage after escape/lifetime analysis.** Use registers,
   ordinary arguments, stack storage or existing actor state where justified;
   otherwise use a correctly owned concrete environment. Allocation, stack,
   regions, messages and emission must consume the same representation plan.
6. **Offer an enforceable restricted profile.** Eventually reject unresolved
   callable representations or dynamic dispatch when the selected profile
   forbids them. Explain the escaping value, open boundary or failed proof and
   its source location. Distinguish a no-PAP profile from a direct-call-only one.

Defunctionalization supplements steps 2–5; it must not preempt profitable direct
specialization by prematurely turning every lambda into an allocated record.

## Current implementation anchors

The inspected checkout is based on `195edfc`, with concurrent edits in Compile
and callback trimming. This design does not modify those edits.

- `Core.Typed.Callback`, its `Catalog`, `Analysis`, `Model` and `Trim` modules
  already track checked code identities, known callbacks and captured arguments.
  The [capture extension](2026-11-09-P2-TYPED-CLOSURE-CAPTURES.md) admits closed,
  non-linear arrow-free captures, including supported nominal containers; arrow
  captures still require environment ownership evidence.
- `Core.Typed.Syntax` has `ClosureValue`, `Apply`, `CodeCall` and `CodeContract`.
  `Core.Typed.Pipeline` and `Compiler.Native.Linked` retain owned definitions
  and cross-artifact verification before erasure.
- Compile currently runs checked list fusion, callback specialization,
  inlining/re-specialization, known-case reduction, vector-read planning,
  normalization, vector fusion and TRMC before region placement.
- `Codegen.Lower` still emits generic application. `runtime/fpr.h` defines PAP
  descriptors, while `runtime/runtime.c` implements `fpr_applyN` and PAP traversal.
  Actor entry APIs in `runtime/actors.c` test `T_PAP`; `runtime/vec.c` and
  `runtime/mod.c` also depend on PAP representation. Consequently, removing PAP
  construction from source functions is not a whole-executable no-PAP result.

## Proposed opt-in interface

| Invocation | Intended behavior |
| --- | --- |
| Default / flag absent | Existing pipeline and ABI; no defunctionalization |
| `--defunctionalize` | Transform supported closed families; preserve existing representation at unsupported flows and report each fallback |
| `--defunctionalize=strict` (later phase) | Require the stated reachable application/runtime-boundary domain to contain no PAP construction, descriptors or generic apply; fail with located reasons otherwise |

A standalone library, dynamic-loading boundary or incompatible profile cannot
silently satisfy strict mode. Initial support is native hosted Base on the host
64-bit target. Sol, builtin/raw, ARC, QOS, foreign callbacks and RV32 are excluded
until separately qualified; an unsupported target/profile combination must fail
option validation, even in experimental mode.

Every invocation produces a summary with converted families, singleton/direct
calls, dispatcher calls, new environment allocations, retained PAP sites and
boundary adapters. Detailed remarks carry source identities and fallback reasons.
Keep the default compiler quiet. Include the mode, model/schema revision and
family/layout dependency identity in unit/cache keys. Warm caches must not mix
normal and experimental representations.

## Typed design

### Family discovery and ownership

Introduce a demand-driven finite-target analysis rooted in emitted entry points.
Use existing code/artifact identities, not textual function names. A family is
partitioned by a compatible checked callable schema and ownership convention;
representation compatibility alone does not justify merging families. Branches
join target sets; recursive strongly connected components reach a fixed point.
Set size, specialization depth and analysis work have explicit budgets. Unknown
or budget-limited is not an empty set.

Each member records its code identity, capture fields, supplied argument prefix,
remaining arguments, result schema, contracts and provenance. Partial application
creates a member with additional evaluated fields, not a generic PAP. Recursive
function-valued environments require recursive family/layout evidence; open or
polymorphically growing families remain unsupported until proved representable.
Do not merge incompatible existential/polymorphic environments by dropping types.

### Rewrite and placement

Run family discovery on the checked linked program after the profitable existing
higher-order/fusion passes and before region placement and representation erasure.
Retain a stable discovery snapshot, then rewrite and verify the whole affected
producer/consumer set. Initially place the materializing rewrite after current
TRMC, before `Regions.placePrograms`, so existing list/vector callback recognition
is preserved. If a later iteration moves it earlier, demonstrate that fusion and
TRMC opportunities survive or migrate their consumers in the same change.

Generate private family constructors and typed dispatchers through the shared
layout/representation authority. A dispatch case unpacks the member's fields and
calls its existing code directly. Nullary members should use an existing compact
constant representation where supported. A singleton family can become a direct
call with explicit captures. Subsequent known-case reduction/inlining can remove
remaining tags/dispatches where proven.

Do not encode generated closures as hand-built erased `CMk` nodes or introduce a
second layout planner. Extend typed verification and lowering together if the
existing nominal machinery cannot express the generated family. Remap ownership,
source origins, summaries and dependent evidence, and re-run verification before
emission. Keep family tags private to the linked image unless a versioned public
protocol explicitly defines them.

### Illustrative transformation

Pseudocode, not proposed surface syntax:

```text
makeAdder n = \x -> n + x
choose flag n = if flag then makeAdder n else (\x -> x * 2)

-- Residual family after direct specialization/lifting:
IntCallback = Add {n : Int} | Double
invokeInt callback x = case callback of
  Add n  -> addCode n x
  Double -> doubleCode x
```

`Add n` retains runtime state. Storing many adders may still allocate many
ordinary records. Whether the record is scalarized, stack allocated or heap
allocated is a representation/lifetime decision. `invokeInt` is finite dynamic
dispatch until the tag becomes known.

## Implementation phases and replacement gates

| Phase | Implementation | Replaced or deleted | Exit evidence |
| --- | --- | --- | --- |
| D0: baseline and semantic audit | Census callable creation/application, boundaries, arity stages and observables; freeze representative inputs and current output/trap traces | Nothing | Account for generated PAP sites, static descriptors and runtime consumers; settle function identity/inspection behavior |
| D1: typed family analysis | Finite targets, joins/SCCs, stable family identities, capture/argument schemas, unknown reasons and budgets; diagnostic mode | No runtime path | Unit tests for joins, returned/stored functions, recursive/open flows and deterministic identities; no emitted-code change |
| D2: first working flag | Closed, monomorphic, non-linear scalar captures; branch-selected and returned callbacks; supported partial applications; constructors/dispatchers and cache partitioning | Generic application and PAP construction only at converted sites | Experimental/default differential tests; new objects and dispatch overhead reported; no silent conversion failure |
| D3: imports, containers and ownership | Cross-unit family propagation, concrete products/nominals, nested callbacks; capture multiplicity and recursive environment verification | Supported duplicated callable discovery; more PAP sites | Import-edit invalidation, polymorphic/linear negative cases, region/ARC evidence before enabling those profiles; no use-after-free or lost finalization |
| D4: runtime boundaries and strict mode | Explicit protocols/adapters for actors, collection callbacks, foreign/HAL entries and exports; executable-domain audit | Generic PAP ABI only at individually migrated boundaries; no blanket runtime deletion | Strict mode rejects every remaining reachable PAP/apply/adapter site; final-code audit plus runtime counters; public ABI and QOS paired validation |
| D5: specialization and promotion | Dispatcher simplification, capture scalarization, code sharing and target cost tuning; qualify RV32 separately | Obsolete private paths only when no supported consumer remains | Semantic tests, runtime/code-size/compiler budgets and target checks justify promotion; default remains unchanged until then |

D2 must handle both a residual choice between at least two functions and a partial
application capturing a runtime value. A flag that merely repeats existing direct
callback specialization is not a defunctionalization experiment. Initially reject
or report unsupported arity patterns instead of implementing them approximately.

D4 strict validation must inspect the final reachable representation and runtime
boundary manifest, not merely scan source or count generated dispatcher names.
Runtime counters exercise selected paths; they cannot prove absence on unexecuted
paths. An adapter that reconstitutes a PAP is a visible fallback and fails strict
mode. Unreachable linked support symbols are reported separately from reachable
PAP operations; a claim that the ABI/runtime is deleted additionally requires no
remaining consumers, including library/exported entries.

## Semantic and evaluation gates

Preserve the current application-spine semantics for saturation, under-application
and over-application. Audit where current code evaluates supplied operands versus
invoking intermediate results; do not assume a rewrite of curried syntax preserves
that order. Evaluate captured/supplied expressions exactly as often as before.
Preserve precondition checks, fallback behavior and blame through direct, escaped,
partial and generated-dispatch calls. Retain scheduling obligations and the
semantic policy's explicit allocation/resource-failure rules.

D0 must examine equality/identity, hashing, printing, serialization, arity
inspection, foreign pointer use and dynamic module APIs for observable callable
behavior. A changed function representation cannot silently change those results.
Unsupported observations need a compatibility boundary or a documented profile
restriction before transformation. Distinct closure constructions must not be
interned merely because they share code if their identity is observable.

Fixtures must include:

- Known lambdas, branch-selected functions, escaping `makeAdder`, repeated use,
  a list/record of callbacks, callbacks capturing callbacks and recursive families.
- Partial application with effectful or trapping supplied operands, saturation,
  over-application and functions returning functions; precondition failure order.
- Imported wrappers and two same-named declarations from different artifacts;
  edited dependencies with warm caches and mode toggling without a clean build.
- Unknown foreign targets, open polymorphism, recursive family budget exhaustion,
  linear captures, arena escape and actor/message boundaries: supported cases
  preserve semantics; unsupported ones give explicit fallback/refusal evidence.
- Shared environments and allocation pressure, pending actor callbacks, cleanup
  and failure paths. Existing fusion, ownership and contract regressions remain gates.

## Measurement and decision criteria

Compare matched builds of the same input/compiler with the flag off/on, retaining
normal lifting, specialization and fusion in both. Start with focused residual
callback fixtures, then the pipeline corpus and representative QOS programs.
Report correctness first and separate host execution, cross compilation and board
execution. Use runtime probes only for attribution; measure speed separately in
uninstrumented runs.

Record dynamic PAP allocation count/bytes, ordinary environment allocation
count/bytes, generic apply calls, dispatcher calls, native instructions, stack,
spills, code size, compiler allocation/peak memory/time and runtime distributions.
Record zero-capture descriptors separately from dynamic allocation. No-PAP is not
a performance result: dispatch, larger variants, missed fusion, register pressure
or cloning can make a program slower or larger. Report regressions and fallback
coverage alongside wins; do not increase existing promotion budgets to hide them.

## Pipeline, resources and WCET integration

- **P1:** callable target/ownership summaries are cooperating analyses with
  provenance, dependency hashes and explicit invalidation; use the shared-summary
  direction, not a separate editor-only estimator.
- **P2/P3:** operate before erasure, carry typed code identities, and route family
  storage through shared layout and ownership planning. Typed/erased agreement
  checks alone do not validate a transformation that changes allocation and code.
- **P4/P5/P6:** retain collection specialization/fusion; optimize known dispatches;
  include generated dispatch/helper paths in fuel, safepoint and stack placement.
  A source lambda eliminated by rewriting must not lose a scheduling obligation.
- **Resource contracts/editor:** public source promises remain distinct from
  optimized representation receipts. Existing native-source hover equations do
  not automatically describe defunctionalized code. Report the model/mode and
  invalidate dependent evidence; never relabel source work as target cycles.
- **WCET/admission:** finite target sets allow bounded dispatch composition
  (dispatch cost plus the maximum applicable callee bound). Account for capture
  construction, storage, runtime calls and scheduling separately. Unknown callee
  bounds remain unknown; finite targets do not prove termination. The simple-risc
  timing model and QOS admission qualification are still separate gates.

Related records: [pipeline roadmap](2026-11-07-PIPELINE-REFACTORING-ROADMAP.md),
[resource/WCET roadmap](2026-11-07-RESOURCE-CONTRACTS-WCET-AND-QOS-ROADMAP.md),
[resource/editor implementation](2026-11-09-RESOURCE-EDITOR-IMPLEMENTATION.md),
and [typed closure captures](2026-11-09-P2-TYPED-CLOSURE-CAPTURES.md).
