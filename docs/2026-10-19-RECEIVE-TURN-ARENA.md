# The receive turn's arena stays with the actor

Date: 2026-10-19. Kind: measurement and runtime change. Applies from the
commit that carries this page, on branch `worktree-receive-turn-arena` over
main `041dc20`. Evidence: `tools/receive-turn-costs.py` (new), the paired
ledgers of `tools/runtime-costs.py`, `tools/bench.py`, the suites and the
100-session Liveboard probe, all recorded in
`bench/2026-10-19-receive-turn-arena.json`. Numbers are from this Mac
(Darwin arm64) with other sessions' builds running beside them: the ratios
are the finding, the milliseconds are indicative.

## What a turn paid

Every recognised receive loop (compiler/ReceiveTurns.hs) and every `Sys.loop`
or `Sys.loopWith` runs each turn under a fresh arena so the turn's garbage is
gone when the turn ends ([memory refinements](2026-10-12-MEMORY-I32-REFINEMENTS.md)).
The 2026-10-18 audit read the price of that boundary off `g_loop`; this page
measured it. With `FPR_COST_PROBE` the buddy now counts the blocks it hands
out and takes back (`fpr_cost_buddy_allocs`, `fpr_cost_buddy_frees`,
buddy.c, under its own lock) and each hart counts the turns it ran
(`cost_turns`); `tests/bench/costprobe.c` reports all three. The probe runs
three request/reply pairs, both sides recognised receive loops, one pair per
hart:

- `small`: the bench ponger (`tests/bench/pingpong.fpr`): the state is the
  actor's own handle, the turn allocates the next-turn closure and the
  `(continue, state)` pair and nothing else.
- `record`: the state is `(count, the last eight requests)`: eight or nine
  cells allocated and about 360 bytes copied a turn.
- `big`: the state is a 1,000-cell list reversed every turn: a thousand
  cells allocated and 24 KB copied a turn.

The pinger's own state `(me, p, k, acc)` is a tuple, so the pinger copies
every turn too; the figures below are averages over both actors of a pair.

Before, per turn, whatever the state:

| per turn | before |
|---|---|
| buddy blocks taken | 2.00 |
| buddy blocks returned | 2.00 |
| message slabs opened | 1.00 |
| bucket array taken, zeroed (4 KiB), returned | 1 |

One block is the arena's first slab (64 KiB, taken on the turn's first
allocation, which every turn makes: the trampoline's closure lives there),
the other the transfer slab (64 KiB) the next state is copied into. Both go
back to the buddy at the turn's end, where `buddy_free_locked` scans a free
list per order under the one spinlock to coalesce; the bucket array goes
through the recycler's lock twice more. A state that is an `Int` still pays
the transfer slab: what crosses the boundary is the next-turn closure, a
`PAP` with its arguments, never a bare `Int`.

A sample of the `small` pair on one hart put the boundary at about a third
of the turn: the 4 KiB zeroing alone was 9% (`_platform_memset`, 130 of
1,500 samples), `buddy_alloc_try` + `buddy_free_try` + `fpr_grow_counted` +
`fpr_mem_take` + `fpr_mem_give` + `fpr_charge` + `fpr_bkt_take` +
`arena_close` + `transfer_free` another 11%, `has_vec` 2%.

## What changed

Three things, all in `runtime/runtime.c`, none visible to a program:

