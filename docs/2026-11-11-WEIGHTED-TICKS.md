# Weighted ticks: fuel counts instructions

Date: 11 November 2026. Kind: implementation record. Branch `weighted-ticks`,
on top of [register fuel](2026-11-10-REGISTER-FUEL.md). `codegenRev` 212.
Rollback: `FPR_NO_TICK_WEIGHT=1` (build-cache suffix `-notickweight`).

Decided 10 November: a tick charges the worst-case instruction count of the
code it covers, at the tick sites that exist today. This page records that
step. It moves no tick and removes none; it changes what one costs and
therefore what a quantum means.

## What a tick charged, and what it charges now

A tick charged one unit: one per function entry, loop iteration, inlined
callee or counted strip. The work behind a unit ran from a three-instruction
leaf to a body of a thousand IR instructions
([tick batching](2026-11-02-TICK-BATCH.md) says so in as many words: "fuel is
not an exact cost measure for this code"), so a slice of 2000 units was
between a few thousand and a few million instructions.

A tick now charges its **weight**: the largest number of target instructions
the function itself can execute from that tick, its own instructions
included, to the next tick or to an exit. Fuel is then an upper bound on the
instructions generated code has executed since the last refill, and a
quantum is an instruction budget.

The rules, all in `Codegen.Bounds.tickWeights`:

- **Measured on the final stream.** The weight is counted on the target's
  own rendering, after placement, frames and every pseudo's expansion: the
  stream `native-insns-v1` already reads. Each backend renders its function,
  measures, assigns the weights and renders again (`Target.Common.weighTicks`).
  A weight that needs a second instruction to subtract changes the count, so
  the measurement runs twice and each tick takes the larger answer.
- **A call is transparent.** The callee charges its own instructions at its
  own ticks. The instructions after the call returns are the caller's and
  are covered by the tick before the call.
- **The prologue belongs to the first tick.** The instructions between a
  function's first and its entry tick (frame, saves, stack check) have no
  tick before them in this function; every tick the entry reaches without
  crossing another carries them.
- **The worst path, not the taken one.** A tick charges the longest path to
  the next tick. A shorter path is over-charged. Nothing is under-charged.
- **Runtime C is not counted.** A call into the runtime costs its call
  instruction. That was true of unit ticks as well.
- **A counted tick's count is dropped.** `OSafepointN n` stood for the `n`
  unit ticks of the scalar code a SIMD pair or an unrolled column strip
  replaced. Both are straight-line code after the tick, so the weight
  already is their cost.
- **A tick-free cycle keeps unit ticks.** `tickWeights` answers nothing for
  it, as `analyse` answers UNBOUNDED, and the function is left as it was.

Weights on `tests/bench/fib.fpr`, per activation of the scalar worker: 47 on
AArch64, 83 on RV64 (hosted, with its TLS hart read), against one unit
before.

## Encoding

| Target | Tick |
|---|---|
| AArch64 | `subs x27, x27, #w`; past 4095, `sub x27, x27, #hi, lsl #12` first; capped at 2^24 - 1 |
| RISC-V | `addi s11, s11, -w`; past 2047, `li t4, w` and `sub s11, s11, t4` |
| x86-64 | `subq $w, (%r10)` on the hart cell, as before |

## The quantum

`FUEL_QUANTUM` was 2000 units. It is 100,000 instructions, which is about
what 2000 units were on the benchmarks (a unit covers 35 to 130 instructions
there, 47 on `fib`). A build with `FPR_NO_TICK_WEIGHT=1` compiles the runtime
`-DFPR_UNIT_TICKS` and keeps 2000.

The number is a first setting, not a qualified one. It decides how often an
actor is preempted, and QOS's latency budget and the Pi fuel window were
qualified against 2000 units.

## What changes for a program

Outputs do not. Scheduling does: a preemption falls where the instruction
budget runs out, not where the 2000th entry happens to be, so a program of
many small functions yields less often than before and one of large bodies
more often. Every existing preemption point is still one.

A test that counted units exactly (`check_self_loops.py`'s 20,001 entries,
the oracles that seed three or seven units and count yields) checks tick
placement, not cost. Those run with `FPR_NO_TICK_WEIGHT=1`. Oracles that
seed one unit to make every tick hostile are unaffected: any weight spends
it.

## A known over-charge

A self-tail loop in its frame-reusing form has one tick, at the loop label,
and the entry falls into it. It is therefore the first tick the entry
reaches and carries the prologue on every iteration, not only the first
(`ticks` in `tests/check_tick_weights.py`: 61 per iteration on AArch64,
where the loop itself is about 46). Sound, and an over-charge of the loop.
Giving the entry its own tick ahead of the label would remove it.

## Verification

- `tests/check_tick_weights.py` (new, in `check_base`): on AArch64, x86-64
  and RV64 every tick of the fixture carries a weight, a function's first
  tick is charged at least its prologue, a branch-free function is charged
  its own instruction count, and `FPR_NO_TICK_WEIGHT=1` restores units. On
  the host, 20,001 activations spend exactly 20,001 times the printed
  weight, and exactly 20,001 with the flag.
- Five checks count units exactly and are pinned to `FPR_NO_TICK_WEIGHT=1`:
  `check_self_loops`, `check_self_loop_rv64`, `check_self_loop_x64`,
  `check_early_loops` and `check_captured_simd`. They test where ticks are,
  which this step does not change.
- On the Mac: the `native`, `riscv` and `host-extra` groups, `make
  unit-tests`, and `check_base` with the five jobs still red on main set
  aside.

Timing on the M4 is unchanged from register fuel within noise, as expected:
no tick was added or removed.

## Not in this step

- **Fewer ticks.** With weights, a call to a small bounded function could be
  charged at the caller's tick and the callee's own tick dropped. That is
  where the time is; it makes the bound interprocedural and is the next
  step.
- **QOS, the Pi and the boards.** The quantum and the fuel window.
