# Actor death: three costs proportional to every actor ever spawned

Date: 11 November 2026. Kind: measurement and fix record. Branch
`slab-recycling`, base `55950a6`. Runtime only (`runtime/actors.c`); no
compiler change, no `codegenRev`.

This began as the first step of the memory work decided on 10 November:
keep freed slabs in the process instead of returning each to the memory
actor. Measuring where slabs go showed that the allocator was not the cost.
Three other things were, all in the path of an actor ending, and all
growing with the number of actors a program has ever spawned.

## What slabs already do

`Sys.memInfo` deltas over 20,000 iterations, hosted, arm64:

| Workload | Buddy takes | Frees |
|---|---:|---:|
| A request server whose every request builds and drops a 3000-cell list | 11 | 8 |
| A function that allocates a 3000-cell list, called in a loop | 5 | 4 |
| A short-lived worker per iteration | 40,805 | 40,012 |

Receive turns and call regions already keep and reuse their slabs. The
buddy is touched per actor lifetime (a stack and a first slab), not per
request, and on an uncontended lock it is served inline. A profile of the
worker loop showed no allocator function at all.

## What the profile showed instead

Four concurrent spawners, 200,000 short-lived workers in all, four harts:
28 to 30 s of wall time and about 100 s of CPU. A single spawner did 20,000
in 0.65 s. In order of discovery:

1. **A new actor's watcher fields were never initialised.** `spawn` sets an
   acb's fields one by one and left out `watch` and `watchers`. The acb
   arena is carved from recycled buddy blocks, not from zeroed memory, so
   once stacks and slabs had churned a new acb read a stale word as its
   watcher count. `wake_watchers` then did what it does when there are
   watchers: walk the ledger of every acb ever made. 14,372 of 17,700
   profile samples were in that walk. With the two fields set: 2.8 s.

2. **The channel-block limbo was a list walked under a lock.** A reaped
   actor's channel block waits until every hart's epoch has advanced twice.
   `chb_take` looked for a matured block by walking the list from its head,
   and `chb_limbo_put` pushed at the head, so every spawn walked past every
   block reaped since. It also meant a single hart asleep in `wfi` held
   every block in limbo for as long as it slept, since a sleeping hart's
   epoch does not move.
   - The limbo is now a queue, oldest first. Stamps only grow, so if the
     head has not matured nothing behind it has, and a take looks at one
     block.
   - A hart observed inside `hal_wfi` after a block was stamped counts as
     advanced. It has no send in flight, and a send it starts on waking
     reads `var == DEAD` and never touches the channels. `hart_phase` 4
     brackets the `wfi` and nothing else; both stores are now `seq_cst`.

   With both: 0.43 to 0.73 s for the four spawners, and a single spawner's
   320,000 workers in 0.92 s where they took 6.79 s.

3. **A death with real watchers walked the ledger by design.**
   `receiveFromRes` parks on a sender and is woken when it dies, and the
   dier found its watchers by scanning every acb for `watch == me`. A
   parent that waits for each of its workers to end:

   | Workers | Before | After |
   |---:|---:|---:|
   | 20,000 | 1.46 s | 0.31 s |
   | 80,000 | 109.78 s | 0.40 s |
   | 320,000 | not run | 0.83 s |

   An acb now carries the list of actors parked on it (`watch_head`, through
   each watcher's `watch_nx`, under `watch_lock`). A watcher links itself
   before it counts itself, and counts itself before `block_unless`
   re-checks DEAD, so the lost-wake pairing is the one it was. The dier
   wakes outside the lock, since a wake ships across harts: under the lock
   it picks up to 32 watchers it has not picked (the low bit of their
   `watch`), unlocks, wakes them, and repeats. A watcher killed while parked
   is unlinked in `reap`.

`acb_t` grows by three words (1384 to 1408 bytes on arm64).

## Still true, and the next question

**Every actor ever spawned keeps its acb.** That is the stated permanence
contract: an actor value is its acb's address, and a send to a dead actor
is a read of `var == DEAD`. Resident memory after the fixes still grows by
about 1.4 KiB per spawn and is never returned: 449 MiB after 320,000
workers. A service that spawns a session actor per request holds 1 GiB per
700,000 requests.

The comment at the acb's definition says about 250 bytes. It is 1408. The
largest fields are live-only: the pending call regions (288), the context
(192), the reason text (160), the received roots (96). Moving what a dead
actor does not need into a block that `reap` returns would cut what stays
to roughly a tenth. That is a change to a structure QOS shares and is not
made here.

**The buddy is contended under concurrent spawn.** 10,000 to 18,000 of
400,000 takes queued on the memory actor in the four-spawner run, and each
stack is guarded and unguarded with `mprotect`. System time is now most of
that workload (0.5 of 0.7 s). A per-hart cache of blocks in front of the
memory actor is the slab recycling this work set out to do, and is the
next step.

## Check

`tests/check_spawn_scaling.py` (new, in `check_base`, run alone): watched
workers and four concurrent spawners at n and 8n must take at most 24 times
as long plus a second. They take 5 to 6 times; the old code took 60 to
several hundred.

`check_base`, with the five jobs red on main set aside: all pass.
