# Steps 6-8: what landed and what remains

Date: 2026-10-27. Kind: status and plan for the rest of steps 6-8 of
[the performance plan](2026-10-26-PERFORMANCE-PLAN.md).

## Landed

- Step 7, first part: [live-range holes and loop-weighted spills](2026-10-27-REGISTER-PRESSURE.md),
  with a register-pressure model gating loop motion.
- Step 6, first part: [clobber-free ticks and noreturn kernel traps](2026-10-27-CLOBBER-FREE-TICKS.md).

## 1b. Parked receive-loop retention (fixed)

Receive-loop boundaries now cycle before a blocking receive when they own
previously received roots and no matching work is ready. Live next-state
values are copied through the existing region protocol; a receive in the
middle of an activation still retains values needed by its continuation.
Selective/Result readiness is checked without evaluating source operands.
`autodrop3` again requires exactly zero live entries on one and four harts.

The [implementation and validation note](2026-10-27-PARKED-RECEIVE-AND-ANALYSIS.md)
records the deterministic park regression, emission coverage and noisy
paired timing samples. It also records the shared post-linked cost
analysis: the QOS shell warm sample uses 15.3% less compiler CPU and 18.5%
less allocation. Quiet-machine runtime measurements and the remaining
allocation/register-allocation work below are still outstanding.

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
