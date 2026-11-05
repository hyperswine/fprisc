# Nested builtin product packets

Codegen 184 / ARC revision 22 extends private builtin product values across
nested checked products. Eligible acyclic children contribute their leaf words
directly to their parent's packet, up to the target's existing eight-word
capacity. This removes inner constructor allocations as well as the outer
wrapper. Owned String/list/reference leaves keep their ordinary representations
and individual reference counts.

This change is specific to builtin/ARC representation lowering. Hosted Base
storage, public tagged layouts, foreign signatures and the runtime heap format
are unchanged. The execution evidence below is RV64 QEMU, not physical-board
timing or a WCET claim.

## Representation and ownership contract

The complete checked type graph determines one product shape per type instance
and target capacity. Strongly connected components identify recursive types;
references to those types remain boxed. An acyclic expansion that exceeds the
capacity retains the original immediate-field packet and its boxed children.
Ancestors may still flatten that bounded packet, preserving the remaining
child box. No caller order, traversal depth or specialization clone counter
chooses the representation.

Each shape records both its original source-field boundaries and its flattened
leaf kinds/ownership. Constructor arguments and source projections follow the
former; private arguments/results follow the latter. The checked layout map is
computed once for each evidence/exposure operation rather than once per caller.
The existing 64-word private argument limit and eight-word result limit remain.

Lexical aliases of nested fields borrow their exact leaf slices from the
parent's live owners. A consuming copy retains the owned leaves. Projecting a
temporary transfers the selected slice and releases the other owners.
Unpacking a nominal tree retains a child before unpacking it and releasing its
temporary container owner. Materialization rebuilds the original nominal tree,
transferring leaf ownership into the appropriate inner and outer boxes. Layout
metadata describes each box's immediate fields, including boxed children.

Public/generic/heap boundaries therefore retain the original representation,
including tagged full-width Word payloads. Unknown layouts, recursive edges
and over-wide expansions do not acquire an unchecked default. Raw libraries
and interrupt handlers admit nested scalar packets only; owned leaves and
boxed fallbacks still refuse before emission. Post-lowering allocation and
register-arity checks remain mandatory. `FPR_NO_PAIR_RETURNS=1` retains the
existing boxed rollback.

## Allocation and executed-work measurements

The [saved-compiler allocation record](../bench/2026-11-05-nested-products-before.json)
and [current ownership matrix](../bench/2026-11-05-nested-products-owned.json)
use the same nested String/Word-plus-String fixture:

| 1,000-step source form | Constructor allocations |
| --- | ---: |
| Previous compiler, outer packet with boxed inner product | 1,001 |
| Current nested packet | 0 |
| Explicit loop | 0 |
| Current compiler with product lowering disabled | 2,002 |

These count constructor requests, not every String/runtime allocation. Dynamic
Strings still exist. Existing flat String/Word and list-payload allocation
gates remain zero and four respectively, matching their explicit controls.
The saved compiler compiles the library under test; the runtime and empty
entry are compiled from the current checkout. Both compiler hashes are recorded.

The [work benchmark](../bench/2026-11-05-nested-products-work.json) separately
disables ARC checking and allocation counters, warms up each source form,
alternates order, and records three repeated QEMU `icount` samples per size:

| Steps | Previous nested product | Current nested product | Explicit loop, before and after |
| --- | ---: | ---: | ---: |
| 100 | 135,019 | 37,736 | 67,231 |
| 1,000 | 1,325,752 | 362,669 | 654,964 |
| 10,000 | 13,232,785 | 3,611,702 | 6,531,997 |

Every repeated count agrees. At 10,000 steps the nested program executes about
3.66 times fewer instructions than the previous compiler and 44.7% fewer than
this explicit-loop spelling. The fully boxed rollback executes 40,035,460
instructions; it also disables the already-existing outer packet optimization,
so it is not equivalent to the previous compiler. Inlining is disabled to
isolate private representation and ownership behavior. These results establish
allocation/work improvement for this fixture, not universal speedups, native
throughput or physical time bounds.

