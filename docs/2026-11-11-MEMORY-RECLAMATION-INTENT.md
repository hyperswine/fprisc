# Memory reclamation intent: unique-cell reuse, then regions with copy-out

Date: 11 November 2026. Kind: decision record and intent. It changes no
compiler, runtime or library behaviour. This is the direction decided on
this date, not a specification and not an implementation record. It may
be reviewed or replaced later if measurement or a later review changes
the trade-off.

It answers decision 1 of the [performance priorities](2026-11-09-PERFORMANCE-PRIORITIES.md)
page (item 2). The mechanisms it chooses are already named there and in
the pages it links; this page records the choice, how the two compose,
and what is still open.

## Decision

On 11 November 2026, Jack decided to pursue **(a)** and **(b)** together,
and not **(c)**:

- **(a) Static in-place reuse of uniquely owned cells**, proved at
  compile time (Perceus-style without counts), extending `Reuse.hs` and
  the consuming workers from local fresh constructors to loop state.
- **(b) Regions with copy-out for unbounded list/tree state**, as the
  fallback that guarantees bounded memory when uniqueness cannot be
  proved.
- **(c) Precise ARC with reuse in Base is not chosen.** That matches
  the 23 October [cost-sized regions](2026-10-23-COST-SIZED-REGIONS.md)
  direction, which replaced Proposal B of
  [memory/I32 refinements](2026-10-12-MEMORY-I32-REFINEMENTS.md)
  (precise ARC in Base) as the long-term Base model: no reference
  counts in Base, and nothing is borrowed.

The goal is unchanged from the priorities page: application loops whose
state is a list, map or tree run in memory proportional to their live
data, with no annotation, and the WCET/`live` bounds stay sound.

## What (a) does

Today, `compiler/Reuse.hs` overwrites a freshly built constructor
nothing else holds, and [consuming workers](2026-10-20-CONSUMING-WORKERS.md)
let that unique root cross a private non-recursive helper. The proofs
are local: the parent must be fresh in the same function; borrowed
arguments and existing list nodes are not eligible; last syntactic use
of a borrowed parameter is not uniqueness; recursive record-update
loops and general list traversal are recorded as future work
([reuse roadmap](2026-10-20-REUSE-AND-PIPELINE-ROADMAP.md)). There is
no count traffic and no runtime ABI change. The path is 64-bit Base
with scheduler instrumentation and without ARC; RV32, Builtin and ARC
keep ordinary construction. `FPR_NO_REUSE=1` restores that path.

**(a)** extends that same idea from local fresh constructors to
loop-carried state. If the compiler can prove a cell is uniquely owned
and dead after this step, the step writes the new value into that cell
instead of allocating. `List.map step ps` can overwrite `ps` node by
node when nothing else refers to `ps`; a map insert can rewrite the
AVL nodes on the path it would otherwise copy. Nothing is counted at
runtime, so WCET stays a compile-time charge. It builds on P1's
escape, aliasing, uniqueness and lifetime facts and on P3's ownership
plan (the priorities page's placement; the
[pipeline roadmap](2026-11-07-PIPELINE-REFACTORING-ROADMAP.md) already
lists those facts as the shared consumers of reuse and regions).

The limit is the proof: whenever uniqueness cannot be shown (shared
tails, aliases, a proof budget, a borrowed parameter), (a) does not
fire and the step still allocates. Without a fallback, memory still
grows.

## What (b) does

Every allocation already goes into a region under the
[cost-sized regions](2026-10-23-COST-SIZED-REGIONS.md) model. A value
leaves a region by being copied into an enclosing region, or moved if
it is linear. Value semantics makes the copy unobservable, so a
boundary is a performance decision, never a soundness one. Linear
values (`Vector`, and now `MutMap`) already cross by handle.

