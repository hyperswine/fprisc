# Owned wrapper payloads

Codegen 186 / ARC revision 24 extends checked builtin product lowering to
single-field owned wrappers. A wrapper around a String, list or tagged generic
payload can carry that payload directly through private arguments, results,
joins and recursive calls. Eligible nesting follows the existing complete
checked layout graph and target capacity.

## Representation contract

A one-leaf packet uses the ordinary one-word private return convention. Its
private entry has a distinct payload name; no one-word multi-register marker
or backend result convention is introduced. Wider expansions continue to use
the existing product convention. Zero-capacity rollback and nullary values
retain their previous behavior.

The checked shape still records the source constructor, original field
boundaries and ownership of each leaf. Copying a payload retains its owned
reference; consuming projection transfers it, and discarding the wrapper
releases it. Nested field aliases borrow from the enclosing live owners.
Tail calls keep these transfers in the original evaluation order.

Public, generic and heap boundaries reconstruct the nominal wrapper tree and
its immediate-field metadata. A one-word private result is therefore not a
public promise that a String pointer represents the source wrapper. Unknown
layouts retain explicit fallback/refusal behavior, recursive edges remain
boxed, and over-wide nesting retains boxed children. Raw and interrupt paths
continue to refuse owned-reference products, including one-field wrappers.

## Allocation evidence

The [saved-compiler measurement](../bench/2026-11-05-owned-wrappers-before.json)
and [current ownership matrix](../bench/2026-11-05-owned-wrappers.json) use the
same 1,000-step source forms:

| Source form | Codegen 185 | Codegen 186 | Explicit payload loop |
| --- | ---: | ---: | ---: |
| String wrapper | 1,001 | 0 | 0 |
| Two nested String wrappers | 2,002 | 0 | 0 |
| List wrapper, including list payload cells | 1,005 | 4 | 4 |

These count constructor allocation requests. The String itself still exists,
and escaping wrappers remain real heap values. Disabling product lowering
restores the wrapper allocations. The allocation oracle also retains the
existing flat and nested multi-field product gates.

The twelve configurations cover C/FPR allocators, soft/hard float ABIs, and
default/no-type-specialization/boxed modes. Tests inspect public one-level and
two-level tagged trees, retain original handles across calls, share payloads
through joins and lists, and require complete reclamation. Seventeen semantic
cases compare printed prefixes, selected branches, unused-payload failures,
division and both integer-overflow endpoints across all three modes.

Hidden payloads retain their own tagged representation. The private Word
factory now requires one payload box; the public factory additionally crosses
its scalar bridge and materializes the nominal Hidden wrapper. Its public
allocation count remains three, as in the saved compiler. The
[public before/after comparison](../bench/2026-11-05-owned-wrappers-public.json)
executes 128 inputs and inspects the same boxed ABI under both compilers. The boundary test
checks these private and public contracts separately, including exact Word
bits, malformed payloads and shared managed graphs.

## Executed work

The [isolated representation benchmark](../bench/2026-11-05-owned-wrappers-work.json)
and [ordinary-inlining benchmark](../bench/2026-11-05-owned-wrappers-work-normal.json)
use uninstrumented allocation paths, an untimed warmup, alternating source
order and three repeated samples per size. Results and return status are
checked on every invocation. The reported measure is QEMU `icount` guest
instructions, not physical cycles or host wall time.

Both inlining configurations give identical counts for this fixture:

| Steps | Previous wrapper | Current wrapper | Current explicit loop |
| --- | ---: | ---: | ---: |
| 100 | 270,835 | 38,272 | 38,217 |
| 1,000 | 2,682,868 | 372,205 | 370,350 |
| 10,000 | 26,802,901 | 3,711,238 | 3,691,383 |

All repeated samples agree. At 10,000 steps this removes about **86.2%** of
the previous executed work. The wrapper spelling remains about **0.54%** above
the explicit loop; removing its constructor allocations does not establish
exact instruction parity. Product rollback restores the previous wrapper
counts. The explicit loop changes by only two instructions between compiler
versions at each size. These measurements establish work reduction for this
source/target pair, not a hardware throughput or scheduling-latency bound.

## Final qualification

All **41 Haskell suites** and **18 qualification groups** pass. The
[validation manifest](../bench/2026-11-05-owned-wrappers-validation.json) binds
the compiler, final sources, test logs and measurement artifacts. Unit checks
cover one-word entry identity, absence of invented `pack1` markers, exact leaf
ownership, nesting, target capacity and raw refusal. Runtime checks cover
generic/hidden/open-row boundaries, existing scalar and multi-field products,
raw/interrupt execution and refusal paths, and sanitizer coverage of conversion
helpers.

A separate [normal-inlining ownership probe](../bench/2026-11-05-owned-wrappers-normal.json)
passes the complete allocation/lifetime oracle on the C allocator and soft
float ABI. It is registered as a distinct CI configuration, without replacing
the broader inlining-disabled matrix. These are local results; no new remote
CI execution is claimed.

The [existing arena recipes](../bench/2026-11-05-owned-wrappers-arenas.json)
retain exact-budget execution, reclamation, guard and failed-publication
checks. Owned payload unwrapping does not add an arena admission contract for
String/list operations. The unchanged compiler-allocation gate passes at
**1.60 / 32.64 / 67.14 GB** for hello/std-live/pos1, with a **420 MB** std-live
peak. The [C2 scaling gate](../bench/2026-11-05-owned-wrappers-cost.json) retains
exact code-size/function-count parity through 256 helpers and
**1.000–1.001x** compiler allocation versus explicit monomorphic twins.
No budget or baseline was relaxed.

Broader Base canonical layouts, general variants, scheduling time bounds and
general-application arena admission remain unfinished. Recursive and escaping
data continue to retain the heap structure required by their contracts.
