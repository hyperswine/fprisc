# Regions, stage 2: boundaries at self tail calls, state that moves

Date: 2026-10-24. Kind: compiler and runtime change, with its checks. Stage 2
of [2026-10-23-COST-SIZED-REGIONS.md](2026-10-23-COST-SIZED-REGIONS.md), on
top of [stage 1](2026-10-24-REGIONS-STAGE1.md); baseline numbers in
[stage 0](2026-10-24-REGIONS-STAGE0.md).

## What a boundary is now

Stage 1 made every turn a boundary for the messages it received. Stage 2
places more turns, all through the one trampoline `compiler/ReceiveTurns.hs`
already lowers recognised receive loops to:

1. **A self tail call is a boundary** (the proposal's rule 2). A
   tail-recursive group that never receives gets the same turn regions
   when its iteration allocates and every live parameter is of bounded
   size. "Allocates" is the cost pass's word on every primitive the
   iteration calls (`Cost.primAllocates`: arithmetic, comparisons and
   projections do not; constructors with fields, closures and string
   primitives do; a call into code the pass does not know is assumed to).
   "Bounded" is a size that does not depend on the loop: scalars, handles,
   Vectors (moved, below), and tuples, records and non-recursive nominals of
   those. A `List`, a `String` or a recursive nominal (a `Tree`) in the state
   declines the loop: copying it every iteration would grow with the loop
   (the proposal's rule 4). A tight arithmetic loop allocates nothing and is
   left as the jump it was. The next state's own constructors do not count
   (they are what the field workers unbox when the loop stays a jump), nor
   does anything on an exit path.

   **A pure loop's region is `Dynamic`, one slab.** The first cut gave a pure
   loop a turn per iteration, and the ratchet said no: one boxed float per
   iteration is an allocation, so `nbody` took 3.5 times as long, `floatcmp`
   14 times, `vecread` 43 times, `helpers` 5.7 times (`tools/bench.py`, with
   against without turn regions). The committed form (`$turnLoop`,
   `g_loop_in` amortized) keeps the state in the region with the scratch and
   copies it out, then resets, only when the region has bumped a slab's worth
   (`FPR_MSG_SLAB_SZ`, the allocator's floor, not a chosen number) since its
   last reset. Garbage is bounded by one slab plus the state; the copy is
   paid once per slab of scratch. A receive loop never amortizes: its
   message dies at the turn's end, which needs the state copied out first.

   **And it is off by default.** Amortizing removed the copy and the reset
   but not the trampoline: every iteration still builds the next-turn
   closure and its packed state and goes through two indirect calls, and the
   ratchet still read `vecread` at 12 times, `floatcmp` at 5, `helpers` at
   2.4, `specialization` at 4 (`nbody` was back within 1.1). A boundary that
   a hot loop can afford has to be a check on the loop's own back edge,
   with the loop left as the jump the typed IR already makes of a self tail
   call (`FPR_TYPED_IR_SELF_LOOPS`): a compare of the region's bytes against
   its capacity, and a call out to copy the live arguments and reset only
   when it trips. That is codegen work this stage did not do. So
   `FPR_LOOP_REGIONS=1` places the pure boundaries (the cache tag carries
   it), `--cost` names the candidates it would place, and the default
   places none.

   `tools/bench.py --runs 5`, fastest run, this Mac, the same compiler
   (`workers` does not build in the ratchet on this branch or on main: its
   probe symbols are missing, unrelated):

   | benchmark | no turn regions at all (`FPR_NO_RECEIVE_TURNS=1`) | pure loops a turn each | pure loops amortized (one slab) | default: pure loops off |
   |---|---|---|---|---|
   | floatcmp | 40.2 ms | 578.0 | 217.0 | 40.1 |
   | helpers | 105.6 | 600.5 | 256.2 | 104.8 |
   | nbody | 232.1 | 813.1 | 259.0 | 229.4 |
   | specialization | 5.8 | 53.4 | 23.3 | 6.3 |
   | vecread | 163.0 | 6,922.0 | 2,022.6 | 161.5 |
   | sha | 120.4 | 120.7 | 122.8 | 121.3 |
   | strbuild | 122.4 | 119.3 | 120.6 | 120.8 |
   | byteloop | 88.4 | 88.8 | 88.7 | 88.4 |
   | fib | 57.9 | 56.9 | 56.8 | 60.5 |
   | pingpong (a receive turn since stage 1) | 238.3 | 358.0 | 329.3 | 349.2 |
   | xpingpong, 4 harts | 332.2 | 431.9 | 445.2 | 417.7 |

   The two message benchmarks pay the receive turn they have paid since the
   2026-10-19 arena page (352 ms there); the rest of the default column is the
   no-turns column within noise.
2. **A loop-invariant or function-typed parameter needs no type evidence.**
   Invariance is per slot: union-find over the group's calls, a slot joined
   to the caller's own parameter it passes, variable the moment any call
   passes anything else. An invariant parameter, a function-typed one, and a
   result that is an invariant parameter's own type handed back are copied as
   they are; a Vector among them, or anywhere in the state, is moved. This is
   what the proposal's `serve` example and the swarm keeper needed.
3. **An owned Vector crosses by handle.** Every piece of a Vector (header,
   directory, kinds, shape, columns; `runtime/vec.c`) is now allocated with
   `fpr_alloc_bulk`, the actor's base pool whatever region is open, so a
   turn's reset never touches it and its one owner frees it (it is linear).
   A compiler-placed turn (`$receiveLoop`, now `g_loop_in(..., movevec)`)
   copies its state as before except for a Vector whose header is in this
   actor's base pool and whose columns are all raw (`vec_movable_here`): that
   one crosses as a word. A message's Vector (in an ownerless slab) or a
   boxed column is still copied, as a wrong guess must be. `Sys.loop`,
   `Sys.loopWith` and `Sys.arena` keep their contracts and refusals; the
   memory plane gains `loop_turn` (plane memory ABI 4) so a loaded process's
   turns do the same.
4. **`--cost` says where the boundaries are.** Every turn placed is a note
   with its rule (`receive-turns:` or `turn-regions:`), and the pure groups
   declined are counted per unit; `FPR_RECEIVE_NOTES=1` lists each one with
   the parameter that declined it.

Not in this stage: pure-loop boundaries by default (above), and the
proposal's rule 3, a region around a *call* whose `alloc` is much larger
than its result. Its threshold is the open question
the proposal names; see "What stage 3 and the rest now need".

## Acceptance

| check | result |
|---|---|
| the swarm keeper (`examples/swarm.fpr`, `tests/base/swarmkeeper.fpr`, new in `check_base`): `receive-turns: keeper: automatic value-state turn regions`; 10,000 ticks of 2,000 motes | resident memory flat (under 4 MiB more after 10,000 ticks) on one and four harts; the swarm's Vectors cross every boundary by handle |
| `tests/dtree.fpr`, 512 rows x 128, ten iterations in one process under an 8 MiB heap, the pool runtime on this Mac (`check_tangnano20k_dtree.py --native --repeat 10`, `FPR_HEAP_MB=8`, `FPR_LOOP_REGIONS=1`) | 10 of 10 iterations match the Python reference, 8.5 ms an iteration after the first (15.6, 8.8, 8.6, 8.5, 8.5, 8.5, 8.5, 8.5, 8.6, 8.5 ms), the ten runs of one process; the baseline compiler on the same runtime and heap exhausts it in the first iteration ("want 262144 after 17 blocks / 6 MiB taken"); this compiler with the switch off completes three iterations, then exhausts it, the per-iteration garbage of `run` having nowhere to go |
| the same fixture on RV32 QEMU, the Tang Nano host, without `FPR_GC` | not met, and unchanged in kind: the first iteration runs the 8 MiB builtin heap out (`Builtin: out of memory` with 8,061,376 bytes live after 107,236 requests for 2,587,924 bytes; the baseline compiler: 8,070,784 live, 103,961 requests for 2,490,492 bytes). No region code runs there; see below |
| stage 1's checks (autodrop2, autodrop3, deadmail, receiveturns, turnroots) | PASS on the stage 2 compiler |
| `tests/check_receive_turns.py` | the `mutable` (Vector state) and `functional` (callback parameter) shapes, refused until now, are automatic; the rest unchanged; PASS (the fixture whose whole state is a Vector found the one path where a moved Vector reached the copier with no context, fixed) |
| `python3 tests/check_base.py -j 4` | PASS: 126 jobs in 492 s on 4 workers, exit 0 (this Mac). One earlier run caught the first form of the pure-loop rule making `pairLoop n (a, b)` a turn (`tests/check_workers.py`: 10,001 turns where the field workers leave zero allocations), which is why the next state's constructors no longer count |
| QOS sweep (`check-all.sh`, `FPRISC_ROOT` at this worktree) | 151 passed, 2 failed, 9 skipped of 162: one better than stage 1. The liveboard leg timed out on a websocket read under the sweep's load again and passes alone; the other is the preferences leg below |
| QOS preferences leg (stage 1's open item) | still red, unchanged: its holder is the frozen `epservice#e8bce05a` namespace loop, which runs under `A.tidy`, an explicit region; rule 2 widens only the loops the compiler places, and explicit regions stay in control by design. The 14-line repair in the QOS worktree stays unminted |

## The Tang Nano host

`machine/tangnano20k` builds `runtime/runtime.c` over `machine/builtin/heap.c`,
a coalescing allocator with explicit free, with actors, pools and arenas
unavailable (`machine/tangnano20k/unsupported.c`). A turn there has nothing
to reset: `g_loop`, `g_loop_with` and `g_arena` now run the loop or the call
plainly on that target (`#ifdef FPR_BUILTIN`), so a program the compiler
lowers to turns still runs and still produces the same values, and the
stage 1 accessor the link was missing there (`fpr_acb_rx`) has its stub.
The dtree acceptance on that host needs regions inside that allocator: a
region records the blocks allocated under it and frees them at its reset
after the state is copied out above it. That is allocator work the
proposal's table ("Builtin ... unchanged by this proposal") did not plan,
and the first iteration alone needs it (2.49 MB requested, 8.07 MB live on
the builtin heap, before any boundary between iterations could help). It is
left open with that scope; the pool runtime's result above is the same
program under the same heap bound.

## What changed

- `compiler/ReceiveTurns.hs`: pure tail-recursive groups, invariants,
  function-typed parameters, Vector state, bounded types, the handed-back
  result, note kinds. `compiler/Cost.hs` exports `primAllocates`.
  `compiler/Compile.hs` prints the notes under `--cost` and the count of
  declined groups. `codegenRev` 90 to 91.
- `runtime/vec.c` allocates bulk through `fpr_alloc_bulk` and
  `fpr_realloc_bulk` (`runtime/runtime.c`; `machine/builtin/heap.c` maps them
  to its allocator). `runtime/runtime.c`: `vec_movable_here`, the
  `movevec` copy mode in `dc_size`, `dc_dup` and `kp_dup`, `g_loop_in`,
  `g_loop_turn` on the memory plane (`FPR_PLANE_MEMORY_ABI` 4), the hart's
  `copy_movevec`, the builtin fallbacks. `runtime/fpr.h` accordingly.
- `tests/base/swarmkeeper.fpr` and its `check_base` case;
  `tests/check_receive_turns.py` moves two shapes from refused to automatic.

## Boundaries this placed in the tree

Under `--cost` on `examples/logbook.fpr` the new boundaries are the pure
loops `serveGo`, `readGo`, `logGo`, `irqReply`, `irqHandTo`, `closeWatcher`,
`acceptGo`, `acceptAll` and the module-compatibility walk; `serveOnGo` (a
reader and writer callback as parameters) becomes a receive turn by rule 2.
About 170 pure groups across the closure are declined, almost all list and
string helpers whose state is the list they walk, which is the right
answer. The explicit-region loops (`register`, `writing`, `session`,
`shard`, `reading`) stay under their `A.tidy`.

## What stage 3 and the rest now need

- **Rule 3, the cost-chosen call.** A region around a call whose `alloc` is
  much larger than its result needs two things this stage does not have: a
  result size (only declared `size` bounds exist; a result type that is
  bounded in the sense above is the obvious proxy) and a threshold. The
  proposal says to settle the threshold by measurement; a criterion with no
  constant in it is available: an `alloc` the cost pass derives as
  input-proportional (it mentions a parameter or a length) against a
  bounded result, as opposed to a constant `alloc`, which a region would
  only slow down. The dtree fixture is the measurement to settle it with,
  once the builtin heap can reset a region.
- **The Tang Nano allocator**, above.
- **`serve` still copies its state each turn**; the stage 3 target.
- **QOS's `A.tidy` loops** are explicit regions and stay as they are; the
  preferences leg's retention depends on their reset cadence (stage 1's open
  item).
