# Register pressure: allocator holes, loop weights and a pressure model

Date: 2026-10-27. Follow-up to item 4 of [the follow-ups](2026-10-27-FOLLOWUPS.md),
where loop-invariant motion was measured 11% slower and left opt-in, and the
first part of step 7 of [the performance plan](2026-10-26-PERFORMANCE-PLAN.md).

## Why motion was slower

The benchmark's fold kernel (`bench/2026-10-27-loop-motion.json`) was not
slowed by the moved code. Motion freed one of the nine callee-saved
registers (x19..x27), and the allocator gave it to the wrong value:

- **No holes.** Each value had one interval from its first to its last
  occurrence in stream order. `p` and the initial accumulator are used in
  the kernel's fallback block, which is placed after the loop, so their
  intervals covered the whole loop and held two callee-saved registers there
  although neither is live in it.
- **No loop weights.** When no register was free, the allocator spilled the
  value with the fewest static accesses. The vector's column base (one use,
  in the loop) and the accumulator (a few uses, all in the loop) cost the
  same, so the freed register went to the column base and the accumulator
  was spilled and reloaded twice per iteration.
- Every value live in the loop had to be callee-saved because the fuel tick
  and the overflow slow paths are calls. That is step 6.

## The allocator (`Codegen.Allocate`, `Codegen.Liveness`)

- **Segments.** `Interval` now carries `ivSegments`: the interval with its
  holes at block granularity (per block, from entry or first occurrence to
  exit or last occurrence; pieces of consecutive blocks merge). Two values
  may share a register unless their segments overlap. They may touch at an
  instruction where one dies by a use and the other is born by a non-early,
  untied definition (the old rule for interval ends). A hole inside one
  block is not split. The cost stays that of the block-level sets.
- **Loop-weighted spill cost.** A spill's cost is its definitions and uses,
  each weighted 8 per loop level (capped at 8^4). Loop depths come from the
  stream's natural loops (`Liveness.loopDepths`). Eviction picks the cheapest
  value that is the only one in the new value's way in a register it may
  take.

`tests/AllocIR.hs` adds a value that crosses a call before a loop and is
used only in a cold block after it: it now shares a preserved register with
a loop value, where it used to force a spill. A second case has three
values across the loop's call with a budget of two, and the value used only
after the loop is the one spilled. A new `simulatePath` simulator follows
branches, so these are checked along the cold path and through 0, 1 and 3
loop turns (the straight-line simulator cannot check holes).

## The pressure model (`Codegen.Pressure`)

`loopPressure` counts, per register class, the values live at each point of
a loop, and the values live across an operation whose expansion may
clobber the caller-saved registers. The second number is the binding one,
because those values must use the callee-saved budget. Classes are guessed
from types and operations (an F64 result is a float register when the
target has a float bank). Liveness is exact on IR values.

`Policy.polRegisters` carries the target's budget: per class, the callee-saved
registers and all allocatable registers (`registerBudget`: a64 9/22 + 8/14
float, x64 5/12, rv 11/19). Loop motion (`Codegen.LoopOptimize`) now:

- takes the longest dependency-ordered prefix of its moves whose loop fits
  the budget; if no prefix fits (the loop was already over), the longest
  that needs no more registers than before;
- hoists a rematerializable value (a constant or static address) only when
  nothing left in the loop still reads it, since hoisting it holds a register
  for the whole loop to save one free instruction.

`tests/LoopOptimize.hs`: motion that only trades one value for another
across the call does not raise pressure; a move that adds a value across
the call is refused under a tight budget while the moves that fit are made;
answers and traps are unchanged on both widths.

## Results (Apple M4, one hart)

The machine was loaded (load average 6-16) during these runs, so the
numbers are seven alternating pairs and only ratios are meaningful.

| Compiler | fold kernel | median |
|---|---|---|
| `09c0417` (before item 4) | spills 4 | 258 ms |
| `c94c64e`, motion on | spills 5 (accumulator in the loop), saves d8 | 303 ms |
| this change, motion off | spills 1 (outside the loop) | 248 ms |
| this change, motion on | spills 0 | 262 ms |

The allocator alone makes the kernel faster than before item 4. With
motion on, the kernel has no spills but is still not faster than without
it: the moved float arithmetic was never on the loop's critical path (the
accumulator's moves between the integer and float registers and the fuel
counter's load and store are). **Motion stays opt-in**
(`FPR_TYPED_IR_LOOP_MOTION=1`); it is now safe to try on other loops.

Compile cost (`tests/check_compile_budget.py`, against the recorded
baseline): std/live +7.7% allocation (was +6.7% after step 5), pos1 +4.5%
(was +3.6%). Peak residency is unchanged. The baseline is not re-recorded.

`codegenRev` 131.

## Validation

`make unit-tests` (AllocIR, LoopOptimize and the rest), and the full Base
suite: 141 jobs in 865 s on six workers.