## Fixed-arena integration

The [arena record](../bench/2026-11-05-nested-products-arenas.json) extends the
controlled static-activation checks with a nested Word loop. The saved compiler
refuses this source's positive-allocation cycle. The new compiler proves zero
loop allocation; only three scalar boundary conversions remain.

Zero, 10,000 and 100,000 iterations all execute with **624 heap bytes and a
368-byte linked whole-activation stack bound**. Word wraparound and returned
bits are checked independently. Each case passes at the exact reserved bounds,
reclaims its complete heap and preserves the guard regions. Short heap/stack
budgets refuse without replacing an existing successful image or receipt.
An independent full-code trace for the zero-iteration case verifies startup
BSS stores, initial stack placement and executed-PC coverage; it observes
352 bytes of stack within the 368-byte proved bound. The longer runs use guard
and result checks, not instruction-by-instruction tracing.

The arena recipe remains a controlled single activation with ordinary
interrupts disabled and an audited C heap. This is integration with the
existing proof, not general admission of allocating loops, concurrent actors,
resumable interrupts or arbitrary application startup.

## Semantic and boundary qualification

The ownership oracle covers twelve configurations: C/FPR allocators, soft/hard
float ABIs and default/no-type-specialization/boxed modes. Nested aliases,
copies, joins, heap storage, retained public handles and distinct dynamic
String fields preserve their values and reclaim completely. Public inspection
checks the original two-level tagged layout and exact full-width Word bits.
Six new nested effect/trap cases agree exactly across all three modes, alongside
the existing six flat cases: argument order, division failure, a trapping
unused inner field, an unselected branch, and both Int-overflow endpoints.

The raw oracle executes a three-level, eight-leaf product without an allocator
or ARC implementation linked. It independently checks every field position
for 256 inputs in each of four ABI/type-specialization configurations: 8,192
field answers, plus aggregate checks. Nested F64/F32 values retain signed-zero
and NaN payload bits. Memory-effect traces and overflow/division/shift/alignment
failures pass for both flat and nested unused fields. The resumed-interrupt
matrix executes 1,001 handler invocations per configuration on both allocators
with type specialization enabled/disabled, verifying GPR/FPR/fcsr restoration
and zero handler constructor allocation.

Unit checks cover checked leaf ownership, capacity-dependent fallback,
mutually recursive boxed edges, stable child choices, exact eight/nine-leaf
admission and raw ownership refusals. The [validation manifest](../bench/2026-11-05-nested-products-validation.json)
binds final sources, compiler and regression evidence.

All **41 Haskell suites** pass, as do existing builtin products, uniform
aggregate conversion, hidden-field boundaries, scalar wrappers, heap budgets
and registry checks. The unchanged absolute compiler-cost gate passes at
**1.59 / 32.68 / 68.98 GB** allocated for hello/std-live/pos1, with std-live
peaking at **433 MB**. The [C2 cost gate](../bench/2026-11-05-nested-products-cost.json)
retains exact emitted code/function parity through 256 helpers and
1.000–1.001x compiler allocation versus explicit monomorphic twins. Neither
budgets nor baselines were relaxed. These are local checks; no new remote CI
result is claimed.

## Remaining scope

Recursive heap structures retain boxes; this change flattens eligible acyclic
product nesting. One-field owned wrappers, open rows, general variants and
broader Base ownership/module/cache storage contracts remain separate work.
Allocating-loop and peak-live resource proofs, general application arenas and
physical scheduling qualification also remain open. The
[active roadmap](2026-11-04-ZERO-OVERHEAD-COMPLETION.md) is unfinished.

The subsequent [codegen-185 boundary milestone](2026-11-05-OPEN-RECORD-BOUNDARIES.md)
adds tagged open-row fallbacks for compiled record shapes. It does not remove
open-row allocations or extend this packet ABI to arbitrary foreign schemas.
