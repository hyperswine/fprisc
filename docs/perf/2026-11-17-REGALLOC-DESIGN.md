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

**Recommendation: (a).** Stage 1 does not change frame sizes, so
`Stack.selectedFrame` and every stack bound are unchanged. The instruction bounds
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
