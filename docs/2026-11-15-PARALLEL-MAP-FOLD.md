# Parallel map/fold and VList-backed linear lists

Date: 15 November 2026. Kind: design proposal and plan. It changes no
compiler, runtime or library behaviour. This is the direction proposed
on this date, not a specification and not an implementation record. It
applies to `origin/main` at `edfa57cd` (merge of PR #79). Thresholds,
chunk factors, cutoffs, first-block size and growth ratio named below
are to be measured; the only timing used here is the xpingpong point
recorded in the measurement plan. The proposal may be revised or
replaced if measurement or a later review changes the trade-off.

It follows from the current actor, hart and memory model, recorded in
the [scheduler model](2026-10-02-SCHED-MODEL.md), the
[memory reclamation intent](2026-11-11-MEMORY-RECLAMATION-INTENT.md)
and the [15 November review of parallelism](#current-state) below. The
VList-backed `List` direction realises the proof-gated form of flat
lists already named as unboxing B6
([unboxing proposal](2026-11-01-UNBOXING-ZERO-OVERHEAD-PROPOSAL.md:369-379);
[priorities](2026-11-09-PERFORMANCE-PRIORITIES.md:354-358)), without
reviving a global array-backed `List`.

## Goal

Two related intents, in one page because they compose:

- Explicit `parMap` / `parFold` that run independent element work
  across harts, with results identical to the sequential `map` /
  `fold`. Optionally, and only when a later gate and a runtime check
  both fire, let ordinary `std` `map` / `fold` use that path. There is
  no implicit data-parallelism today, and this page does not propose
  one that is on for every call.
- When the compiler can prove a `List` use is uniquely owned — the
  same uniqueness facts `Reuse.hs` already uses — represent that list
  as a Bagwell VList (a chain of doubling blocks) instead of cons
  cells. Shared or unproved uses stay ordinary cons-cell lists. This
  is a compiler-chosen representation of `List`, not a new surface
  type.

## Current state

Hosted Base is already concurrent, but only as actors on harts, not as
data-parallel loops. A posix process starts one pthread per live hart.
The compile-time cap is `fpr build --harts N`, defaulting to at least 2
and otherwise the build machine's online core count
(`compiler/Build.hs:71-80`, `110-115`). At run time the live count is
that cap, cut to the machine's cores, or to `FPR_HARTS`
(`machine/unix/main.c:60-91`). Builtin images are built with
`FPR_NHARTS=1` (`Makefile:398`). ESP-IDF pins one FreeRTOS task per
core (`machine/esp-idf/main.c:1-6`).

The actor surface is `spawn` / `spawnOn` / `spawnCap`, `send` /
`receive` / `receiveFrom`, `sendLinear`, `sendArc`, `yield`, `kill` and
sleep (`runtime/actors.c:4193-4258`; `std/actor.fpr:1-36`). `send`
never waits and answers `Ok` or `Err` (`mailbox full` / `dead actor`)
(`std/actor.fpr:15-18`). An ordinary `send` deep-copies a heap value
into an ownerless message slab, or inlines a tagged Int
(`runtime/actors.c:3478-3502`). `sendLinear` moves a received root, or
copies and consumes a local (`runtime/actors.c:3566-3586`). `sendArc`
is the only share path: the pointer crosses, the value is frozen by
contract, a `Vector` is refused, and a cross-process share becomes a
copy (`runtime/actors.c:4198-4217`).

Each hart has a local FIFO run queue of at most 4 and a ready backlog.
Admission prefers anyone who has waited more than `FPR_TAU` (64)
machine-wide admissions, otherwise a weighted pick
(`runtime/actors.c:1152-1166`). An idle hart steals the oldest unpinned
`READY` actor from other backlogs; a backlog past 4 rings an idle hart
(`runtime/actors.c:1168-1289`, `1209-1217`). Actor 0 and `spawnOn`
placements are pinned; a plain `spawn` can migrate at a safepoint
(`runtime/actors.c:207`, `1255`). Preemption is cooperative at
function-entry fuel ticks.

There is no `par`, `pseq`, future or task library, and no parallel
`map` / `fold`, in the language or in `std`. SIMD is intra-hart only:
two-lane Vector kernel pairs on hosted x64 and A64, off on posix
RISC-V and Builtin (`compiler/Compile.hs:936`).

Sharing between actors is by copy, by a linear move, or by an explicit
frozen share, not by a shared mutable heap. Each actor has its own slab
pool (`runtime/fpr.h:77-81`, `119-176`). Cost equations and declared
`work` / `alloc` / `live` contracts do not bound time spent waiting on
another hart. The scheduler states an admission bound, not a time WCET,
and explicitly does not bound cross-hart latency
(`docs/2026-10-02-SCHED-MODEL.md:74-115`, `133-137`).

## Layer 1: an explicit API

`parMap` and `parFold` are ordinary functions the program names. They
are not a change to sequential `map` / `fold`. A first cut lives in
`std`, next to `std/list` and `std/vector` (exact module names are
chosen at implementation). Both are `unsafe` until their cost contracts
are stated and checked, in the usual way (`compiler/Safety.hs:6`).

### Vector

`Vector` is already a linear contiguous carrier
(`core/prelude.fpr:22`, `726-749`). A `parMap` over a unique `Vector`
splits it into contiguous chunks, moves each chunk to a worker with
`sendLinear` (no element copy of the input), maps in place or into a
fresh chunk on that hart, and moves the results back to be concatenated.
`sendArc` is the wrong tool: it refuses a `Vector`
(`runtime/actors.c:4210-4211`), and a frozen share would not allow an
in-place write.

If the input `Vector` is not uniquely owned in the caller's hands, the
API does not silently alias it. The caller already holds a linear
handle; splitting consumes it.

### List

A `List` is a persistent cons spine today. Sharing tails is observable
in complexity and in WCET, which is why a global array-backed `List`
was rejected as a default
(`docs/2026-11-09-PERFORMANCE-PRIORITIES.md:354-358`). Until a
uniqueness proof applies, `parMap` on a `List` therefore chunks by
walking and copying a prefix of the spine into each worker (or into a
temporary `Vector` chunk), maps there, and merges the results back
into a list whose value equals the sequential `List.map`. The input
list is not consumed. This path will be more expensive per element
than the Vector path; whether it ever wins is a measurement, not a
claim.

Where uniqueness is proved, the [VList-backed linear lists](#vlist-backed-linear-lists)
section applies: those lists are already a chain of blocks, which
`parMap` can move as chunks with `sendLinear` instead of walking
cons cells. The prelude name `VList` is a namespace over `Vec`, not
this structure (`core/prelude.fpr:726-749`); the two must not be
confused.

### parFold

`parFold f z xs` is a tree of per-chunk folds combined by `f`. `f`
must be associative and `z` must be a unit for `f`, so the value
equals a left-to-right sequential fold. The contract is on the caller
for the explicit API; Layer 2 will only auto-select when `f` is on a
whitelist or is so annotated. A non-associative `f` is a misuse of the
explicit API, not something the runtime can repair.

### Chunking, workers and assembly

The number of chunks is on the order of the live hart count times a
small factor, so an idle hart can steal leftover chunks. The factor,
the minimum chunk length, and whether workers are spawned per call or
drawn from a kept pool, are to be measured. Stealing is the existing
per-hart mechanism (`runtime/actors.c:1168-1289`); pinned `spawnOn`
workers would not be stolen, so a pool of unpinned workers, or a
`spawn` onto a named hart without pinning every chunk, is the better
fit. Assembly concatenates Vector chunks, or joins List spines, in
input order, so the result is identical to the sequential operation,
including for a non-commutative map body that only reads its element.

### Failure, nesting and memory

A panic or an uncaught error in a worker fails the `parMap` / `parFold`
the way the sequential body would have failed that element; no sibling
chunk's result is returned. The exact rendezvous (whether already-running
siblings are killed, or only joined) is an implementation choice that
must not change the value of a successful run.

A `parMap` / `parFold` nested inside another, or inside a worker, falls
back to the sequential operation, or to a small bounded depth decided
at implementation and then measured. Unbounded nested fork would fight
the same harts for work and would make the cost contract dishonest.

Worker scratch is ordinary actor or region allocation. A worker's
loop can use today's copy-out and, on a unique Vector chunk, in-place
reuse (`compiler/Reuse.hs`, `runtime/runtime.c:2711-2774`). On join,
results move back with `sendLinear` where they are linear, or are
copied if they are persistent lists; a worker region may adopt a
result that is most of what it holds, as loop regions already do
(`runtime/runtime.c:2574-2577`). The parent does not reuse a cell that
a worker still holds.

### Cost contract

The declared bound is a sequential upper bound: the work and allocation
of the sequential `map` / `fold`, plus a fork/join term proportional to
the number of chunks (spawns, two moves or copies per chunk, and a
join). It does not claim a wall-time speedup and does not claim a
bound on cross-hart wait, matching the scheduler page's refusal to
bound that latency. `live` is the parent plus the workers' peak, which
is larger than the sequential peak when chunks are live together; that
is stated, not hidden.

## Layer 2: compiler-gated automatic use

Ordinary `map` / `fold` (and the `Vec` / `List` names that are those
functions) may be lowered to the explicit path only when every one of
these holds:

1. The element function is pure: no `send`, `receive`, I/O, or `Sys`
   effect the compiler can see, and no unknown callback. A function
   that already has a verified cost equation with no opaque I/O or
   actor primitive is the expected evidence.
2. For `fold`, the combiner is known associative: a whitelist covering
   at least `+`, `*`, `max`, `min` and `Map.union` (and the obvious
   companions such as `Int`/`F64` forms of those), or a user
   annotation chosen at implementation. `parMap` does not need this.
3. A static per-element cost estimate, from the cost pass, is above a
   threshold that is itself to be measured.
4. The call is not in WCET-checked or otherwise bounded code (a
   function whose declared `work` / `alloc` / `live` is being proved,
   or a target that admits a heap or stack budget as a hard limit),
   and not in Builtin or RV32 code.

If any condition fails, the sequential function is left alone. The
lowering is opt-in at this layer in the sense that the compiler must be
able to prove the conditions; a rollback flag (`FPR_NO_PAR_MAP` or
similar, name chosen at implementation) turns it off and belongs in the
unit cache tag, like the other `FPR_NO_*` flags
(`compiler/Compiler/Options.hs:92`, `127-135`).

## Layer 3: a runtime check at gated sites

Even a lowered call starts sequential unless `len xs` times the
estimated per-element cost exceeds a cutoff and at least one other
hart is idle (or `Sys.harts` is greater than 1 and the current backlog
suggests spare capacity; the exact idle test is an implementation
detail to measure). The sequential fast path must cost only a few
compares and must not spawn. Cutoffs are to be measured; they are not
set on this page.

## Per-target support

| Target | Layer 1 | Layers 2-3 |
|---|---|---|
| Hosted posix x64, A64, RV64 | Yes: multiple harts, `sendLinear`, stealing | Yes, under the gates |
| Builtin, including RV32 and `--arc` / `--raw` | No: single hart (`Makefile:398`), no compiler-placed actor regions in that profile (`compiler/Compile.hs:1127-1128`) | No |
| QOS process images (shared plane) | Yes, but workers are scheduled on the plane's harts, compiler-placed regions are skipped on the plane (`runtime/fpr.h:203-227`; `runtime/runtime.c:2508-2512`), and a cross-process `sendLinear` / `sendArc` copies (`runtime/actors.c:3591-3593`, `4215-4217`) | Only inside one process image, and only if the same purity and cost gates hold |
| Sol VM (`fpr run` of a `.sol` file) | Not on the VM's green-thread shim, which has no harts and no WCET (`compiler/Sol/VM.hs:500-509`). A Sol program compiled as hosted Base follows the posix row | No, on the VM |
| ESP-IDF (posix host, one hart per core) | Yes in principle, same runtime, subject to measurement on the board | Same gates, after a board measurement |

## VList-backed linear lists

The intended backend for a `List` whose use the compiler can prove is
linear is a Bagwell VList: a linked chain of heap blocks whose
capacities double. Ordinary cons-cell `List` remains the
representation wherever that proof does not hold, including any list
that shares a tail. The source type stays `List`. This is not a new
`List 1` type for the programmer to write, and it is not a change to
`Vector`. The 9 November priorities page rejected both a global
`--list-as-vec` flag and a second linear list type
(`docs/2026-11-09-PERFORMANCE-PRIORITIES.md:354-360`); unboxing B6
already named the conditional alternative: where ownership analysis
proves a list is built once and consumed linearly, the same
pattern-match API may lower onto chunked storage with observably
identical behaviour, and where the proof fails the cons cells stay
(`docs/2026-11-01-UNBOXING-ZERO-OVERHEAD-PROPOSAL.md:369-379`). This
section is that alternative, with a definite structure and a freeze
story for the moment uniqueness ends.

Three names that must stay distinct:

- **Prelude `VList`** is a `Struct` of operations over today's
  contiguous, linear `Vector` (`core/prelude.fpr:726-749`).
- **The old Vector "VList block directory"** was a per-column chain of
  blocks, shipped first and later rejected as Vector's layout because
  every random access paid a directory hop and log2 index math. Vector
  columns are now one contiguous span grown by `realloc`-by-doubling
  (`runtime/vec.c:1-14`, `35-58`; `docs/2026-08-25-VEC.md:18-37`).
  This proposal does not put that directory back under `Vector`.
- **A Bagwell VList**, here, is only a representation of uniquely
  owned `List`.

### Structure

A linear list is a pointer to a (block, offset) pair. The block holds
a contiguous run of elements and a link to an older, larger-or-equal
block. A cons that finds room in the current block writes the element
and advances the offset: an in-place bump. A cons that finds the block
full allocates a new block of twice the previous capacity, links it to
the old chain, and writes there. Intended complexities, as design
goals rather than measurements, are O(1) amortized cons, about O(1)
index (a walk of the block chain, which is logarithmic in length if
capacities double), and a cache-friendly traversal of each block as a
dense run.

The first-block size and the exact growth ratio are to be chosen and
measured. Vector columns today start at 16 words and double
(`runtime/vec.c:35-58`); that is the existing doubling ladder, not a
decision that this structure must use the same constants.

### Why only under proven linearity

The proof is the one `Reuse.hs` already requires for spine reuse:
public entries stay borrowing; last syntactic use of a borrowed
argument is never uniqueness; a fresh spine from `Nil`, or a list
threaded through a loop that nothing else holds, can be uniquely owned
(`compiler/Reuse.hs:1-3`, `268-271`). A retained tail, an
alias, or a value that escapes the unique root keeps cons cells.

Under that proof, no other list points into these blocks, so a cons
never fights a shared suffix for the next slot. In-place bump is
always safe, and a per-block "last used" or occupancy check for
sharing is unnecessary. The moment that would otherwise need such a
check is exactly the moment this representation is refused, or the
chain is frozen (below).

A global Vector or array backend would change the complexity of
`x :: xs` and of shared tails for every list, and so the WCET of the
same source, which is why `--list-as-vec` was rejected as a default
(`docs/2026-11-09-PERFORMANCE-PRIORITIES.md:354-358`). A Bagwell chain
used only where uniqueness is proved does not change those shared-tail
facts: unproved lists still cons in O(1) onto a shared tail of cons
cells.

### Choosing the representation, and the escape boundary

The compiler chooses the representation from the same uniqueness and
lifetime facts that feed reuse (P1 facts consumed by the ownership
plan, as the [reclamation intent](2026-11-11-MEMORY-RECLAMATION-INTENT.md:50-60)
already describes). It is a per-use or per-binding choice, not a
flag that rewrites every `List` in the program.

When a linear VList escapes to a context that may share it — a second
consumer, a stored tail, a return from a function that is not itself
proved unique, a `send` of a persistent value — the chain is frozen
in place as an immutable VList view, in preference to being converted
to cons cells. Freezing keeps the blocks and their structural sharing:
two tails that live in the same block share that block, and every
older block, by holding different offsets. Conversion to cons cells
is always correct and is the fallback when a view cannot be used
(an unknown foreign consumer, a boundary the copier does not yet
understand). It costs a walk of the live elements; that cost is
charged at the boundary, not hidden in later conses.

`x :: xs` on a frozen or linear VList is a view: `x` is the element at
the current (block, offset), and `xs` is the same chain at the
preceding offset, or at the end of the older block. No element is
copied. Cons onto a frozen chain must not bump that block; it
allocates a fresh unique prefix (a new block, or a cons cell) that
points at the frozen tail.

`keep` / message copy of a frozen VList copy the live blocks they
reach, not a cons spine. `sendLinear` of a unique (still linear)
VList moves the handle and the blocks, like a `Vector`.

### Reuse, regions, MutMap and Vector

In-place reuse of list spines (`$reuse.fresh` / `OReuse`,
`compiler/Reuse.hs:207`, `compiler/Codegen/Lower.hs:587-594`) and
element reuse (`compiler/Reuse.hs:184-193`) stay meaningful on a
VList: a unique element or a unique current block can be overwritten
instead of allocated. A frozen block is not overwritten.

Region copy-out copies whole live blocks of a VList that belongs to
the region, not each element as a cons cell
(`runtime/runtime.c:2711-2774`, the existing region-copy rules for
what lies inside the arena). On region exit, a result that is most of
what the region holds can still be adopted
(`runtime/runtime.c:2574-2577`). A unique VList handle crosses a
region by move, as `Vector` already does
(`runtime/vec.c:45-48`; `docs/2026-10-24-REGIONS-STAGE2.md` as cited
there).

`Vector` and `MutMap` / `FixedMap` remain the explicit linear
contiguous and hash-table types (`core/prelude.fpr:22-30`). This
backend does not replace them and does not make `List` a `Vector`.
A unique list that wants a single contiguous span can still convert
with `Vec.fromList` (`docs/2026-08-25-VEC.md:41-45`), which stays
explicit.

### WCET for VList operations

A cons that bumps an existing block is a bounded store. A cons that
grows allocates one new block whose size is the next step of the
doubling ladder, not a copy of the whole list. The per-operation worst
case is therefore bounded by that largest new-block allocation (plus
the ordinary element write). Compare Vector growth, which
`realloc`-copies the whole column and attributes that copy to the
push that grew (`runtime/vec.c:6-10`; `docs/2026-08-25-VEC.md:20-24`):
honest, but the worst-case payment at a growth is the whole history.
The first-block size and the ratio still have to be chosen so this
worst case can be named in a contract.

In WCET-checked or otherwise bounded code, either the list stays cons
cells (Layer 2 already refuses automatic parallelism there), or the
representation uses a bounded maximum block capacity so the growth
allocation has a static ceiling. Those constants are to be measured
and then declared. Inferred uniqueness, as with reuse, does not lower
a *public* bound of persistent `List`
(`docs/2026-11-11-MEMORY-RECLAMATION-INTENT.md:193-197`).

### Composition with parMap / parFold

A unique or frozen VList is already partitioned into blocks. Those
blocks are the natural chunks for `parMap` / `parFold`: a unique
chunk moves with `sendLinear` and needs no element-wise copy of the
input, the same as a `Vector` slice that has been split off a unique
handle. Frozen shared lists still need a copy of any block a worker
would write, or a policy that only reads (a `parFold` of a frozen
input can share read-only blocks). Assembly is still in input order,
so the result equals the sequential operation. Chunk-count factors
and whether a large last block is split further are to be measured.

### Relationship to `--list-as-vec` and Vector

`--list-as-vec` would have changed every `List` into an array-backed
structure, including those that share tails. It was rejected as a
default; B6, proof-gated flattening, was left as the compiler-chosen
alternative (`docs/2026-11-09-PERFORMANCE-PRIORITIES.md:128`,
`354-358`; `docs/2026-11-01-UNBOXING-ZERO-OVERHEAD-PROPOSAL.md:369-379`).
This page takes B6 and chooses Bagwell blocks rather than a single
contiguous `Vector` span, because a later freeze should share prefixes
by block and offset, and because a growth should not copy the whole
spine. `Vector` itself stays the compute-bound, explicitly linear,
contiguous column type (`docs/2026-08-25-VEC.md:1-14`,
`runtime/vec.c:1-14`).

## WCET

Parallel execution is excluded from WCET proofs, or costed as the
sequential upper bound plus the fork/join term above. A VList cons is
costed as a bump, or as the allocation of the next (bounded, in
checked code) block, as in the previous section. It is not costed
as "work divided by harts". Cross-hart wait is not a compile-time
bound today (`docs/2026-10-02-SCHED-MODEL.md:133-137`), C entries in
the send path do not preempt (`docs/2026-10-02-SCHED-MODEL.md:94-98`),
and this proposal does not invent one. A function that must keep a
proved `work` / `alloc` / `live` bound stays on the sequential path
(Layer 2, rule 4).

## Measurement plan

A crossover benchmark is the first implementation deliverable after a
correct explicit Vector `parMap`: vary length and per-element work,
plot sequential against `parMap` on 2, then more, live harts, and
record the length and cost at which `parMap` first wins. The same
sweep sets the Layer 2 threshold, the Layer 3 cutoff, the chunk-count
factor, and the minimum chunk length. List `parMap` and both
`parFold`s get their own sweeps; they may have no useful crossover.

The VList representation is validated on the in-tree app workloads
that are list- or map-heavy today — `wordfreq`, `csv` and `sim` in
`tests/bench/apps/` — against cons-cell `List` and, where a unique
list is already rewritten by spine reuse, against that baseline.
The measurements to take are allocation requests, instructions or
wall time, and peak RSS, with outputs byte-identical to the cons-cell
run. First-block size, growth ratio, freeze-versus-convert cost, and
whether block-chunk `parMap` ever beats sequential `List.map` are all
to be measured. This page does not claim a speedup on those apps.

The only timing this page relies on is a 15 November 2026 run of
`tests/bench/xpingpong.fpr` on the development x86_64 box (8
processors online), built from `edfa57cd` sources with `--harts 4`:
1,000,000 request/replies between actor 0 on hart 0 and a `spawnOn 1`
ponger finished in 0.951 s wall and 1.899 s CPU (ratio 2.00). That is
0.951 µs of wall time per cross-hart round trip. It is a
communication floor for a tiny Int message, not a `parMap` crossover
and not a WCET. All thresholds remain to be measured.

Outputs of every parallel run in that plan must match the sequential
run, byte for byte, including existing app and Benchmarks Game
fixtures if they are switched to `parMap` in an experiment.

## Open questions

- Worker lifetime: a per-call spawn of one worker per chunk, or a
  long-lived unpinned pool per process. Spawn cost is part of the
  fork/join term and must be in the crossover measurement.
- The idle-hart test for Layer 3: `Sys.harts`, a scheduler query, or
  both.
- The annotation syntax for an associative combiner that is not on the
  whitelist, and whether it is trusted or proved.
- How a panic in one worker is propagated without leaking the other
  chunks' linear buffers, including VList blocks moved with
  `sendLinear`.
- Whether QOS plane workers should be refused until a process-local
  measurement exists.
- Nesting bound: always sequential inside a worker, or a small depth.
- The first-block size, growth ratio, and maximum block capacity in
  bounded code.
- The exact freeze point: at the first escaping use, at a function
  return, or at `send`. When a frozen tail later becomes unique again
  (the last alias drops), whether it may thaw, or stays frozen.
- Whether a unique list that is only indexed and folded, never consed
  after construction, should instead lower to a contiguous `Vector`
  span (B6's "flat" alternative), or always to Bagwell blocks.
- Interaction with spine-reuse twins already in `Reuse.hs`: one
  mechanism, or a VList lowering that makes some twins unnecessary.

## Staged rollout

1. Explicit `parMap` on `Vector`, with a cost contract, sequential
   equality tests, and the crossover benchmark. No automatic lowering.
2. Bagwell VList as the representation of uniquely owned `List`,
   behind a rollback flag, with freeze-on-escape, `x :: xs` as a
   (block, offset) view, and equality of results against cons-cell
   `List`. Measure on `wordfreq`, `csv` and `sim`. No change to
   unproved lists and no change to `Vector`.
3. Explicit `parFold` on `Vector`, then `parMap` / `parFold` on
   `List` — using VList blocks as movable chunks where the proof
   holds, and the copying path otherwise — each with its own
   measurement.
4. Only if a measured crossover exists and is stable: Layer 2 gates
   and the Layer 3 fast path, behind a rollback flag, off in
   WCET-checked, Builtin and RV32 code.

A later page can supersede this one without rewriting it, in the usual
way.
