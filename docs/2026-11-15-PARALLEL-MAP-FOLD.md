# Parallel map and fold: an explicit API, then gated automatic use

Date: 15 November 2026. Kind: design proposal and plan. It changes no
compiler, runtime or library behaviour. This is the direction proposed
on this date, not a specification and not an implementation record. It
applies to `origin/main` at `edfa57cd` (merge of PR #79). Thresholds,
chunk factors and cutoffs named below are to be measured; the only
timing used here is the xpingpong point recorded in the measurement
plan. The proposal may be revised or replaced if measurement or a later
review changes the trade-off.

It follows from the current actor, hart and memory model, recorded in
the [scheduler model](2026-10-02-SCHED-MODEL.md), the
[memory reclamation intent](2026-11-11-MEMORY-RECLAMATION-INTENT.md)
and the [15 November review of parallelism](#current-state) below.

## Goal

Add explicit `parMap` / `parFold` that run independent element work
across harts, with results identical to the sequential `map` / `fold`.
Optionally, and only when a later gate and a runtime check both fire,
let ordinary `std` `map` / `fold` use that path. There is no implicit
data-parallelism today, and this page does not propose one that is on
for every call.

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

A `List` is a persistent cons spine. Sharing tails is observable in
complexity and in WCET, which is why a global array-backed `List` was
rejected as a default
(`docs/2026-11-09-PERFORMANCE-PRIORITIES.md:354-358`). `parMap` on a
`List` therefore chunks by walking and copying a prefix of the spine
into each worker (or into a temporary `Vector` chunk), maps there, and
merges the results back into a list whose value equals the sequential
`List.map`. The input list is not consumed. This path will be more
expensive per element than the Vector path; whether it ever wins is a
measurement, not a claim.

`VList` in the prelude is a namespace over `Vec`, not a second list
representation (`core/prelude.fpr:726-749`). This proposal does not
change `List`'s backend. Proof-gated flattening of a unique list
(unboxing B6 on the priorities page) remains a possible later
optimisation of the List path, not a change of the type's default.

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

## WCET

Parallel execution is excluded from WCET proofs, or costed as the
sequential upper bound plus the fork/join term above. It is not costed
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
- Whether a unique `List` can be flattened to Vector chunks by the
  existing proof-gated unboxing path (B6), without making Vector the
  default `List` representation.
- How a panic in one worker is propagated without leaking the other
  chunks' linear buffers.
- Whether QOS plane workers should be refused until a process-local
  measurement exists.
- Nesting bound: always sequential inside a worker, or a small depth.

## Staged rollout

1. Explicit `parMap` on `Vector`, with a cost contract, sequential
   equality tests, and the crossover benchmark. No automatic lowering.
2. Explicit `parFold` on `Vector`, then `parMap` / `parFold` on
   `List`, each with its own measurement.
3. Only if a measured crossover exists and is stable: Layer 2 gates
   and the Layer 3 fast path, behind a rollback flag, off in
   WCET-checked, Builtin and RV32 code.

A later page can supersede this one without rewriting it, in the usual
way.