[Stage 2](2026-10-24-REGIONS-STAGE2.md) places a self tail call as a
boundary only when every live parameter is of bounded size. A `List`,
a `String` or a recursive nominal (a `Tree`) in the state declines the
loop: copying that state every iteration would grow with the loop (the
proposal's rule 4). That is exactly the state of typical application
loops, and it is why those loops never get their memory back.
`FPR_RECEIVE_NOTES=1` lists the declining parameter. Pure-loop regions
that do qualify were later made a check on the loop's own back edge
rather than a trampoline
([loops and calls](2026-10-25-REGIONS-LOOPS-CALLS.md));
`FPR_NO_LOOP_REGIONS=1` turns that placement off.

**(b)** lifts stage 2's decline for unbounded list or tree state, and
copies live state out at a slab boundary. The copy cost is proportional
to live state per cycle, not to total allocation. The
[follow-ups](2026-10-27-FOLLOWUPS.md) already have a single-slab
generational path for receive-turn transfer slabs (retain immutable
nodes in the current slab, compact deeply after eight generations, or
sooner if the state no longer fits); (b) generalises that idea beyond
receive turns, as the priorities page already proposed. Nodes the new
state no longer reaches stay until the region's policy compact-copies
it; that pause is proportional to the live state's size, which `size`
bounds can bound.

Stage 2 already amortises a qualifying pure loop: the state is copied
out and the region reset only after a slab of scratch has been bumped
(`FPR_MSG_SLAB_SZ`), so garbage is bounded by one slab plus the state.
(b) needs a similarly cheap form for previously declined loops; a
trampoline per iteration is known to be too expensive on hot loops
(stage 2 withdrew it from the default for that reason).

The measured `Sys.loop` variant of sim, recorded on the 9 November
priorities page, bounded memory to 13 MB but took 1.5x longer.
That is the kind of cost (b) accepts as the price of a bound when (a)
cannot fire.

## How they compose

**(a) first, where uniqueness is proved; (b) as the fallback that
keeps memory bounded when it is not.** They are not alternative
product directions. The cost-sized regions proposal already states the
composition: uniquely owned state updated in place by `Reuse.hs`
produces no such garbage in the first place; copy-out and
state-region compaction reclaim the rest.

The compiler chooses as follows, once both are implemented:

1. On a step that would allocate a new version of loop or path-copied
   state, consult P1 uniqueness and lifetime facts as consumed by P3's
   ownership plan. If the cell is uniquely owned and dead after the
   step, reuse it in place. No new cell, and no copy-out of that cell.
2. If uniqueness is not proved, do not reuse. If the loop's state is
   an unbounded list, string, map or tree, place a region anyway
   (lifting the stage-2 decline) and copy the live state out at a slab
   boundary, then reset. Memory stays bounded by the live state plus
   at most a slab of garbage, or by the region's compaction policy.
3. Linear types already move by handle and are outside this problem.
   Shared persistent structure that is *intentionally* kept is copied
   or retained according to (b); that cost is real, not a bug.

A later payoff named on the priorities page follows from the same
rule: in-place reuse of unique AVL, HAMT and list nodes, so
persistent `Map`/`List` code can approach `MutMap` without
annotations, with (b) still bounding the cases uniqueness cannot
cover.

## Why not (c)

Precise ARC with reuse in Base (Perceus, Swift; Proposal B of 12
October) would free at last use and reuse a cell whose count is 1, and
would be the most general of the three. The 23 October regions
proposal set it aside, and this decision keeps that line, because of:

- count traffic on most copies and drops;
- larger code;
- atomic counts for cross-hart sharing;
- no up-front size, so admission and WCET still stop at the heap;
- Proposal B as written needs borrowed parameters, which FP-RISC
  rules out ([value semantics](2026-10-17-VALUE-SEMANTICS.md); the
  regions rule is "no borrowing").

The Builtin profile keeps its own ARC and raw modes; this decision is
about Base. A tracing collector for Base remains a non-goal of the
priorities page. Refcounting at the edges (`sendArc`, message roots)
is unchanged: the regions proposal would later count references to a
frozen shared *region*, not to each value, and that work is not part
of this intent.

## Phase placement

Unchanged from the priorities page, now with (c) dropped:

- The decision and a measurement plan belong now. Implementation
  follows P3's first slices (delivery order items 5 and 9).
- **(a)** is a P3 consumer of P1's uniqueness and lifetime domain
  ("Escape, aliasing, uniqueness and lifetimes: scalar replacement,
  reuse, regions").
- **(b)** is P6 region-room placement plus runtime copy-out. P6
  already names region room as a separate obligation stream in
  `Codegen.Placement`.
- Each lands with its own rollback flag (below), the 19-entry corpus
  drift explanation, and the QOS pairing gate required of a P3 slice.

## WCET and live bounds

- On the **reuse path**, the step does not allocate. The charge is
  the in-place write, not a new cell and not a copy of the live
  state.
- On the **copying path**, copy-out is charged in proportion to the
  live state at that boundary, and compaction (when the policy
  runs) in proportion to the state's size. That is the cost the
  23 October proposal already accepted as honest.
- **Declared `live`** of a loop becomes provable where its state
  size is, because the discarded scratch is released at the
  boundary instead of accumulating as `alloc`. Today's `live` is
  still conservative `alloc` plus frames under the pool model
  ([live memory](2026-10-02-LIVE-MEMORY.md)).
- WCET still charges the **copying path unless the type is
  linear**, because dynamic or inferred uniqueness is not
  guaranteed by the type (priorities page). A proved reuse is a
  compile-time fact about a particular build; it does not change
  the public contract of a persistent `Map` or `List`.

## Gates

From the priorities page; they are the acceptance line for the
implementation, not a claim that any of them hold today:

- RSS on csv and wordfreq grows no faster than the input (2x input
  gives at most about 2x RSS, not 2x garbage).
- sim RSS is flat over steps.
- The declared `live` bound of a loop becomes provable where its
  state size is.
- No change to outputs, trap order, or the scheduling contract of
  the [semantic policy](2026-11-07-PIPELINE-SEMANTIC-POLICY.md).

Every change keeps declared `work`/`alloc`/`live` bounds PROVEN or
reports them UNPROVED by name.

## Rollback flags

Each mechanism lands with its own `FPR_NO_*` flag, in the unit cache
tag, so a regression can be isolated and the previous path restored.
Names for the new flags are chosen at implementation; this page does
not invent them. The flags already in the tree that this work will
touch are:

- `FPR_NO_REUSE=1` already rolls back today's local reuse and
  consuming workers, including their cache identity. (a) keeps a
  rollback path: either this flag, if the new loop-state reuse can
  share it honestly, or a separate `FPR_NO_*` if the two must be
  independently disabled.
- `FPR_NO_LOOP_REGIONS=1` already turns off today's loop-region
  placement (bounded state only). (b) needs its own flag so
  copy-out for previously declined unbounded state can be rolled
  back without disabling those regions.
- `FPR_RECEIVE_NOTES=1` and `--cost` already report placed and
  declined turn regions; they should name the new (a)/(b) choices
  the same way.
- `FPR_STATE_GENERATIONS=1` is the existing single-slab
  receive-turn generation switch, with a compiled full-copy
  control. (b) should say, at implementation, whether it extends
  that path or sits beside it.

## Measured baseline

These numbers are the before-picture this work will be judged
against. They are not new measurements.

From the 11 November 2026 back-to-back run (off-tree write-up, same
Linux x86-64 box as the 9 November priorities measurement). "now" is
`b8518da` (main after the #69 merge). Later commits on main (#71,
#72) are cost-bound and no-specialization-sort fixes and are not
claimed to have moved these RSS figures.

| Workload | Time / peak RSS (`b8518da`) | Notes from that write-up |
|---|---|---|
| sim (20k particles x 2000 steps, persistent `List P`) | 2.862 s / 3668 MB | 36.9x the peer median; the same write-up also states 3.7 GB. Unchanged from the 9 November compiler within noise. C was 2 MB. |
| csv (parse 1M lines, aggregate by key) | 2.210 s / 1265 MB | 11.5x the peer median; rounded there as 1.26 GB. Time narrowed since 9 November; RSS unchanged. |
| wordfreq (2M words, persistent `Map`) | 3.578 s / 1992 MB | 20.5x the peer median; the same write-up also states 2 GB. |
| sim_loop (`Sys.loop`, bounded memory) | 4.319 s / 13 MB | Same program family as the priorities page's `Sys.loop` variant. |

The 9 November priorities page recorded the same `Sys.loop` variant
of sim as bounding memory to 13 MB but taking 1.5x longer. That 1.5x
figure is from that page, not re-derived here.

The same 11 November write-up records why the RSS has not moved:
sim's `run` loop is still declined as a region; every particle-step
allocates cells that are never freed. MutMap is a source change for
wordfreq and treemap, not a reclamation of persistent `Map`/`List`
loops.

## Open questions

This intent does not close these. They belong to the measurement
plan and to the implementation design:

- The exact uniqueness proof for loop-carried and path-copied nodes
  (what P1 must establish beyond last syntactic use; how shared
  AVL/list tails are declined).
- The cheap form of (b) for previously declined loops: a back-edge
  room test and a slab-amortised copy, not a per-iteration
  trampoline. Where that form still costs too much, whether (b) is
  on by default or only when `--cost` shows a growing live set.
- How (b) relates to `FPR_STATE_GENERATIONS` and to stage 2's one-slab
  amortisation: extend, or a separate path.
- Compaction policy for a state region that (b) places (`Compact
  AtDouble` and the other policies in the 23 October proposal are
  still unchosen for this use).
- WCET: inferred uniqueness never lowers a *public* bound of a
  persistent type; can a module-private or specialised copy of a
  function be charged on the reuse path when the proof holds for
  that build?
- What copy-out copies when a substring holds its buffer (priorities
  item 1.5, string slices, still open).
- Builtin and the Tang Nano heap still cannot reset a region
  (stage 2 leftover); (b) on that host needs allocator work the
  23 October table did not plan.
- The in-tree app suite and RSS recording (priorities item 0) are
  still off-tree; the gates above need that suite to be executable
  in the repository.

## Status

Intent only, 11 November 2026. No compiler, runtime or library change
is implied by merging this page. A later page can supersede it
without rewriting this one, in the usual way.
