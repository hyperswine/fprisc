# The four benchmark regressions since 2026-10-01

Date: 2026-10-26. Follows [the step-0 baseline](2026-10-26-PERFORMANCE-BASELINE.md),
which found pingpong 2.1x, strbuild 1.7x, xpingpong 1.5x and vecread 1.4x
slower than `bench/baseline.json` (2026-10-01). Host: Apple M4. Profiles are
Instruments' Time Profiler (`xctrace`, with Xcode's developer directory),
1 ms samples. Two are fixed here; one needs a memory-model decision.

## strbuild: a byte-loop `strcat` (fixed)

The profile put the difference in `fpr_prim_fn_strcat` itself: 107 samples in
the slow build against 55 in a fast one, inside `cat`'s 20,000 appends (about
200 MB copied). `strcat` copied with two byte loops. At best that is about a
byte a cycle; the slow builds ran at half that, the signature of a
load/store aliasing stall when source and destination sit at an unlucky
distance. Where the destination landed depended on which call region's slab
the strings were in, so the time flipped with unrelated changes: a probe
that only printed four extra counters at the end of `main` ran at 124 ms
against the benchmark's 175, with identical region decisions, memory and page
faults. The step-0 "both regions on" attribution was this effect, not a cost
of regions.

`strcat` now copies with `memcpy` (the destination is a fresh allocation, so
nothing overlaps): **strbuild 174 -> 83 ms**, 1.27x faster than the 2026-10-01
baseline, and the same with either region switch (83 / 79 / 80 ms; the call
region's adoption check and close remain, about 4 ms). `strJoin` already used
`memcpy`; the one other byte-copy loop (`SStr.fromStr`) is bounded by the
short-string capacity.

## vecread: a loop region around a loop that never allocates (fixed)

`sumAt`/`sumAt1` read an Int vector and allocate nothing, but the loop-region
rule counted the pair-free read `$vec.at` as unknown code, which is assumed to
allocate, so the loop got a region it could only pay for (about 10%).
`ReceiveTurns.allocates` now knows `$vec.len` never allocates and that
`$vec.at`/`$vec.get` allocate only for a Vector of records or tuples
(`row_at` builds a row; Int, float and boxed elements come back as the word).
The vector's type comes from the loop's checked interface, through names
bound exactly once in the body; anything else keeps the conservative rule.
**vecread 220 -> 200 ms.** Loops that allocate keep their regions.

The rest of vecread's gap to 2026-10-01 (200 against 158 ms) is the per-element
C call and the generic column read (`$vec.at` -> `row_at` -> `get_cell` ->
`vl_slot`): the planned inline vector fast path (review section 1, item 3).

## pingpong and xpingpong: receive-turn trampolines (needs a decision)

Same-hart pingpong takes 360 ns a round trip (169 ns on 2026-10-01). Two causes:

- **Receive turns (about 37%).** `FPR_NO_RECEIVE_TURNS=1` takes pingpong from
  334 to 211 ms and xpingpong from 391 to 357 ms. Each turn runs the runtime
  trampoline (`g_receive_loop` -> `g_loop_in`): two generic applications, a
  fresh `(continue, next-turn closure)` pair and closure, a deep copy of the
  closure and its captured state into transfer storage (`dc_size`, `dc_dup`),
  then root release, arena reset and transfer retirement. That is paid per
  message even when the state is four Ints.
- **Stealing (about 20%).** On one hart pingpong takes 279 ms; with the default
  ten harts, 340-380 ms. Idle harts take the ponger, which turns a same-hart
  exchange into a cross-hart one that spins (`block_unless`, `hal_mtime`).

Loop regions already avoid the per-iteration cost: a direct self tail call,
an inline room check, and a cycle only when a slab has filled. Doing the same
for receive turns would release a turn's scratch and its messages at the next
slab boundary instead of every turn: memory stays bounded by a slab, but it
changes the stage-1 rule "a message dies with its turn" as written. That is a
memory-model decision, recorded in [the plan](2026-10-26-PERFORMANCE-PLAN.md),
not made here. xpingpong's remaining gap with turns off (357 against 255 ms)
is not yet attributed.

## Validation

The changes are `runtime/runtime.c` (`fpr_prim_fn_strcat`) and
`compiler/ReceiveTurns.hs` (`allocates`). Benchmarks above are fastest of
seven or nine runs. The full Base suite passes 137 jobs in 585 s on seven
workers, with the compile budget unchanged.
