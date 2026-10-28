# Tick amortization: the measured bound

Date: 2026-10-27. Kind: measurement. Applies to main at `e6fadfb` (codegen
revision 135). The measure-first gate for step 8 of
[the performance plan](2026-10-26-PERFORMANCE-PLAN.md), as designed in
[steps 6-8: what remains](2026-10-27-STEPS-6-8-REMAINING.md). An earlier
attempt with a scratch compiler flag did not take effect; this page gets
the number by editing the build's own assembly.

## Method

A 200,000,000-iteration self tail-call countdown (two Int operations and a
compare per iteration, no allocation) was built with `fpr build --keep`,
and the kept root assembly was edited by hand in two variants:

- **tickonly**: the loop keeps the hart read (`mov x9, x28`) and drops the
  five fuel-cell instructions (`ldur`/`sub`/`stur`/`cmp`/`b.gt`) and the
  slow-path call;
- **notick**: the loop drops the hart read as well.

Both variants, and the unedited reference, were linked against the same
runtime objects, cc flags and prelude unit as `fpr build`, and produce the
correct sum on every run. Seven to ten alternating samples after warmup;
medians with minima alongside. Source, hashes and all samples are in
[the raw record](../bench/2026-10-27-tick-amortization-bound.json).

## Result (Apple M4, one loop, no other load)

| Variant | Median | Min | Speedup |
|---|---:|---:|---:|
| reference (tick per iteration) | 0.298 s | 0.294 s | -- |
| tick cell removed, hart read kept | 0.244 s | 0.235 s | **1.22x** |
| both removed | 0.214 s | 0.214 s | **1.39x** |

A first round under light background load read 1.36x / 1.48x; the table is
the quieter second round. The per-iteration tick therefore costs **20-40%
of the tightest loop this machine runs**, split roughly 6:1 between the
fuel cell's loop-carried memory dependency and the hart-read move.

This is an upper bound: the probe's loop body is six instructions, so the
tick is a large share. Loops with real work see proportionally less, and
loops whose tick is amortized over a kernel strip already pay it once per
strip (`OSafepointN`).

## Notes for the design

- The measured per-iteration sequence in the `fpr build` configuration is
  six instructions: `mov x9, x28`, then the four fuel-cell ops and the
  branch. The countdown design (a register block parameter decremented per
  iteration, with `OSafepointN K` at zero) replaces all six with two
  register instructions, so it should capture close to the full removal
  number.
- The TLV call seen in `fpr compile --target=a64mac` output
  (`_fpr_posix_hart@TLVPPAGE` + `blr`) is a different hart contract from
  the build's `x28` reservation and was not what ran here. If the TLV
  contract ever becomes the hosted default, the tick's cost under it is
  much larger and worth its own measurement.
- Self tail-call loops are formed in the allocator (`loopForm`), below the
  IR: they need the countdown inserted there through target hooks, or self
  tail calls turned into IR loops before lowering, as the plan's step 8
  already records.

**Decision: step 8 is worth building.** A 1.2-1.4x bound on the tightest
loop, with no memory-model change, clears the bar the plan set.
