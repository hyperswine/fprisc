# Contracts in application code

Date: 2026-10-17. Kind: implementation plan and acceptance record.

The POS, inventory and printer applications have useful invariants, but most
are expressed only as ordinary branches over `Int` and shared records. The
goal is to make their internal APIs carry meaningful contracts, ownership and
resource declarations, starting with sound enforcement through composition.

This follows the [refinement direction](2026-10-12-MEMORY-I32-REFINEMENTS.md#3-refinements-in-the-type-with-propagation)
and the [example-style plan](2026-10-03-STYLE-DIRECTION.md). The existing
`examples/ideal/transitions.fpr` and `buffer.fpr` remain the small teaching
examples. The new cores should be used by the actual applications.

## Delivery order

1. **Higher-order contract enforcement.** A contracted function passed to
   `map`/`fold`, stored in a record or local alias, returned from a function,
   or partially applied must retain its checks. Ordinary saturated named calls
   should retain static discharge and their existing resource equations.
2. **POS core.** Extract quantity normalization, cash/change and stock-admission
   arithmetic. External requests remain fallible; validated scalar operations
   carry preconditions and checked work/allocation declarations. Keep the shared
   native/browser tax calculation and user-facing workflow.
3. **Inventory pagination core.** Extract positive-page-size, nonnegative-count
   arithmetic, page clamping and offsets. Avoid overflow in ceiling division and
   offset calculations. Keep current configuration normalization and normal
   rendered pages; explicitly clamp malformed negative page requests.

## Compiler contract

The existing precondition pass inserts checks at syntactically named call sites.
As of the initial audit, `needsPositive 0` traps while
`List.map needsPositive [0]` returns `[0]` for the same `x > 0` signature.
This bypass must be closed before promoting contracted callback pipelines.

The first implementation uses checked function entries for escaped values,
with full signatures so linear arguments and ownership remain visible to the
existing checker. The checked path must preserve evaluation order, evaluate
arguments once, respect lexical shadowing, and work across native module
boundaries and the Sol frontend. Direct named partial applications check the
supplied constrained arguments immediately. Escaped function values check on
saturation, before entering the contracted body; constructing an unused invalid
partial application through an alias does not itself fail.
Checks must not be hidden by an `unsafe` escape or an unjustified cost summary.
The native unit-cache revision must distinguish the new lowering.

This step does not add a general refinement type system. Result refinements,
inferred caller obligations, general relational arithmetic proofs and checked
container-length refinements remain separate work. Contract failures remain
programming errors with named blame; malformed network/forms/configuration
inputs should still be handled as ordinary errors before entering a contracted
internal API.

## Acceptance

- Valid direct, aliased, higher-order, record-stored, returned and partially
  applied calls agree. Invalid calls retain named contract failures.
- Guards still discharge direct obligations; existing ideal-example and cost
  declarations still prove. Contracted foreign functions retain checks.
- Callbacks with effects preserve argument/check timing and execute once.
- Typed checked entries retain the existing linear parameter/result signatures;
  a direct partial application owning a vector remains single-use. Native
  one/four-hart and Sol execution exercise the shared frontend. General linear
  closure capture through aliases is not certified by this change.
- POS arithmetic agrees with independent references, including zero/boundary
  quantities, insufficient cash, out-of-range inputs and overflow boundaries.
- Pagination agrees with independent reference calculations for empty results,
  exact/partial pages, negative/oversized requests and large integer counts.
- Deliberately broken preconditions and insufficient resource budgets fail.
- The real POS/inventory sources compile with the extracted cores; existing
  behavior/browser checks provide regression coverage where affected.

The focused suites join `tests/check_base.py`; pagination also receives a
standard-library golden test. Source modifications unrelated to this task are
preserved, and no deployment or publication is part of this request.

## Follow-up applications

2026-10-17 implementation: [linear printer connection and frame ownership](2026-10-17-PRINTER-OWNERSHIP.md), with local-only acceptance and explicit native/scalar resource boundaries.

After these cores, introduce a genuinely linear owner for printer connections
and frame buffers; current `std/transport` explicitly documents state threading
without static alias checking. For a combined numerical/ownership/resource
example, strengthen Swarm's per-mote update and then its per-tick budget, or add
a simulated bounded sensor-processing controller.

Resource declarations concern abstract work and the compiler allocation model.
They are not an end-to-end networking deadline or measured hardware WCET. Sol
currently shares precondition/linearity enforcement but does not enforce native
resource declarations. Input/output size assumptions and opaque library costs
must stay visible until the relevant analyses are implemented.

## Implementation

`compiler/Precond.hs` gives escaping contracted functions typed checked entries.
Local aliases, records, returned functions and callbacks point to these entries;
statically discharged direct calls keep their original targets. Partial direct
calls retain an entry for the remaining checks. Guards are checked before their
facts become available, and generated locals cannot collide with source names.
Argument effects occur once, in order, and a failing check precedes the original
body. Checks retain their actual cost instead of inheriting the body's resource
declarations.

Calls that supply arguments to a returned function preserve the original direct
call boundary. For unknown/aliased calls, this preserves each backend's existing
behavior: native may evaluate the whole argument spine before entering the first
function, while Sol applies it in stages. Differential tests compare contracted
and uncontracted calls on each backend; this work does not standardize that
older evaluation difference.

Inference and Sig/Struct specialization also select checked entries for globals
they synthesize after the precondition pass. Native dynamic lookup and C export
trampolines use checked pointers while retaining the source module identity.
Shared foreign declarations emit one checked implementation, and the native
cache key includes the merged contract context. Interface stamps distinguish the
new callable contract from older raw-entry artifacts.

Only a predicate's own scalar binder is currently in scope. Free global and
other-parameter references are rejected instead of being captured from the
caller's locals; termination `measure` expressions keep their existing scope.
An escaping contracted definition must accept all its declared parameters in
its source definition. A body that returns the remaining function is refused at
that boundary until staged checked entries can preserve its effect timing.
Hidden vector layout arguments do not count as source parameters.

`examples/pos1_core.fpr` supplies the actual register's quantity normalization,
cash/change calculation and restock admission. Fallible boundary helpers accept
ordinary `Int` inputs. The validated scalar APIs declare:

| Operation | Parameter contracts | Work bound | Allocation bound |
| --- | --- | ---: | ---: |
| `boundedQuantity` | Both inputs in 0..999 | 3 | 0 |
| `difference` | Both inputs nonnegative | 1 | 0 |
| `addStock` | Stock in 0..9999; delta in 1..999 | 7 | 16 |

Restock tests capacity before adding, and cash checks ordering before using the
difference as change/shortfall. These declarations cover the scalar operations,
not cart totals, currency parsing, journal replay or the complete checkout.
The existing shared native/browser tax formula remains in `pos1_pricing.fpr`.

`std/pagination.fpr` supplies `validSize`, `pages` and `plan`; inventory calls
`plan` in its real projection. `pages` requires a positive size and nonnegative
count, with work <= 8 and allocation <= 0. `plan` has the same preconditions and
an unrestricted requested index, with work <= 25 and allocation <= 32. It clamps
negative requests to zero, late requests to the last page and empty results to
one empty page. Ceiling division subtracts before dividing. The clamped offset
cannot exceed `count - 1` for a nonempty result, so multiplication fits when the
inputs fit. Those postconditions are documented and boundary-tested rather
than inferred result refinements.

## Validation record

The focused suites are `check_higher_order_contracts.py`,
`check_contract_rewrites.py`, `check_pos_core.py` and `check_pagination.py`; all
are registered in `tests/check_base.py`. Pagination also joins
`tests/check_std.py`.

Verified on the macOS AArch64 host:

- The full higher-order suite passes on native/Sol: aliases, callbacks, records,
  returned functions, direct/escaped partials, guard checks and shadowing,
  predicate helper hygiene, imports, argument/check timing and Sol file rollback.
  Additional native cases cover vector mapping/layout evidence, repeated foreign
  declarations, direct linear-PAP single-use/refusal, static/dynamic module lookup
  and actual contract-only plugin attachment. C-export/foreign entry emission,
  unsupported shape/free-name refusal and visible checked-path costs also pass.
- POS: 646 independently calculated quantity/cash/restock cases on one/four
  harts, invalid direct/aliased/higher-order calls, and actual register snapshots.
  All six scalar work/allocation declarations are proven at their exact bounds.
- Pagination: 2,286 independent reference cases on one/four harts, tagged-Int
  extrema, five invalid-contract refusals and deliberately insufficient budgets.
  The golden test and actual inventory projection agree, including empty/shrunk
  results, negative/late requests and historical configuration normalization.
  Derived work is 6 for `pages` and 18 for `plan`; allocation is 0 and 32.
- Contract rewrite regressions pass on native/Sol, including selected operators,
  guards, imports and a shared native cache reused with a stronger contract.
  Existing direct work/allocation proofs still report `PROVEN`.
- `check_cost.py`, `check_cases.py` and `check_specialization.py` pass, including
  measured recursion, manifests, signature/coverage refusals, native/Sol effects
  and panic timing, warm mode caches and RV64/RV32/A64/x64 emission. Two stale
  Todo cost assertions were refreshed to its existing `updateWith` API and
  measured `dropGo` recurrence.
- All eight ideal examples build with their resource declarations proven. The
  full ideal acceptance run passes: original/ideal file/report/Todo/service
  behavior, independent buffer/transition results, and invalid precondition,
  linear reuse, nondecreasing measure and insufficient-bound refusals.
- Checked interface publication and real native-module load/reload/refusal tests
  pass. Contract-only modules preserve their nonempty source identity.
- The actual POS reload test passes on one/four harts: independent carts and
  cashiers, changed checkout policy, receipt history, incompatible/invalid update
  refusal, recovery, reload notice and journal rebuild. Ordinary static pricing
  still works without a publication journal.
- Browser regressions pass: 1,031 native/generated calculation vectors, 50
  console-history vectors, real POS carts/receipts/checkout and real inventory
  history/draft/focus/scrolling on one/four harts.
- The pure-application source boundary audit passes across 97 native modules,
  Sol web and automation. No application-authored JS/CSS or external runtime
  integration was introduced by these cores.

All checks above completed successfully. No physical device, network deadline
or hardware WCET claim is made by these host checks. The full Base/std aggregate
suites were not run; the affected suites and pagination golden test were run
directly. Unrelated checkout changes were preserved. Changes are not committed,
pushed or deployed by this request.
