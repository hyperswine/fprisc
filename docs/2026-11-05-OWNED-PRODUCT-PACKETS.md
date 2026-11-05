# Owned fields in builtin product packets

Codegen 181 / ARC revision 21 extends the checked private product ABI to owned
fields. Complete single-constructor products of two through eight words can
carry Strings, lists and other boxed values directly alongside scalar fields.
The wrapper disappears; its owned payloads retain their normal representation.
Unknown layouts, multi-constructor values and unsupported widths keep their
existing boundary behavior. Nested products are not recursively flattened.
Existing target capacity and return conventions still apply; the execution
qualification in this report is RV64 QEMU.

The later [codegen-184 nested-product follow-up](2026-11-05-NESTED-PRODUCT-PACKETS.md)
adds eligible acyclic flattening and nested lexical borrowing. The measurements
and original scope below describe codegen 181.

This is abstraction removal in the builtin/ARC profile. It does not enable
owned products in raw units or interrupt handlers, change the public tagged
ABI, or establish broader Base support or whole-image arena admission.

## Ownership and scoped borrowing

Checked layouts provide a separate ownership bit for every physical field.
Copying a packet retains its owned fields; destroying it releases those fields.
Unpacking a real box retains its payloads before releasing the box, while
materialization transfers field references into the original nominal box.
Aliased fields each carry their own reference. Branch joins and private calls
transfer references under the same convention as ordinary ARC arguments/results.

Lexical aliases of a local packet and its one-word fields can borrow from the
enclosing packet's owners. Each consuming use still retains its value before
those owners are released. Returning a field therefore creates an independently
owned result. This also removes redundant references introduced by pattern-match
aliases. Borrowing does not cross a function boundary or apply to temporaries;
projecting a nested packet still unpacks and owns its component references.

Public, generic and heap boundaries still materialize real tagged objects.
Argument expansion beyond the existing 64-word limit retains the boxed entry.
Raw/interrupt validation rejects owned packets before ownership-free lowering.
No pointer tagging, runtime heap format or allocator implementation changes.

## Allocation and work evidence

The [ownership regression record](../bench/2026-11-05-owned-products.json)
compares identical payload construction and checks complete reclamation:

| 1,000-step workload | Boxed rollback | Product packets | Explicit loop |
| --- | ---: | ---: | ---: |
| String/Word wrapper constructors | 1,001 | 0 | 0 |
| List payload plus wrapper constructors | 1,005 | 4 | 4 |

These are constructor-allocation counts, not all String/runtime allocation
requests. The String itself still exists. The four list allocations include
the existing payload construction/conversion work shared by both spellings.

The [paired work record](../bench/2026-11-05-owned-products-work.json) uses the
saved codegen-180 compiler, the final compiler and its boxed rollback with the
same source, runtime, ISA flags and explicit-loop control. ARC checking and
allocation counters are disabled for this measurement. Three repeated samples
follow warmup, alternating the two source forms; all repeated counts agree.

| Steps | Previous aggregate | Current aggregate | Explicit loop |
| --- | ---: | ---: | ---: |
| 100 | 194,381 | 22,361 | 37,108 |
| 1,000 | 1,917,014 | 213,194 | 359,341 |
| 10,000 | 19,143,047 | 2,121,227 | 3,581,374 |

At 10,000 steps this is 9.02x fewer executed guest instructions than the previous
aggregate implementation and 40.8% fewer than this explicit-loop spelling.
The rollback exactly reproduces the previous aggregate counts; the explicit
control is unchanged. These are deterministic QEMU `icount` instruction counts,
**not hardware cycles, host throughput, physical Pi timing or a WCET bound**.
They establish this fixture's allocation/work improvement, not universal
performance parity for owned aggregates. Inlining is disabled to isolate the
private representation and ownership convention.

## Validation

The [final validation manifest](../bench/2026-11-05-owned-products-validation.json)
binds the compiler, sources and evidence. All **41 Haskell suites** pass. The
new ownership oracle passes twelve configurations: C/FPR heaps, soft/hard
float ABIs and default/no-type-specialization/boxed modes. It exercises shared
dynamic Strings, two owned aliases in a packet, copies, joins, discarded
arguments, tag checks, nested and heap escapes, retained public handles,
returned String lifetimes, exact full-width Word payloads and wide-argument
fallbacks. All paths check reclamation under `ARC_CHECK=1`.

Six effect/trap cases agree exactly across all three optimization modes:
observable argument order, division by zero, an unused trapping field, an
unselected branch and both integer endpoints. Existing builtin/raw products,
uniform aggregate conversion, hidden-field boundaries, scalar wrappers,
heap-budget admission and registry regressions also pass. Raw/interrupt
ownership refusals are covered by the representation unit tests.

Unchanged compiler budgets pass at **1.59 / 32.68 / 68.97 GB** allocated for
hello/std-live/pos1; std-live peak residency is **428 MB**. The
[C2 cost gate](../bench/2026-11-05-owned-products-cost.json) keeps identical
assembled code sizes and function counts through 256 helpers, at
1.000–1.001x the compiler allocation of explicit monomorphic twins. Neither
absolute nor relative cost limits were increased. This is local host and
emulator evidence; no new remote CI or physical-board result is claimed.

## Remaining scope

Broader Base ownership/module/cache contracts, open rows, recursive flattening
and general variant storage remain separate gates. Scheduling time bounds and
whole-image heap/stack/arena composition still need their own evidence. The
[active roadmap](2026-11-04-ZERO-OVERHEAD-COMPLETION.md) remains unfinished.
