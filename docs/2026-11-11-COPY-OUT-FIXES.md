# Copy-out fixes: a live-size trigger, no foreign copies, preserved sharing

Date: 11 November 2026. Kind: implementation record with measurements.
Branch `bench/apps`, on top of the [application workloads](2026-11-11-APP-WORKLOADS-AND-GARBAGE.md)
commit. This implements item 1 of that page's "What can be done". It is
runtime-only: `runtime/runtime.c`. There is no compiler, codegen or ABI
change, and `codegenRev` is unchanged.

## Summary

| Case (copy-out selected) | Before | After |
|---|---|---|
| sim, `FPR_PERSISTENT_LOOP=run` | 2.9 s / 15 MB, state copied every step | 1.6-1.8 s / 17 MB, every other step |
| scan: 1M-element input built before the loop, 4-element window | 2.71 s / 95 MB, 4.9 GB copied | 0.29 s / 34 MB, 0.39 MB copied |
| history: 20,000 versions sharing their tails | 4.21 s / 1387 MB, 4.2 GB copied | 0.31 s / 7 MB, 0.85 MB copied |

- Interleaved on a loaded machine, sim with copy-out now runs in the same time as sim without it
  (2.13 s against 2.10 s) at 17 MB instead of 2.7 GB.
- Outputs are unchanged.
- All three changes apply only to **pure loop regions**. Receive loops keep today's every-slab cycle, which also releases the messages their turns took.
  `Sys.arena`/`loop`/`loopWith` and message copies pass no region and are unchanged.

## The three changes

### 1. Copy when the arena has grown by k times the last copy

`g_region_cycle` used to copy the live state at every trip of the back-edge
room test, that is, after every 64 KiB of allocation. sim's live state is
about 1.6 MB, so it copied 1.6 MB for every 64 KiB it could free.

The scope now records:
- `live_bytes`: what the last copy produced, the used bytes of the new state slab;
- `alloc_mark`: the arena's `allocated` gauge at the last reset.

A cycle whose arena has bumped less than `FPR_REGION_GROWTH * live_bytes` since then returns the packed state unchanged.
It keeps the arena; the back edge re-marks and asks again a slab later.
Two bounds follow:
- the copy work is at most 1/k of allocation;
- the region holds at most about k + 1 times the live state.

`FPR_REGION_GROWTH` is a C define, default 2, the intent's `AtDouble`. Deferred cycles are counted (`fpr_region_deferrals_count`).

sim, by k (single runs of three):

| k | time | peak RSS |
|---|---|---|
| 0 (the old behaviour) | 2.83-3.01 s | 15 MB |
| 2 | 1.48-1.68 s | 17 MB |
| 4 | 1.25-1.69 s | 21 MB |
| 8 | 0.95-1.24 s | 25 MB |

At k = 8, sim with copy-out beats sim with no reclamation (1.35 s / 3.7 GB):
the reused arena stays in cache, where fresh pages had to be faulted in and zeroed.

Note: `fpr build --cflag` does not reach the runtime's compile or its cache key. The sweep above edited the define.

### 2. Do not copy what lies outside the region

`dc_dup` copied everything reachable except retained nodes, actors, statics
and movable vectors. A cell in the caller's pool, an enclosing region's arena or the
base pool was re-copied at every full compaction, although none of them can be reset while the loop
runs, because regions nest LIFO. For a loop walking an input built before it, that
meant re-copying the remaining input every eighth cycle: 4.9 GB on the scan fixture.

A region copy now carries `dctx.region`, the loop's arena. A cell whose slab
is owned by another pool stays by identity; vectors keep their own move-or-copy rule.
The cells still copied are:
- cells of the arena;
- cells of ownerless slabs: the previous transfer slab, messages and orphans.

The sizing pass reads the same region from a thread-local, set only around `dc_size_in`, which never parks.
The copy pass takes it from the copy context, because `msg_slab_new` between the two
passes may park the actor and move it to another thread.

For review: a transfer slab's graph may now point into the caller's pool.
`sendArc` promotion pins only the root's slab, so a shared state root leans on
the same per-slab escape rule as any ordinary pool graph, which already spans
slabs. The `check_state_generations` ARC export case passes.

### 3. Preserve sharing, paying for it only when there is sharing

The copier walks a tree, so a cell reached twice was copied twice. A state that
keeps versions sharing a tail grew quadratically: 4.2 GB copied for 20,000 versions.

A hash map on every copy would cost sim about 0.4 s. Instead the sizing pass of a
region copy has a cap: the bytes the arena bumped since its reset, plus the state slab, plus one slab of slack for ownerless slabs.
A tree walk over distinct cells can never exceed that.
- Within the cap: nothing changes.
- Past the cap: the walk stops at once, so a heavily shared graph cannot make it exponential. The copy then:
  1. sizes again with a table (open addressing, in an ownerless slab for the one copy) that counts each cell once;
  2. copies with the same table as a source-to-copy map.

  A shared tail mid-spine is patched to its existing copy. Vector headers and heap nils go in the table too, so sizing and copying agree.
- Past 3/4 full: if the table would pass 3/4 full, which happens only when the state reaches more cells than the cap predicted (through ownerless slabs), it is dropped and the old tree copy is used.
  The sizing and copy passes therefore always visit the same set of cells.
- Shared copies are counted (`fpr_region_shared_copies_count`).

## Tests

- `tests/bench/reclamation/persistent_aliases.fpr` gains `scan` and `history`.
- `tests/check_persistent_reclamation.py` checks both:
  - outputs, the old version, copy-out on/off and cache rollback;
  - with copy-out on, the state bytes copied stay under 4 MiB (scan) and 16 MiB (history). They were 4.9 GB and 4.2 GB.
- Passing: check_persistent_reclamation, check_consuming_reuse, check_state_generations (1/4 harts, full-copy control, ARC export), check_receive_turns, check_loop_state, check_arena_migration.
- `tests/check_base.py`: everything passes except `check_x64_scalar.py`. That check fails identically with the unmodified runtime: an `rotate63` store assertion in x86-64 emission, unrelated to this change.

## Open

- **The default for k.** 2 keeps peak memory at about 3x live. 4 or 8 is faster on
  sim and still tiny there, but scales to 5-9x live on large states.
- **Automatic selection.** Copy-out is still opt-in per function. The next step is to admit every loop stage 2 declines, including loops inside `List.fold`,
  whose state is the closure's accumulator. Selecting `fold` or `inserts` today does nothing.
- **`region_close`** still copies a cycled loop's result without the region rule,
  so it re-copies caller-pool cells into the caller's pool. This is correct but wasteful.
- **Sharing is not used by messages or `Sys.loop`.** They keep the tree copy and its existing admission budget.
