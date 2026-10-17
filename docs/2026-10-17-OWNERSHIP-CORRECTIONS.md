# Ownership corrections: inference, records and control flow

This is the first implementation batch following the
[ownership audit](2026-10-17-LINEAR-OWNERSHIP-GAPS.md). It corrects Sol inference
parity and preserves known ownership through record operations, case-result
joins, and pattern guards. General polymorphic and higher-order ownership is
still open.

## Implemented behavior

- Sol retains inferred ownership signatures and merges declared, inferred, and
  primitive signatures in the same priority order as the native frontend.
  Unannotated owner-producing/consuming functions now participate in checking.
- `LShape` preserves record fields and whether a row has an unknown tail. Both
  declared and inferred record types provide that structure.
- Constructing, aliasing, updating, or returning a known-owned record preserves
  ownership. Updating unrestricted metadata moves the old record into its
  successor; the old binding cannot be reused. Replacing an owned field is
  refused because the old owner would be discarded.
- Projecting a field moves the record. It is accepted when every other known
  field is unrestricted; otherwise the checker requires complete owned-field
  destructuring. Reading only metadata from a known-owned record is refused
  because it would discard the owner. Nested projection/update paths follow
  these rules at each level.
- Record patterns bind the actual known field shapes and refuse omitted owned
  fields. Duplicate literal fields involving an owner are refused because
  selecting a name would discard or alias one of its values.
  Moving/destructuring a known-owned open record is conservatively
  refused because its residual ownership is unknown. Returning or forwarding
  the whole record remains possible.
- Case-result ownership joins every live arm. A linear closure in a later arm
  cannot become reusable because an earlier arm returns an unrestricted closure.
- Pattern guards preserve the RHS shape and check newly bound owners for exact
  use. Owner-producing guards must bind irrefutably and cannot precede a guard
  that may fail. Guard bindings cannot hide an existing known owner by shadowing
  its name. Until guard failure cleanup is modeled, explicit cases provide the
  way to handle refutable ownership transitions.

The Sol Prolog example also needs ordinary machine-state threading under the
stronger inference checks: inspecting its heap/trail tuple transfers ownership
into the destructured fields, so continuing with the old tuple is invalid.
The example now reconstructs/thread successors and returns the machine alongside
backtracking marks. No ownership escape is added to accommodate the example.

## Validation

All validation is local; no M1 host, printer, or production service is contacted.

- `tests/check_structural_ownership.py`: 29 cases in both native and Sol, with
  refusal checks and executed legal single-use moves. Includes nested paths,
  residual-owner loss, stale records, replacement, inferred record returns,
  open rows, case closures, and guard fallthrough.
- `tools/sol-linearity-check.py`: eight ownership regressions, including
  legal composition, top-level evaluation, and a discarded Prolog machine
  successor. Both suites are registered in
  `tests/check_base.py`.
- The existing printer ownership/resource suite passes on one and four local
  harts, with 12 refusal cases, native buffer accounting/quotas, stale/wrong owner
  checks, actor-death cleanup, eight proven scalar bounds and 303 arithmetic
  reference cases. Typed-vector checks also pass.
- Sol output compatibility passes 26 checks, hosted libraries pass 117 checks,
  and Sol examples pass 21 checks, including Prolog backtracking and direct
  heap/trail mark/undo state preservation. The seven native application
  entrypoints (inventory, logbook, POS, printers, printer host, report, and ideal
  report) pass check-only compilation.
- The complete `tests/check_base.py` run passes, including POS live reload,
  inventory's 2,286 pagination references, native/Sol specialization and effect
  ordering, actor lifetime/cleanup, and local runtime checks. Platform-specific
  checks retain their reported skips; the POSIX RV64 artifact check lacks a
  suitable compiler backend on this host. Cross-target emission checks are not
  physical-target execution evidence.

The general-purpose Sol script suite also passes, including native system-report
and archive execution. Native system-report and the Base suite's loopback server
fixtures require execution outside the restricted sandbox; all fixtures remain
local and disposable.

The original diagnostic now records
[11 remaining accepted invalid cases](evidence/2026-10-17-linear-ownership-after-structural.json),
down from 19 in the initial snapshot. All eight corrected probes are refused
for linearity by both frontends. The diagnostic intentionally exits 1 while
remaining gaps exist; the passing regression suites assert the corrected cases
and valid examples instead.

## Next compiler work

1. Preserve symbolic ownership parameters and their use constraints through
   generic schemes and instantiation. Identity must preserve an owner's shape;
   duplication/discarding requires an unrestricted argument. Ordinary Int/String
   duplication must remain legal.
2. Substitute actual payload ownership into generic constructors and patterns,
   including `Box`, `Result`, and `List`, rather than collapsing a container to a
   single linear/unrestricted flag.
3. Track callable capture/result ownership and call multiplicity through returns,
   aliases, dynamic partial applications, and higher-order parameters.
4. Extend those constraints to row polymorphism. A helper typed only with
   `{tag : Int | r}` can still hide owners in `r`; the current conservative rule
   applies when ownership is already known, not to every possible instantiation.

The new constraints must survive checked module interfaces, closure lifting,
specialization, and both frontends. An imported or specialized generic helper
must enforce the same ownership requirements as a local call.

These changes are not a whole-language ownership soundness proof. The generic
buffer duplication example from the audit still compiles, with native checks
remaining the runtime backstop. Deliberate `keep`/`drop` and raw owner-constructor
escape rules are separate follow-up work.
