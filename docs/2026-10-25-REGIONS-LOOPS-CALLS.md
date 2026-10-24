# Regions at loop back edges and around costly calls, and none for a collector

Date: 2026-10-25. Kind: compiler, codegen and runtime change, with its
measurements. Follows [stage 2](2026-10-24-REGIONS-STAGE2.md) of
[the cost-sized regions plan](2026-10-23-COST-SIZED-REGIONS.md), and settles
the three things stage 2 left open: pure-loop regions on by default (they cost
hot loops too much), the proposal's rule 3 (regions around costly calls), and
the Tang Nano host, where the classifier needed a collector. The conservative
collector of [2026-10-20-TANGNANO20K-GC.md](2026-10-20-TANGNANO20K-GC.md) is
removed: the RV32 Base heap now reclaims by regions only.

## Loop regions: a test at the boundary, not a trampoline

Stage 2 placed a pure loop's region through the receive-turn trampoline: a
closure and its packed state per iteration, two indirect calls, a copy and a
reset. Amortising the copy to once per slab still left vecread 12 times as
slow. The form now:

- The loop stays a loop: every member of the recursive group gets an inner
  version with two more parameters, the pool mark and the activation's
  sequence number, and its tail calls stay direct tail calls, which the typed
  IR makes jumps (`FPR_TYPED_IR_SELF_LOOPS`).
