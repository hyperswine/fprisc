# Register allocation, audit item C9: design note

Status: stage 1 implemented on `ari/regalloc` (hosted x86-64 only, default on,
`FPR_NO_X64_RA=1` restores the old path). Stages 2+ need decisions listed below.

## Where the cost is

fprisc already has a linear-scan allocator (`Codegen.Allocate`, M3) with block
segments (holes) and loop-weighted spill cost. It does not split intervals, and a
value live across a clobbering call must take a callee-saved register (x64: rbx,
r12-r15) or a slot. Classifying the instructions of the 830cb768 benchmark binaries
(callgrind, per instruction) gives the frame/allocation overhead as a share of all
instructions executed:

| bench | frame setup/teardown | callee saves/restores | spill slots |
|---|---|---|---|
| binarytrees | 13.7% | 9.2% | - |
| treemap_mutmap | 7.5% | 5.3% | - |
| records | 5.2% | 3.4% (+1.7% arg->callee copies) | - |
| nbody | - | - | 5.4% |
| fannkuchredux | - | - | 7.0% (loop) |
| wordfreq | - | - | 5.1% (walk) |

Three causes account for most of the frame and callee-save share:

1. **Parameters cross the entry stack check.** `OStackCheck`/`CheckAndTick` is a
   real call to `fpr_stack_grow`, so every parameter is live across a clobbering
   call and is forced into a callee-saved register (records `cmp`, treemap `byKey`).
   The opt-in `FPR_TYPED_IR_ENTRY_ARGS` parks them in frame slots instead, which
   grows frames (32 -> 48 bytes) and was a net loss on csv/wordfreq/records (+3%).
2. **Saves sit in the prologue on every path**, including leaf paths that never
   call (binarytrees `check`). The shrink-wrapping pass (`Common.shrinkWrap`)
   exists but is wired only on A64.
3. **Slow paths that are plain calls.** `==`/`!=` on boxed values (`OEqVal`) calls
   the runtime as a clobbering call even though its fast path is inline.

## Stage 1 (implemented, no decision needed)

All of it keeps the calling convention, the tagged signatures of exported, FFI and
QOS entries, and the frame layout.

- **Preserving entry checks.** On x86-64 the entry stack check calls a generated
  `fpr_stack_grow_local` wrapper that preserves every allocatable register (like
  the existing `fpr_fuel_save_local` and `fpr_alloc_save_local`). The entry pseudo
  becomes a preserving call (`Protocol.keepingEntry`, checked by
  `checkProtocols` and the forms checker), so parameters stay in their arrival
  registers and no parking slots are needed.
- **Live-set saves for preserving runtime calls.** Keeping calls that used a
  shared wrapper saving 8 GPRs + 12 xmm now save only the caller-saved registers
  live across the call (`Allocate.liveAcross`, annotation `KeepsLive`), inline.
  The `OEqVal` slow path uses this, so a boxed comparison no longer clobbers.
- **x64-aware entry split.** The entry split treats safepoints, stack checks and
  `OEqVal` as non-clobbering on x64, so it does not introduce copies for them.
- **Shrink-wrapped callee saves** (`Common.shrinkWrap`, now on x86-64): saves are
  placed at the dominating block that needs them; paths that never reach a save
  skip the restores.
- **Short epilogue** `leaq -16(%rbp),%rsp; popq %rbp` (frame pointer kept: rbp is
  the CFA that `fpr_stack_grow` relies on when it switches segments).

Off switch: `FPR_NO_X64_RA=1` (adds `-nox64ra` to the native cache key); the
config-differential check runs the suite both ways.

## Open decisions and recommendations

### Calling convention

Options: (a) keep the platform convention everywhere; (b) a private FP-RISC
convention for internal calls only (more callee-saved registers, args in
registers that survive the entry check) with exported/FFI/QOS entries keeping the
tagged signatures via thunks; (c) per-function custom conventions (IPRA).

**Recommendation: (a) for stage 1 (done), revisit (b) only after stage 2.** Stage 1
removes most of the measurable convention-related cost (arrival copies and the
forced callee saves) without touching any ABI. (b) changes every internal call
site, the runtime preserving wrappers and the context-switch save set, and
(c) makes separate compilation and the cache key depend on callee bodies.