1. **The arena stays open for the whole loop.** `g_loop` and `g_loop_with`
   open one arena before the first turn and close it after the last.
   At each turn boundary `arena_reset` rewinds it instead: the chain head
   (the newest slab, the size the turn's doubling settled on) keeps its
   block with the bump pointer back at the start; the slabs behind it go
   home; a slab something escaped from during the turn (sent by reference)
   is orphaned exactly as `arena_close` orphaned it, and returns when its
   last promoted object drops. The bucket array is kept and cleared, not
   returned. Death tears the open arena down as it tore down a turn's
   (`fpr_pool_reclaim` walks the scope chain; nothing new there).

2. **The bucket array is zeroed only when something was freed.** A slab's
   spare header word (`fpr_slab_t.pushed`, the former alignment pad) is set
   by `fpr_free` when a cell of that slab goes to its pool's buckets.
   `arena_reset` reads it on every slab it walks and zeroes the 4 KiB only
   when one says so, clearing it on the slab it keeps. A turn that frees
   nothing, which is most turns of most loops, leaves the heads as the last
   zeroing left them. The flag lives in the slab rather than beside the
   bucket heads because QOS carves bucket arrays of its own by
   `FPR_NBUCKETS` (`qos/native/proc_entry.c`, `qos/appside/entry.c`); a
   longer array would have overrun them. Nothing changes in `fpr_pool_t`
   or the ACB: no ABI moves. The recycler's own zeroing in `fpr_bkt_take`
   is a `memset` now rather than a loop the compiler did not vectorise
   (the loop form of the reset, tried first, cost more than the buddy
   traffic it replaced: 777 samples where the old `memset` had 130).

3. **Two transfer slabs per loop, not one per turn.** A scope keeps
   `held`, the state the next turn reads, and `spare`, the slab the
   previous state was in. `transfer_copy` copies the next state into the
   spare when it fits, else into a fresh, bigger slab (the spare goes
   home); `transfer_retire` moves the state the turn just left behind into
   the spare, keeping the larger of two. A slab a promoted object still
   pins is never reused: it returns when that object drops, as before.
   The reissue resets the slab's `promoted` pre-check flag, on the same
   argument the recycler uses (nothing in the slab is referenced).
   `Sys.arena` goes through the same copy with no spare.

The three walks of the state graph are two: `has_vec` folded into the copy
as a refusal the copy context carries (`dctx_t.novec`: the `T_VEC` arm of
`dc_dup` panics by the loop's name). The sizing walk stays: the copier
bumps without bounds checks, and a bounds check with an unwind in a
recursive copier is not clearer than one walk that sizes. The checks on the
initial state and on the callback's captures at loop entry still use
`has_vec` once.

## Per-turn cost before and after

`tools/receive-turn-costs.py --runs 3`, best of three plain runs, ledger from
the instrumented build. One hart is one pair; four harts are four pairs, one
per hart. CPU is user + system of the process over all its turns.

| shape | harts | turns | buddy ops / turn | message slabs / turn | CPU ns / turn | wall ms | turns / s |
|---|---|---|---|---|---|---|---|
| small | 1 | 1,000,006 | 2 + 2 -> 0 | 1.00 -> 0.00 | 214 -> 123 | 217 -> 126 | 4.6 M -> 8.0 M |
| small | 4 | 4,000,017 | 2 + 2 -> 0 | 1.00 -> 0.00 | 2,877 -> 746 | 2,946 -> 766 | 1.36 M -> 5.2 M |
| record | 1 | 400,006 | 2 + 2 -> 0 | 1.00 -> 0.00 | 326 -> 204 | 133 -> 84 | 3.0 M -> 4.8 M |
| record | 4 | 1,600,016 | 2 + 2 -> 0 | 1.00 -> 0.00 | 2,443 -> 738 | 1,010 -> 304 | 1.6 M -> 5.3 M |
| big | 1 | 40,006 | 2 + 2 -> 0 | 1.00 -> 0.00 | 6,633 -> 5,363 | 267 -> 217 | 150 k -> 184 k |
| big | 4 | 160,018 | 2 + 2 -> 0 | 1.00 -> 0.00 | 8,895 -> 6,245 | 369 -> 257 | 434 k -> 622 k |

"0" is 2 to 11 blocks per million turns: the first slabs of each actor and
the spawn and kill around the pair. On one hart the small turn is 123 ns
of which the copy of the next-turn closure (`dc_size` + `dc_dup`, 120 bytes)
is now the largest item; the 4 KiB zeroing is gone from the profile. On
four harts the before figure was mostly the buddy lock and the memory
actor's queue: four pairs took 3.9x longer on the wall than one pair did,
and now take 1.4x (the arc lock and the mailbox remain).

The ratchet's two actor benches (`tools/bench.py pingpong xpingpong`, best
of seven, the same binary shape as `small`):

| bench | before | after |
|---|---|---|
| pingpong (one hart, 1,000,000 round trips) | 646 ms | 352 ms |
| xpingpong (across harts) | 1,033 ms | 400 ms |

Both still read SLOWER against `bench/baseline.json`, which was recorded
on another day's build; the sibling pages of 2026-10-18 found main already
2.7x and 4.2x over it. The baseline was not re-recorded here.

## What is kept, and what moved

- **A turn's garbage is gone at turn end.** Nothing allocated in a turn is
  reachable after it: the slab is rewound, the buckets cleared, big-block
  LIFO dropped, exactly the set `arena_close` released. What changed is
  where the bytes sit while nothing references them: in the actor's kept
  slab rather than on the buddy's free list. Memory per long-lived loop is
  the live state, twice at most, plus one arena slab of the size its turns
  settled on and one spare transfer slab -- bounded by the largest turn and
  the largest state, as before, not by the number of turns.
- **Idle footprint.** Between turns an actor in a receive loop used to hold
  one transfer slab (64 KiB floor); it now holds that, a spare of the same
  size, its arena slab (64 KiB floor) and the 4 KiB bucket array: 196 KiB
  against 64 KiB at the floors, for each actor sitting in a receive loop.
  This is what the Liveboard probe below measures at the scale of a server.
- **Actor death frees everything.** `fpr_pool_reclaim` tears down each
  scope's arena (the open one included) and releases both transfer slabs
  (`scope_release`); an actor ended while a copy is in progress finds the
  slab being filled in `spare`. `tests/check_actor_reap.py` and the
  receive-turn million-message test are the checks.
- **Inbox admission accounting is unchanged.** The admission charge of
  [2026-10-13](2026-10-13-INBOX-ADMISSION.md) still counts one potential
  message slab per queued graph; transfer slabs were never part of it (the
  state is not queued anywhere) and still are not. The deliberate
  overcount per message stands as written.
- **The runtime-costs ledgers are exact as before.** The allocation ledger
  and the paired message ledger (`--receive-turns off`) count the same
  requests and copies; the turn mode's `message_slabs` falls, which that
  ledger never asserted exactly (its comment says why). The tool's
  expectations were not changed.
- **No ABI moves.** `fpr_pool_t`, the ACB and the hart block are as they
  were (the hart's new counter is under `FPR_COST_PROBE` like its
  neighbours); `fpr_slab_t` renames its pad word. QOS kernels pick the
  change up when rebuilt against this runtime; a loaded process runs the
  kernel's loop through the memory plane as before.
- **Sys.arena** copies its result through the same `transfer_copy`
  (no spare: one fresh slab per arena, freed at exit as before) and refuses
  a Vector result by the same name during the copy rather than before it.
  The panic is the machine's either way (`fpr_cpanic`).

## The Liveboard at 100 sessions

`tools/session-memory.py --qos ../qos`, the real QOS Liveboard with the
snapshot hook, four harts, 2 GiB heap, three runs each way alternating
(before from the main checkout at `041dc20`, after from this branch).
At 100 sessions, median of three (min to max):

| | before | after |
|---|---|---|
| peak RSS | 541 MiB (512 to 549) | 591 MiB (521 to 599) |
| admission of 100 sessions | 5.16 s (3.20 to 6.10) | 4.77 s (3.17 to 5.77) |
| buddy in use at the snapshot | 96.9 MiB | 97.8 MiB |
| message slabs opened | 2,891 | 2,711 |
| allocated bytes | 31.2 GB | 31.5 GB |
| 50 sessions, peak RSS | 270 MiB | 256 MiB |

Admission time is the same within its noise (this Mac was running other
sessions' builds; the spread is wider than the difference). Message slabs
fall by 6%: the transfer slabs the session loops no longer open. Buddy
memory in use at the snapshot rises by 0.9 MiB: the kept arena and spare
slabs of the loops parked at that moment. Peak RSS at 100 sessions reads
9% higher by the medians while the ranges overlap and the 50-session figure
reads lower; three runs do not separate a real 25 MiB (211 actors spawned,
two 64 KiB slabs each if every one sat in a loop) from the run-to-run
spread of 40 to 80 MiB this probe shows. The honest statement is: the
retained slabs cost each parked loop up to 132 KiB more than before, the
buddy sees under 1 MiB of it in this server, and peak RSS is not shown to
move outside its noise. If idle footprint matters more than turn cost for
some deployment (a board with a few MiB), the lever is to give the kept
slab back when an actor parks for longer than a turn; that is not done
here and the page that does it should measure the Pi.

## Verification

- `tools/receive-turn-costs.py --runs 3`: the tables above; every run's
  check line matched the expected sum (the probe computes it).
- `tools/runtime-costs.py --quick --runs 1`: exit 0, the allocation and
  paired message ledgers exact as the tool asserts, unchanged
  expectations; the turn-mode ledgers now show 4 message slabs for 514
  turns where there were about 514.
- `tests/check_receive_turns.py` and `tests/check_loop_state.py`: PASS
  (one million ordinary recursive receives under 64 MiB on one and four
  harts, cancellation releasing transferred closures, the opt-out baseline
  still growing).
- `tests/check_std.py`: PASS in full (the two failures the 2026-10-19
  std-suite page repaired are on main now).
- `tests/check_base.py`: every step PASS up to `check_specialization.py`,
  which needs the cabal package database the worktree does not have
  (`dist-newstyle`); it and `check_workers.py` test the compiler, which this
  branch does not touch, and both PASS run from the main checkout; the
  steps after them (the inline block: admission, confined processes, the
  heap-nil loop, fixed heaps, traps, the job broker, I64 and the rest)
  were run from a copy of the file with those two lines removed, PASS.
- `tools/bench.py pingpong xpingpong`: the table above; the two still
  exit 1 against the stale baseline, as they did on main.
- The Liveboard probe: the section above.

## Not verified

- QOS: no QOS image was built or run against this runtime (the plane path
  is the same code; the Liveboard probe exercises it as a host program).
- Hardware: the Pi 4, STAR64 and the boards were not run; the buddy and
  the memory actor are the same code there, the profile is not.
- `fpr sol` and the hosted (`std/hosted`) runners were not measured.
- The idle footprint figure (196 KiB against 64 KiB per parked loop) is
  arithmetic from the slab floors; the probe's peak RSS is the measured
  quantity.
