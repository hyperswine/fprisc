# Steps 6-8: what landed and what remains

Date: 2026-10-27. Kind: status and plan for the rest of steps 6-8 of
[the performance plan](2026-10-26-PERFORMANCE-PLAN.md).

## Landed

- Step 7, first part: [live-range holes and loop-weighted spills](2026-10-27-REGISTER-PRESSURE.md),
  with a register-pressure model gating loop motion.
- Step 6, first part: [clobber-free ticks and noreturn kernel traps](2026-10-27-CLOBBER-FREE-TICKS.md).

## 1b. A parked receive loop keeps its messages (found, not fixed)

Step 1 ([receive turns per slab](2026-10-26-RECEIVE-TURNS-PER-SLAB.md))
releases a receive loop's messages when its region cycles, which happens
once a slab of allocation has passed. The plan also named a second trigger,
cycling when the actor parks while holding messages, and it was not
implemented. An actor that ends parked in its receive therefore keeps the
messages taken since its last cycle, at most about 1,024 roots (a slab at
`FPR_RX_CHARGE`), until it next cycles or dies.

`autodrop3` (Base) found it: its ponger never exits, and on four harts about
one run in ten ended with exactly 731 live entries (the commit before
`2201e4b`: 0 in 200 runs; from `2201e4b` on, 18-27 in 200). It had passed
the day's Base by chance. The check now asserts the documented bound, at
most a slab per receiving actor, instead of zero.

The fix is the park trigger: at a receive loop's boundary, cycle also when
the mailbox is empty and the region holds received roots, so the actor
parks holding nothing. The boundary test is inline on each target, so this
adds a mailbox load (hart -> current actor -> mailbox head) to A64, x86-64
and RISC-V, behind the existing clock test's cold path. It changes no
semantics beyond releasing earlier.

## 6b. Inline allocation fast path (decided, not started)

`fpr_alloc` (`runtime/runtime.c`, `alloc_in`) is not a bump allocator with
a slow path. In order it:

1. finds the pool through the hart's override slot (arena or region) or the
   current actor's pool;
2. takes a recycled block from the size bucket (an atomic exchange, since
   any hart may push frees there);
3. above the bucket ceiling, takes an exact-size block from the pool's
   free list of big blocks;
4. only then bumps the current slab, and on refill checks whether a pending
   call region should open (`region_trip`).

An inline bump that skipped steps 2-3 would leave recycled blocks unused
until some C-path allocation takes them, which changes the memory bounds
the regions work relies on. An inline step 2 would put an atomic exchange
and four dependent loads in every allocation site, about what the call
costs now.

Options, for a decision:

- **(a) Bump-only pools.** Arena and region pools (receive turns, loop and
  call regions) are reset wholesale, so their frees could stop feeding
  buckets, and their allocation becomes bump-only. The hart block caches
  the current pool's `hp`/`end` and the compiler bumps inline, calling C
  only on refill. Actor base pools keep buckets and the C path. This
  changes what a free in an arena does (nothing, until the reset), which
  is a memory-model change.
- **(b) Keep the C call, cut its cost.** Make `fpr_alloc` preserve more
  registers (a custom convention for the common bucket and bump hits), so
  values across an allocation need not be callee-saved. That is no change
  to memory behaviour, but it saves less.

Measure first: allocation-heavy benchmarks (strbuild, nbody, helpers) with
the call cost isolated (`xctrace` time in `alloc_in` and the save/restore
around the call sites).

**Decision (2026-10-27): option (a), only where it already holds.** The
compiler's regions (loop, call and receive-turn regions) are created
without buckets (`arena_close`: "a compiler region has none"), and a small
free into a bucketless pool is already dropped (`fpr_free`). Inside a
compiler region `alloc_in` is therefore already bump-only for small
sizes, so an inline bump there changes no memory behaviour. The actor's
base pool, `Sys.arena` arenas (which have buckets) and allocations above
the bucket ceiling (the big-free list) keep the C call.

Design:

- The hart block publishes a bump window: the current slab, its `hp` and
  `end`. It is valid only while the current pool is a bucketless region
  (and never in `FPR_COST` builds); otherwise `end` is 0, so the inline
  test always fails. A native ABI revision.
- Generated code, for a constructor of known size: `p = hp; n = p + total`;
  if `n > end` call `fpr_alloc` (which also handles region trips and slab
  refill); else store `hp = n`, add `total` to the region clock (cell 58,
  which `alloc_in` charges per allocation today), write the header (total
  and slab) and zero the rounding pad that `fpr_dcopy` reads.
- The runtime writes the window back (`slab->hp`, and `pool->allocated`
  from the bumped distance) before anything reads them: the C allocation
  path, region open/cycle/close, an override change and an actor switch,
  and republishes it after.

First step: count allocations by pool kind (compiler region, actor pool,
arena) in strbuild, nbody and helpers, to bound the win before building it.

## 7b. Splitting at loop boundaries (next)

Holes handle a value that is dead in a loop. The case still left is a
value live across a loop and used on both sides but not inside. Loop
weights make it the preferred spill, but it is then spilled everywhere,
including the uses outside the loop. Splitting its range at the loop's
entry and exits, with a store and reload placed there and resolved like
block-parameter copies, would keep it in a register outside the loop.
This needs move resolution on edges, which `Allocate` does not have yet;
it is the remaining part of the plan's step 7.

## 8. Tick amortization (designed, not started)

After step 6 a tick costs no registers, but it is still a load, subtract,
store and branch on the fuel cell every iteration, a loop-carried
dependency through memory. Design:

- At the IR level, give a loop with a tick a countdown block parameter `c`
  (initially K). Each iteration decrements it in a register; at zero it
  runs `OSafepointN K` (which already exists for SIMD strips) and resets
  it. Fuel accounting stays exact up to the uncharged remainder (< K) when
  the loop exits.
- K from the loop body's measured bound (`Cost.hs`): the largest K with
  K x body cost at most a fixed budget (for example 256 instructions), so
  the time between safepoint checks stays bounded and explicit.
- Self tail-call loops are formed in the allocator (`loopForm`), below
  the IR. They need either the same countdown inserted there through
  target hooks, or self tail calls turned into IR loops before lowering.
  The second is cleaner and lets loop motion see them too.

Measure first: a pure counting loop with the per-iteration tick removed
from the assembly by hand, to bound the win before building it. A first
attempt with a scratch compiler flag did not take effect, so the number is
not in yet.
