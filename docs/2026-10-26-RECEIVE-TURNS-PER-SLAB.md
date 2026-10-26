# Receive turns cycle per slab

Date: 2026-10-26. Step 1 of [the performance plan](2026-10-26-PERFORMANCE-PLAN.md),
decided by the user: a receive loop's scratch, and the messages its turns
received, are released when a slab has filled, not at every turn. This amends
the rule of [regions stage 1](2026-10-24-REGIONS-STAGE1.md), "a message dies
with its turn": on hosted targets it now dies at the first region boundary
after its turn, which comes within a slab. Memory stays bounded by a slab per
receive loop. QOS process images and builtin heaps are unchanged (below).

## Why

Every receive turn ran the `$receiveLoop` trampoline: two generic
applications, a fresh `(continue, closure)` pair and closure, a deep copy of
the next state into transfer storage, then root release and arena reset. In
same-hart pingpong that was 37% of the time ([regressions](2026-10-26-PERFORMANCE-REGRESSIONS.md)),
paid per message even for four Ints of state.

## The form

A receive loop now takes the loop-region form pure loops already use
([loop and call regions](2026-10-25-REGIONS-LOOPS-CALLS.md)): every member
gets an inner version with the pool mark and the activation's sequence
number, tail calls stay direct (the typed IR makes them jumps), and each
boundary member (each member that receives) tests the hart's allocation clock
on entry (`ORegionRoom`). Only when a slab has been charged since the mark does
the cold path run `$regionCycle`: the changing state is copied out, the roots
taken since the region opened are released, and the arena is reset.

Two differences from a pure loop:

- **The region opens at entry.** `$regionOpen` (new, `runtime.c`) opens it
  before the first turn, so every message the loop takes is above the region's
  root mark. A pure loop opens lazily because its state may live in the
  caller's pool; a receive loop's state may point into a message, so its first
  cycle must copy, which an open region does. The loop runs on the sequence
  number `$regionOpen` returns, which keeps the call: the first version fed the
  open into the mark read, whose inline lowering ignores its argument, and the
  open was dropped (the region opened at the first cycle and the first turns'
  roots outlived the loop).
- **Messages are charged to the clock.** A message lives in its sender's
  message slab, not the receiver's arena, so a loop that allocates nothing
  would never cycle. `fpr_rx_push` charges the hart's clock 64 bytes per
  received root (`FPR_RX_CHARGE`, which also caps a cycle at about a thousand
  roots) and a whole slab the first time a root pins a message slab the open
  region has not been charged for (`fpr_scope.msg_slab`). What the roots pin is
  then within the slab bound.

`region_close` now releases the roots taken in the region, after its result is
copied out. A region that received messages closes by copying even where it
could adopt, since an adopted result could point into a message.

## Where it applies

- Hosted targets (posix, and every image that owns its heap): the new form.
- QOS process images (`oQosApp`: `--system=qos-portable`, `qa64`, `qx64`,
  `qrv64`): unchanged. Their plane memory reclaims per turn through
  `$receiveLoop` and the kernel's `loop_turn`; the region hooks do nothing in a
  plane process, so the loop form would lose that reclamation.
- The builtin heap: the form applies, through the builtin region hooks; the
  builtin runtime never released message roots per turn, before or after.
- `FPR_NO_RECEIVE_TURNS=1` still turns receive turns off entirely.

## Known effect: the clock is per hart

The allocation clock belongs to the hart, so an actor's loop also sees the
allocations of other actors that ran on its hart between its turns, and cycles
earlier than its own allocation alone would make it. Early, never late: memory
stays bounded, and a cycle is cheap. In the probe below the consumer cycled
about every four turns (the producer's 1 KB strings are built by repeated
appends on the same hart). A per-loop clock (the region arena's own counter)
would remove this; it needs a different room test than the hart cell.

## Measurements (Apple M4)

| | before (trampoline) | after |
|---|---|---|
| pingpong (1,000,000 same-hart round trips) | 334-360 ms | 175-202 ms best of nine (169 on 2026-10-01; the spread is hart stealing, plan step 2) |
| xpingpong (cross-hart) | 391 ms | 263-271 ms (255 on 2026-10-01) |

A probe (`msgload`): a producer sends 200,000 one-kilobyte strings with an ack
per message; the consumer's loop keeps a count and two sums and appends to each
string. Peak resident memory and wall time on 1 / 4 harts:

| | peak | time | roots at exit | rx list grows |
|---|---|---|---|---|
| trampoline (`fpr` before) | 3 MB | 1.08 / 0.75 s | 0 | 0 |
| per-slab turns | 3 MB | 0.55 / 0.28 s | 0 | 0 (high-water 8) |
| receive turns off | 1,240 / 1,592 MB | 0.99 / 1.00 s | 200,000 | 6 |

`codegenRev` 125.

## Checks that changed with the rule

- `tests/check_receive_turns.py` and the `swarmkeeper` case asserted the old
  note text; recognised hosted loops now report "turn region at the receive
  (opens at entry, cycles per slab)". Every behavioural check in them passes
  unchanged (a million messages on one and four harts under 64 MiB,
  cancellation, mutual recursion, imported helpers, nominal state).
- `autodrop3` required the received-roots list never to grow past its inline
  eight; a cycle may now hold up to a slab's worth (1,024 roots), so the check
  keeps `arc_live = 0` exact and bounds the growth (one doubling here).
- `tools/runtime-costs.py` required more copies than the two message copies
  per operation (the per-turn state copy); state is now copied only at a cycle,
  so the ledger may sit at that floor.
- `tests/RegionInterfaces.hs` runs its trampoline-protocol checks in QOS mode
  (`R.Options ... False`) and adds a check that a hosted receive loop gets an
  entry that opens its region, loop helpers, and no trampoline helper.

## Validation

The full Base suite passes 137 jobs in 546 s on eight workers, with the
compile budget unchanged; the benchmark set and the probe above. The QOS sweep was not rerun: QOS app images keep the trampoline,
but the kernel and host-side tools built by the hosted compiler take the new
form.