### WCET: per-path frame bounds

Options: (a) keep one static frame size per function (the bound is the frame size,
shrink-wrapping only moves saves inside it); (b) per-path frame sizes (allocate
the save area only on paths that save), with the bound taken as the maximum over
paths.

**Recommendation: (a).** Stage 1 keeps one static frame per function, computed
by `Stack.selectedFrame` as before. In the measured programs frames only shrink, because parameters no longer
need callee-saved registers or parking slots: across records, treemap_mutmap,
binarytrees, nbody, wordfreq and csv (125 functions), 46 frames are smaller and
none is larger (the largest frame in each program is unchanged or smaller). The instruction bounds
(`native-insns-v1` segmax/exittail/ccalls and the tick weights) are computed from
the emitted instruction text, so they remain sound and pick up the shorter paths
automatically. The WCET reference (cached-SDRAM simple-risc on the builtin RV32
target) is untouched: stage 1 is limited to the DirectX64 backend and the RV
bare-metal and builtin output is byte-identical apart from the codegen revision
string. (b) would save stack bytes on deep recursion but makes the bound a path
maximum that the checker has to recompute; not worth it until a target is
stack-limited.

### Compile time

Shrink-wrapping is a dominator fixpoint per function and the live-set pass runs
only in functions that contain a keeping call. **Recommendation:** keep both
unconditional, but skip shrink-wrapping for functions over the existing `large`
threshold (as done). Measured against the compile budget in the PR.

## Stage 2 candidates (need Jack's choice)

1. **Loop live-range splitting** for the slot-heavy loops (nbody, fannkuch, the
   wordfreq walk): split intervals at loop boundaries so the loop body keeps
   values in registers and spills move to the loop edge. No ABI or WCET-model
   change; costs compile time (interval splitting + resolution moves). This is the
   recommended next step.
