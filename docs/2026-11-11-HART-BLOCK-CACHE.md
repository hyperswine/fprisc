# The harts' block caches: freed blocks are recycled, not sent home

Date: 11 November 2026. Kind: implementation record with measurements.
Branch `hart-block-cache`, on top of
[actor death costs](2026-11-11-ACTOR-DEATH-COSTS.md). Runtime only
(`runtime/actors.c`, two helpers in `runtime/buddy.c`). Build flag
`-DFPR_NO_BLOCK_CACHE` removes it.

This is the slab recycling decided on 10 November: memory an actor gives
back stays with the hart that freed it and is handed out again, instead of
going home to the memory actor's buddy and being asked for again.

## Where blocks went

Every block an image owns comes from one buddy allocator behind the memory
actor: stacks, a pool's slabs, channel rings, bucket arrays. A request that
finds the buddy's lock free is served inline; one that finds it held is
queued on the memory actor, and the requester parks until the reply. A free
coalesces; the next take of that size splits again.

After the [death-path fixes](2026-11-11-ACTOR-DEATH-COSTS.md), four
concurrent spawners (200,000 short-lived workers, four harts) spent their
time here:

- 405,000 buddy takes and 400,000 frees, two of each per worker (its stack
  and its first slab), of which 10,000 to 18,000 takes found the lock held
  and went through the memory actor;
- two `mprotect` calls per worker, guarding its stack and unguarding it
  again, and a page fault reading the buddy header the guard had covered.
  With the harts no longer idle, `mprotect` was 1511 of the profile's
  samples and system time was 1.5 s of a 0.6 s run.

## What a hart keeps

Each hart has a small cache, filled by its own frees and emptied by its own
takes (`fpr_mem_give`, `fpr_mem_take`):

- **By order, the last few.** `CACHE_ORDERS` 4 and `CACHE_DEPTH` 4: up to
  four blocks each of the four smallest buddy orders (64 KiB to 512 KiB at
  the hosted geometry). A take of a size the hart has cached is a pop.
- **Stacks keep their guard.** A dead actor's stack waits guarded
  (`warm_put`) and is handed to the next spawn as it is: no `mprotect`
  either way. The buddy header is under the guard, so `stack_guarded`
  notes whether the block is charged in the block's top word (16 bytes the
  stack gives up) before the guard goes on.
- **Only plain blocks.** A block charged to a confined process's budget goes
  home, where the buddy un-charges it. A cached block is charged by its next
  taker as a fresh one is, and a charged spawner is not given a warm stack
  (its tag could not be written under the guard).

## What it must not cost

- **Memory someone else needs.** One hart can hold 3.75 MiB of blocks and
  four stacks. A take the buddy cannot serve empties every hart's cache
  into it and tries once more (`cache_flush`, from the inline path, the
  direct path and the memory actor itself), so a cached block never turns a
  servable request into "no memory". The caches have a lock for that alone.
- **Wrong numbers.** `Sys.memInfo`'s free figure adds the cached bytes back.
  They are free.
- **The admission tests' queue.** `FPR_ADMISSION_TEST` builds force requests
  onto the memory actor's queue to test cancellation there; the cache is
  compiled out of them.

A block cached by a hart that never asks for that size again stays cached.
The bound above is the whole of that cost.

## Measurements

Apple M4, arm64 macOS, four harts. "Start" is main before the death-path
fixes; "death fixes" is the commit below this one.

| Workload | Start | Death fixes | With the caches |
|---|---:|---:|---:|
| Four spawners, 200,000 workers: wall | 28-30 s | 0.43-0.73 s | 0.12 s |
| The same: system time | 0.8 s | 0.5-0.65 s | 0.01-0.02 s |
| The same: buddy takes | 405,000 | 405,000 | 4,400 |
| The same: takes queued on the memory actor | 10,000 | 10,000-18,000 | 0-1 |
| One spawner, 320,000 workers: wall | 6.79 s | 0.92 s | 0.47 s |

On a 16 MiB heap, after 800 workers have come and gone on four harts, the
main actor can build a 300,000-cell list. Before these two changes it could
not ("heap exhausted"): reaped channel blocks sat in limbo and `Sys.memInfo`
showed 9,984 KiB free where it now shows 13,888.

## What is still held: the acb

Resident memory is unchanged by this: 289 MiB after 200,000 workers, 459
MiB after 320,000. That is the acbs, 1408 bytes each, kept for ever by the
permanence contract. It is the remaining place where memory is not given
back, and the largest one for any program that spawns per request. The
[death-costs record](2026-11-11-ACTOR-DEATH-COSTS.md) lists what is in it.

## Check

`tests/check_spawn_scaling.py` gains the small-heap case. `check_base` passes
with the five jobs red on main set aside. arm64 macOS only: not run on
Linux, on QOS (whose apps reach the same buddy through the shared plane) or
on the boards, where the caches' bound is a larger share of memory.