- The test sits at the entry of a **boundary** member: those called from
  outside the group, plus as few more as break every remaining cycle of the
  group's call graph. The other members stay small, so the inliner still
  merges a mutual pair (vecread's `sumAt`/`sumAt1`) into one loop; the
  inliner's size measure does not count the two pass-through parameters.
- The test is one typed IR op, `ORegionRoom mark`: load the hart's allocation
  clock (`region_bytes`, hart cell 58, directly after `stk_lo`/`stk_span`),
  subtract the mark, shift left by three (the mask to the tagged Int range)
  and compare unsigned against 64 KiB. On hosted A64 that is

  ```
  ldr x10, [x28, #472]
  sub x9, x10, x23, asr #1     ; the mark is a tagged Int
  lsl x9, x9, #3
  cmp x9, #524288
  cset x9, lo
  cbz x9, Lcycle               ; not taken on the hot path
  ```

  and the same shape on x64 and RV32/RV64. The hot body is the fall-through:
  A64 and x64 now omit the jump when a conditional branch's target is the
  next block, which also took fib from 56 to 49 ms.
- Only when 64 KiB has been allocated since the mark does the cold path run:
  `$loop.cycle.f` opens the region (the first time: the state was built in
  the caller's pool, which outlives the loop, so nothing is copied) or copies
  the changing arguments out and resets it, and reads the mark again. The
  loop's entry takes a sequence number and a mark; `$loopLeave` closes the
  region, if one opened, copying the result into the caller's pool.
- Invariant arguments are passed as they are and never copied: they were
  built before the loop, outside every region it opens. Variable arguments
  must be of bounded size (stage 2's rule); a Vector in them moves by handle.
- The allocation clock is per hart (a migrated actor reads another hart's
  clock, which can only make a reset early, never put one off for ever), and
  counts bump allocations, not bulk Vector storage.

`FPR_NO_LOOP_REGIONS=1` turns the placement off; it is in the unit cache tag
(the old `FPR_LOOP_REGIONS` was not, which is how a stale prelude built with
the trampoline survived a rebuild on the way here).

## Call regions (rule 3), with no threshold to tune

A saturated call to a function outside the caller's recursive group, whose
allocation grows with its input or cannot be named, and whose result is a
copyable value, gets a **pending** region: `$callPend` before it, `$callLeave`
after. Nothing happens unless the call allocates a slab in the pool it started
in; then the allocator's slab-refill path opens the region on the spot, later
allocations go to its arena, and `$callLeave` copies the result out and frees
the rest. Lazy opening is what removes the threshold the proposal left open:
a call that allocates little never pays more than the two calls, and one
that allocates a lot pays one copy of its result.

- "Grows" is the cost pass's word: the allocation mentions a parameter, or is
  opaque through unverified recursion or an unknown argument. An opaque
  primitive is a constant, and unmeasured recursion whose bodies allocate
  nothing per call now allocates nothing (`nth`, `lenL`: the cost report's
  allocation equations lose those ω, which `tests/check_cost.py` now expects).
- Calls into the caller's own recursive group are never wrapped, so no copy
  compounds with recursion (the proposal's rule 4); the copy costs at most
  the result once per distinct wrapped function on the stack.
- Calls into other units are judged by their callee's own equations: the cost
  equations are computed once over the whole program.
- The arguments are evaluated inside the pending region, unbound, so the field
  workers still see a literal constructor argument (the `pairLoop` check of
  `tests/check_workers.py` caught the bound form making an allocation).
- The `--cost` report sees the program without either kind of region: a
  region changes no work and no allocation.

`FPR_NO_CALL_REGIONS=1` turns the placement off.

What a call allocates before its region opens stays in the pool it started in,
up to the rest of that pool's current slab. Inside a loop region that is
garbage the next reset takes; in a loop that is no region (one that manages
its own with `Sys.arena`, say) it accumulates as it did before call regions,
at about half the rate in the probe below.

### Closing by adoption when the result is most of it

A call that builds its result and little else (`pieces` in
`tests/bench/strbuild.fpr`, a 1,000,000-element list that is its whole
allocation) gained nothing from its region and paid a copy of the result:
strbuild ran 15% slower with call regions (139 against 121 ms). A
compiler-placed region now closes by **adoption** when its result is at least
as large as the garbage it would free: copying would cost as much as the
memory it reclaims. The test is a walk of the result that mirrors the copy
(`kp_reaches`: what `kp_dup` would allocate, a moved Vector nothing) and
stops as soon as it has counted half of what the region bumped, so it never
walks further than the copy it may replace. Adopting hands the region's slabs
to the pool it closes into, behind that pool's bump slab and owned by it, and
adds their bytes to its gauge (a pending region outside counts them as its
call's). The garbage kept is at most the result's size, and the enclosing
pool's to reclaim. Not adopted: a fixed-heap pool (it keeps its cap), and a
loop region that has cycled (its state lives in transfer slabs the result may
point into). An explicit `Sys.arena` or `Sys.loop` always copies, as its
programmer asked. On the builtin heap the same rule moves the region's live
blocks into the enclosing region's list (untracked when none is open) and
frees its freed ones. `Arc.adoptions` (tests/arc_churn/arcprobe.c) counts
them; strbuild is back to 124 ms.

### A region opening under a closing scope

A pending call region can open while a `Sys.arena`, `Sys.loop` or
`Sys.loopWith` scope above it is closing: the scope's result is copied into
the call's pool, and that copy is what fills the slab. The new region's scope
then sits at the chain's head, above the closing one, and the closing scope
used to leave the chain by overwriting the head, which dropped the new region;
its `$callLeave` then found another region open and panicked ("call region: a
nested region is still open"). `tests/check_pos_reload.py` found it. Every
scope now leaves the chain by unlinking itself wherever it is
(`scope_unlink`); `tests/base/regionnest.fpr` (the Base case `regionnest`)
builds the shape directly: forty 20,000-cell arena results copied out under a
pending call region, on 1 and 4 harts. It panics with the old exit and passes
with the new one.

### The pend stack outlives a pool reset

Each actor keeps its pending call regions on a stack in its acb: eight entries
inline, then doubling. The first sweep of QOS with call regions failed 23 legs,
most with "call region: a nested region is still open" and some with
corrupted values ("strlen: not a string", a pattern that cannot fail
failing). The grown stack had been allocated in the actor's own pool, and QOS's
services run `AC.tidy`, whose `Sys.poolReset` frees that pool in place: the
stack's memory went home under it, later cells reused it, and later pends were
written into live data. It grows into a buddy block now, as the received-root
list does, released when the actor ends (`fpr_pends_reclaim`). A pend whose
pool was reset since also counts its slab from the reset instead of underflowing
into an immediate open. `tests/base/pendreset.fpr` (the Base case `pendreset`)
nests ten call regions, resets the pool, builds a list over the freed memory and
nests again: the old stack segfaults it, the new one leaves the list whole.

## The Tang Nano heap: regions, no collector

`machine/builtin/heap.c` gains regions without a byte per allocation: a region
is a list of the blocks it allocated, threaded through the block header's
`pending` link (the ARC release worklist uses it, and ARC builds open no
regions). A block is untracked (no region open, or bulk Vector storage),
tracked, or tracked-and-freed (its space waits for the reset; the live bit is
gone, so a second free is refused). A reset frees only the region's blocks; a
close frees them after the result is copied into the enclosing region. The
compiler's region primitives and `Sys.loop`/`Sys.arena` drive these on the
builtin target (`runtime/runtime.c`, `FPR_BUILTIN`). The board host names
the hart's clock word for the heap once (`fpr_builtin_heap_clock`), so the
inline back-edge test reads the same counter there.

A call region on this heap opens after its call has allocated **4 KiB**, not a
slab: on the host an open costs a slab, here one small block and the copy of
the result. What a call allocates before it trips stays in its caller until
the caller's region resets, and nested calls each leave that much: at a slab,
the classifier's split search left up to 64 KiB per entropy call, about 30
calls deep, and one iteration filled the 8 MiB heap. At 4 KiB the open costs
under 3% of what the call allocated.

Removed with the collector: `machine/tangnano20k/gc_registers.S` and
`gc_roots.c`, the `FPR_BUILTIN_GC` code in the heap, `tests/check_tangnano20k_gc.py`,
`tests/tangnano20k_gc_roots.c`, `tests/tangnano20k_gc_registers.S`,
`tests/builtin_gc.c`, `tests/typed_ir/builtin_gc_oracle.c`, and
`tools/bench-builtin-typed.py` (which also compared against the legacy
backend, deleted at `13ff336`, and so could not run). `FPR_GC=1` and
`FPR_GC_STRESS` are refused by name by `machine/tangnano20k/build.sh`; the
`fprisc-48` preset no longer sets them. `tests/check_typed_ir_builtin.py`
keeps its emission contract (typed, no fuel, no stack growth, honest loop
reports) and no longer runs the collector's root oracle. The heap report's
`collections=` field is now `regions=`, and `reclaimed=` counts bytes freed by
region resets and closes.

## Acceptance

| check | result |
|---|---|
| `tests/dtree.fpr` 512 x 128 rows, 16 bins, depth 6, ten iterations in one process, RV32 QEMU (the Tang Nano host), **no collector** (`check_tangnano20k_dtree.py --qemu --repeat 10`) | 10 of 10 match the Python reference (55 nodes, 481/512 and 116/128 with their digests); heap peak 2,532,832 bytes of 8 MiB, 25,321 regions, 183,472,640 bytes reclaimed; 3.31 to 3.51 s an iteration in QEMU (`docs/evidence/2026-10-25-regions-loops-calls/dtree-rv32-qemu-x10.json`). Before regions: out of memory in the first iteration |
| the same fixture on the host pool runtime under `FPR_HEAP_MB=8` | 10 of 10 (stage 2 needed `FPR_LOOP_REGIONS=1`; now the default) |
| the swarm keeper, 10,000 ticks (`tests/base/swarmkeeper.fpr`) | flat, as in stage 2 |
| a 2,000,000-iteration loop allocating a string an iteration (the page's probe) | memory grows 128 KiB, not 500 MB; its region opened once and reset 7,811 times |
| the benchmark ratchet, regions on against both switches off, fresh caches, fastest of 7 | all twelve within 3.3% (on / off, ms): byteloop 87.9 / 88.7, fib 49.0 / 49.7, floatcmp 41.8 / 40.6, helpers 105.6 / 105.4, mixed_locals 4.1 / 4.1, nbody 229.9 / 232.0, pingpong 323.1 / 320.8, sha 126.8 / 126.9, specialization 6.2 / 6.0, strbuild 124.2 / 123.8 (139 before adoption), vecread 162.4 / 161.8, xpingpong 389.0 / 392.3. `workers` does not build under `tools/bench.py` in either mode, as on main: the tool passes no `--with tests/bench/workers_clock.c` |
| `tests/base/regionnest.fpr` on 1 and 4 harts: arena copy-outs open pending call regions (80 opens in 40 rounds), a 300,000-element builder under a pending region, then a 1,000,000-iteration string loop | correct results (the builder's sum whole, its region adopted), the loop's memory bounded; with the old scope exit it panics |
| `tests/check_pos_reload.py` | PASS (it panicked before `scope_unlink`) |
| `tests/base/pendreset.fpr` on 1 and 4 harts | correct; exit 139 (segfault) with the pend stack in the pool |
| an outer loop that is no region (`rounds` above, which uses `Sys.arena`), 40 rounds | grows 20 MiB with call regions, 37 MiB without: the copy made before each call region opens stays behind |
| `tests/check_reuse.py`: the 10,000-iteration loop allocating 960,000 bytes, its cost ledger | 20,015 requests with loop regions (one scope record and 13 per-slab state copies, 784 bytes), 20,002 with call regions only, 20,000 with neither; the check's reuse ratchet (20,000 / 10,000) is now measured on a build with both switches off, its values on the default build; `tests/check_consuming_reuse.py` the same |
| Base case `vecpeek`, its baseline without the pair-free rewrite | 82,960 bytes for 2,000 reads with loop regions (a reset in the second loop reclaims pairs), 96,096 without; the baseline is now built with both switches off, as it counts the pairs |
| `tests/check_typed_ir_kernels.py` | PASS; the oracle link now leaves out the fixture filler's `$loop.in.fill` and `$loop.cycle.fill` with `fill` itself |
| `tests/check_receive_turns.py`, `check_loop_state.py`, `check_workers.py`, `check_cost.py`, `check_self_loops.py` | PASS |
| `tests/check_typed_ir_builtin.py --require-execution`, `check_builtin_heap_index.py`, `check_tangnano20k_rv32_base.py`, `check_tangnano20k_args.py` | PASS |
| `python3 tests/check_base.py -j 4` | PASS, 128 jobs in 512 s (after the four test fixes above, with `regionnest` and `pendreset`) |
| QOS sweep | 150 passed, 3 failed, 9 skipped of 162 legs (stage 2: 151 / 2 / 9), after the pend-stack fix (the sweep before it: 130 / 23 / 9). The three: (1) the native instruction ratchet, `runtime call sites 79 > ceiling 67`: the frozen module `84826bc9`'s `viaNamespace` wraps its six `EP.readOnce`/`EP.writeOnce` calls (one runs per call) in call regions, two runtime calls each; a decision, not a defect (see below). (2) Graphics.qa (`tools/gfxapps-check.py`): stalls after the first injected key, waiting for Terra's next frame; it fails the same with both region switches off, and the Mac's screen had been locked for five hours, which throttles real-GL frames: not verified, to rerun unlocked. (3) preferences, below |
| QOS preferences leg (stage 1's open item) | unchanged from stage 1: `preferences: preference endpoint retention`; the frozen `epservice#e8bce05a`'s tidy loops hold their roots until a reset (stage 1's page). The 14-line repair stays uncommitted in the QOS worktree |

## A decision for QOS: the ratchet's call-site ceiling

QOS's `check-all.sh` passes `--runtime-call-sites-ceiling 67` to
`tools/native-insns-ratchet.py`, a static count of C calls per function. Call
regions add two per wrapped call, so `viaNamespace` went from 67 to 79 (and
`main` from 47 to 73, under the ceiling). The calls it wraps are RPCs, whose
replies are exactly the temporaries a region should take. The options:

1. Raise QOS's ceiling to 79: a QOS-side edit, like the epservice repair.
2. Inline `$callPend`/`$callLeave` in the typed IR, as the back-edge test is:
   a pend is three stores and an increment into the actor's stack, a leave a
   decrement and a test, with C only when a region opened. That removes the
   growth and the cost everywhere, but needs the current actor's pend stack and
   pool reachable from hart cells, kept current at every actor switch.
3. Leave the ceiling and turn call regions off for that program
   (`FPR_NO_CALL_REGIONS=1`): it gives up what they reclaim in QOS's services.

## Not verified

- The physical Tang Nano board was not rerun: the RV32 result above is QEMU.
  The collector-era board runs and the rejected 72/54 MHz image are in the
  2026-10-20 page.
- The x64 and RV forms of `ORegionRoom` are covered by the suites' emission
  checks and the RV32 QEMU run; the x64 form ran only under the x64 checks of
  the Base suite on this Mac (Rosetta).

## What changed, by file

- `compiler/ReceiveTurns.hs`: pure loops as entry-tested inner functions with
  a cycle function, boundary members by feedback set, call regions over the
  whole program's equations. `compiler/Cost.hs`: `allocGrows`, allocation-free
  unmeasured recursion. `compiler/Inline.hs`: region parameters do not count
  toward the size limit. `compiler/Compile.hs`: the switches, the cache tag,
  the externs, the region-free cost report, the shared equations.
- `compiler/Codegen/IR.hs`, `Lower.hs`, `Eval.hs`, `Verify.hs`, `Dump.hs`,
  `Target/A64.hs`, `Target/X64.hs`, `Target/RV.hs`: `OHartCell` and
  `ORegionRoom`; A64 reads spill cells straight off x28; A64 and x64 fall
  through to the next block. Selection revisions A64 27, x64 26, RV 26;
  `codegenRev` 105.
- `runtime/fpr.h`, `runtime/runtime.c`, `runtime/actors.c`: the hart clock at
  cell 58, the pending stack in the acb, lazy loop and call regions, the
  allocator's trip, the release of a copied Vector, `scope_unlink`, the pend
  stack's buddy block, adoption
  (`kp_reaches`, `region_adopt`; `fpr_builtin_region_adopt` in the heap). `machine/builtin/heap.c`,
  `builtin.h`, `machine/tangnano20k/*`: heap regions, the collector removed.
  `FPR_NATIVE_ABI` 8 to 9 (hosted A64) and 7 to 8 (others): the hart and acb
  layouts changed, so QOS kernels and modules rebuild together.

## What comes next

Stage 3, generational copy-out and `Dynamic` policies: `serve` still copies
its whole state every request, and a large model's frame copy is still
proportional to the model (stage 0's 160 and 320 bytes per element).
A loop that manages its own regions (`Sys.arena` inside it) is declined as a
loop region, so the leftovers of the call regions under it accumulate; placing
a loop region around such a loop, nesting its stack scopes, is the open item
this page leaves.
