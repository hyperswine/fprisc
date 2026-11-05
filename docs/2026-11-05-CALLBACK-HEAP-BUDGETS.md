# Allocating callback heap budgets

Codegen 180 adds `--heap-budget=BYTES` for builtin RV64 ARC libraries with
explicit C exports. The compiler proves cumulative allocation requests and
requested bytes from the final verified IR, includes the checked C adapter's
conversions, and compares a physical C-heap capacity bound with the supplied
limit before publishing root assembly.

```
fpr compile --profile=bare-metal-builtin --arc --lib \
  --export=identity,wide,choose --heap-budget=2640 callbacks.fpr callbacks.s
```

This is admission for **one invocation on a fresh, 16-byte-aligned builtin
RV64 C heap**, using the allocator contract in `machine/builtin/heap.c`.
The caller must provide and initialize that arena, use a runtime configuration
whose maximum accepts it, and exclude concurrent/unaccounted heap users.
Inputs, caller stacks, argument cells and static data are separate obligations.
The option neither resets a live heap nor changes callback instructions to
fit the budget. It does not certify the separate FP-RISC implementation of
the allocator (`HEAP=fpr`). Link identity and whole-image storage composition
remain required before broader deployment admission.

## Proof authority and refusals

`Codegen.Heap` consumes the simplified, verified typed IR of functions that
actually pass native selection. Its policy is restricted to builtin RV64 ARC
with fixed stack and no scheduler fuel. Source `size`, `alloc` or termination
annotations cannot replace these facts. Static literals/nullaries cost no heap;
constructor requests use their emitted `8 + 8 * fields` layout. Each supported
uniform scalar box requests 24 bytes. Audited retain/release, layout and
unboxing operations allocate none in this C runtime. Generic aggregate
conversions, arbitrary runtime/foreign calls, reallocations and region paths
remain unproved.

Codegen 182 also shares [checked scalar selections](2026-11-05-SCALAR-ARENA-ADMISSION.md)
with RV64 emission. Exact inline Word, comparison and address operations now
contribute zero demand without pretending they are C runtime calls. Guarded
operations and their possible failure paths still need separate contracts.

Sequential calls add demand; alternative control-flow successors take an
upper bound in each of request count and requested bytes. Missing callees,
duplicate symbols, weak/interposable entries and unknown operations refuse.
Strongly connected components are admitted only when their entire reachable
allocation demand is zero. Allocating recursion/loops remain unproved; the
analysis does not invent iteration counts. This also conservatively refuses
some loops with an allocation only after their final exit.

The public entry's checked adapter contributes its input boxes, even when the
implementation later frees them. Unboxing the returned scalar allocates none.
Unused allocating constructors elsewhere in the unit do not disqualify a
closed callback that cannot reach them. Imported/kernel calls need matching
facts; absent facts never become zero defaults.

## Physical capacity

For `N` allocation requests totaling at most `R` requested bytes, the current
bound reserves `align16(R + 176 * N)` block bytes. The per-request allowance
contains the 80-byte RV64 block prefix, up to 16 bytes of rounding/minimum
payload and up to 80 bytes of unsplittable tail. The aligned live-start bitmap
is then included by solving for the supplied span. All arithmetic uses
unbounded compiler integers and refuses a capacity outside RV64's address
range. Zero requests need no heap arena.

This is deliberately a **cumulative** upper bound, not an optimized peak-live
bound. Starting with one fresh contiguous free block, allocating from that
remaining block reduces it by no more than the charged physical bytes;
allocating from a recycled block cannot reduce it. Frees can only preserve or
enlarge that remaining space. Charging all requests therefore leaves room for
each subsequent request, despite recycling/fragmentation. Reallocation is
excluded because retained capacity and in-place growth need different facts.
Region operations are excluded because their implicit requests are not yet
covered. The allocator's [geometry queries](2026-11-05-BUILTIN-HEAP-GEOMETRY.md)
provide an independent runtime check of the assumed prefix/minimum/bitmap
contract in the execution harness.

This leaves substantial room for tighter liveness proofs. For example, the
12-argument callback reserves 2,640 bytes but reaches 1,344 live block bytes.
The difference is explicit accounting conservatism, not a claim of eliminated
memory overhead.

## Execution and validation

The [callback record](../bench/2026-11-05-heap-budget.json) contains the compiler
identity, admission/refusal results and exact plain/measured image identities.

| Callback | Proved requests | Proved requested bytes | Admitted arena | Observed peak block bytes |
| --- | ---: | ---: | ---: | ---: |
| Word identity | 2 | 48 | 416 | 112 |
| Twelve Word arguments, returning the last | 13 | 312 | 2,640 | 1,344 |
| Bool selecting between two Words | 3 | 72 | 624 | 224 |

Both plain and measured RV64 QEMU images execute 256 calls, covering full-width
Word values, both conditional branches, C stack arguments and native hart
argument cells. The measured requests/bytes exactly match the proof; every
call leaves zero live allocations and intact arena guards. Both images pass
the independent schema-2 target-image gate. These are emulator checks, not
physical-board or remote CI evidence.

Exact limits pass; one-byte-short limits refuse before new root assembly is
written. A cached invocation with a tighter limit preserves the previous
successful output. Invalid limits, duplicate/missing export sets, RV32, unknown
printing and possible overflow calls refuse. A raw allocation-free callback
is admitted with zero heap demand. The emitted instructions/data are identical
with and without the heap budget; only the admission note is added.

The Haskell suite independently expands 1,728 acyclic sum/branch graphs and
checks cycle/unknown/duplicate/negative cases, typed constructor sizes, runtime
contracts and physical capacity boundaries. The source execution check is
registered in Base and requires execution in the RISC-V CI configuration.

All 41 Haskell suites, the existing native/callback stack execution checks,
materializing-pipeline regressions and eight check-registry tests pass with the
same final compiler. The unchanged compiler-cost gate passes at
1.59/32.68/68.98 GB allocated for hello/std-live/pos1. The C2 gate retains exact
code-size/function-count parity through 256 helpers, with compiler allocation
about 1.001 times the explicit monomorphic twins. See the
[validation manifest](../bench/2026-11-05-heap-budget-validation.json).

An initial implementation exceeded std-live's peak-memory gate. Ordinary
compilation now avoids computing unused stack reports: request them explicitly
with `--stack-report`; C exports and stack-budget admission still enable them
automatically. Std-live now peaks at 428 MB, within the unchanged limit. A
cached imported-unit check confirms that requesting the report refreshes its
comments while preserving unit identities and instructions. The stack-bound
solver itself is unchanged from codegen 179. Heap analysis is also opt-in.
Cost checks overlapped with other validation, so their wall times are not
isolated throughput measurements.

## Remaining roadmap work

The later [controlled activation builder](2026-11-05-STATIC-ACTIVATION-ARENAS.md)
binds this conditional heap proof to the audited C runtime and actual reserved
regions for one fresh scalar callback, including its startup/caller stack.
General program, loop, conversion and concurrency composition remains open.

The later [linked-stack gate](2026-11-05-LINKED-STACK-ADMISSION.md) accounts for
the actual native/C stack graph of the allocating callbacks and binds it to
the linked image. The controlled builder composes that proof with startup,
caller storage, fixed arenas and exact runtime identity for its restricted
single-activation subset.

This does not finish the static-arena roadmap. Useful bounded allocating loops,
tighter peak-live and ownership composition, complete conversion graphs,
general startup, interrupt nesting and concurrent entry dispatch remain open.
A heap bound proves neither termination nor scheduling latency/WCET. Broader
Base boundaries and physical reference-target qualification remain unfinished.