2. **Shallow-stack policy as the default**: skip the entry stack check in small
   leaves whose frame fits the guaranteed red zone. Saves the check, but it is a
   stack-soundness policy decision (the bound then relies on the caller's reserve).
3. **Frameless x64 entries / dropping rbp**: needs `fpr_stack_grow` to find the
   segment without the frame pointer. Larger runtime change.
4. **Private calling convention** (decision above, option b).

Not register allocation, but seen in the same profiles: the boxed-equality fast
path sequence and separately inlined fuel ticks.

## Stage 1 results (8841b1c9 against main 22ed0c71, Linux x86-64)

Callgrind instructions, median of 3 at the cg sizes; 16/16 benchmark outputs match.
Tests: unit 45/45; `tests/run.sol` push tier 23 checks, 0 unexpected (known failures only);
nightly config differential 43 programs x 11 configurations (with `no_x64_ra`), only the
known loopcalls/vecinline `no_reuse` build failures.
Base binaries re-run from a path of the same length as the branch's gave identical
counts, so the path has no effect on the comparison.

| bench | main 22ed0c71 | ari/regalloc 8841b1c9 | change |
|---|---:|---:|---:|
| records | 2,256,916,816 | 2,149,379,587 | -4.76% |
| treemap_mutmap | 1,540,995,472 | 1,412,034,538 | -8.37% |
| csv | 4,228,304,720 | 4,221,244,033 | -0.17% |
| wordfreq | 4,490,577,348 | 4,520,330,667 | +0.66% |
| binarytrees | 1,967,400,807 | 1,804,028,253 | -8.30% |
| nbody | 1,552,447,966 | 1,553,929,473 | +0.10% |
| sim | 2,886,364,668 | 2,894,660,029 | +0.29% |
| wordfreq_mutmap | 2,167,910,515 | 2,136,088,844 | -1.47% |
| format | 2,785,901,863 | 2,776,926,998 | -0.32% |
| treemap | 1,810,518,204 | 1,745,398,351 | -3.60% |
| fannkuchredux | 820,875,578 | 819,081,149 | -0.22% |
| spectralnorm | 833,509,652 | 841,942,941 | +1.01% |
| mandelbrot | 821,114,085 | 800,659,199 | -2.49% |
| fasta | 400,737,409 | 387,101,438 | -3.40% |
| knucleotide | 2,413,212,646 | 2,354,618,933 | -2.43% |
| revcomp | 257,388,554 | 257,540,999 | +0.06% |
| total | 31,234,176,303 | 30,674,965,432 | -1.79% |

The spectralnorm regression is one extra register-to-register copy per inner
iteration of `mulRows` (a different assignment, no added spill, save or reload);
wordfreq and sim are similar small assignment differences. Loop splitting/coalescing
(stage 2, item 1) is where these get fixed.

Compile budget (GHC allocation, `tests/sol-checks/compile-budget.sol`; this
environment has no recorded baseline, so main is measured as the reference):
hello 1,384,508,640 -> 1,397,108,144 bytes (+0.9%), std-live 30,934,788,208 ->
31,793,656,992 (+2.8%), pos1 66,926,937,200 -> 68,154,825,776 (+1.8%); the gate is +10%.

## Stage 2: loop spill code on hosted x86-64 (`FPR_NO_X64_SPLIT=1` is off)

Jack's choice for stage 2 was loop live-range splitting, keeping the platform
calling convention. Profiling the four targets showed the loop spill code came
from four specific causes. Each one is fixed where it arises, not by a general
interval splitter. All four are under `cfgFrames` (hosted x86-64 with stage 1
on), behind `tuneSplit`; A64, RV and the builtin profile are unchanged.

1. **Spill moves** (`acSpillMoves`). Before, a register move with one spilled
   side went through the r10/r11 scratch: a load then a copy, or a copy then a
   store. Now it is the frame access itself: one store or one load, or nothing
   when both sides share a slot. A reload directly after a store of the same
   register and slot is dropped (`forwardStores`, adjacent items only). This
   was the hop at the wordfreq walk's parameters.
2. **Cold-call splitting** (`acColdCall`, x86-64: `keepingCall`).
   - **The problem.** A live-set slow path is a `PreservingRuntime` call: the
     vector get/set fallbacks, the arithmetic overflow paths, and boxed
     equality. Each one reserved its fixed argument registers (rdi/rsi/rdx)
     for every value crossing it. In fannkuch's inner loop, with all five
     callee-saved registers taken, `i+1` and `j-1` were spilled for the sake
     of calls that almost never run.
   - **The change.** A value crossing such a call may now take one of those
     argument registers. It is stored to a frame slot before the call's
     argument staging and reloaded after. Those frame slots are shared by all
     cold calls in the function, as many per slot kind as the busiest call
     needs.
   - **The cost stays on the cold path.** The scan takes those registers
     last (the `soft` set), so the store and reload land only on the slow
     path, and only when the registers are needed.
3. **Move hints.**
   - **The problem.** The scan only hinted fixed operands, so a loop's next
     value got whatever register came first and was copied into the loop
     variable on every back edge. That was the extra copy in spectralnorm's
     `mulRows`.
   - **The change.** A value defined by a move from an already-placed value,
     or moved into one, now prefers that value's register. It never prefers
     a cold call's argument register it crosses. Holes are at block
     granularity (Codegen.Liveness), so this pays when the next value is
     computed in an earlier block than the copy, which is the normal shape
     of a loop body.
4. **The lean tick** (`Protocol.keepingEntryWith`).
   - A mid-function fuel tick (`EntryTick`/`TickN`) reads the hart into r10,
     subtracts, and on the slow path calls `fpr_fuel_save_local`, which
     pushes and pops rax..r11. It never writes rax.
   - Its protocol still claimed rax as an implicit definition, which kept rax
     away from every value crossing a loop's tick.
   - Under the split the kept tick no longer claims rax, and
     `checkProtocols` accepts exactly that variant for x86-64 ticks.
   - The stack check still claims rax, because `fpr_stack_grow` returns
     through it.

`checkAllocation` (the physical-liveness oracle) runs on every function as
before. The cold-call save and restore are ordinary SpillStore/Reload items,
so the stage 1 live-set pushes (`keepLive`) see the argument register as
overwritten by the staging and do not push it.
Unit tests: `tests/AllocIR.hs` (cold-call saves in an argument register, a
loop move hint, store forwarding, spill moves under the symbolic simulator).
Config differential: `no_x64_split`.
