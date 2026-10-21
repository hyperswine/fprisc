# The typed-IR fib regression: cause, four experiments, one default

Date: 2026-10-22. Kind: implementation and measurement record.
Base: main `6b42a60` (the typed-IR migration merged). Branch `typed-ir-fib`.
Host: Apple M4, macOS 27.0.1, one hart, the paired driver
`tools/bench-typed-ir-m3.py` (31 alternating rounds, warm-up, every output
checked, seeded bootstrap of the median paired ratio).

The [migration record](2026-10-22-TYPED-IR-MIGRATION.md) left fib 12% slower
than the best legacy combination (`legacy-best`: `FPR_COSTED_REGISTERS=1
FPR_COMPACT_FRAMES=1 FPR_SELF_LOOPS=1 FPR_A64_FRAME_PAIRS=1`) and named it the
promotion blocker for A64. This page finds the cause, measures four
separately switched changes and makes one of them the backend's default.

## Cause

Half of `fib 35`'s activations are leaves (`n < 2`). The typed backend's
worker, against legacy-best's:

- **The frame link** was two stores (`stur x30`, `stur x29`) and two loads,
  where legacy-best uses one `stp`/`ldp` pair.
- **Callee saves on every path.** `n` must survive the entry's runtime calls
  (stack growth, fuel), and on the recursive path the calls to fib. The
  allocator keeps one interval per value, so `n` sits in `x19` from the
  entry on, and the prologue saves and restores `x19` and `x20` on every
  activation, leaves included, though only the recursive path needs them.

## Four switches

Each is its own unit and run cache identity.

| Switch | What it does | Where |
|---|---|---|
| `FPR_TYPED_IR_LINK_PAIRS` | the frame link as one `stp x29, x30` / `ldp`, same two words, same layout, when the offset fits the scaled range | A64 render |
| `FPR_TYPED_IR_ENTRY_ARGS=1` | every function's register parameters stay in their registers through the entry; only the entry's slow paths park and reload them (the migration's wrapper-only forwarding, generalised, and allowed on Mach-O TLV, whose hart read preserves `x1..x7` and saves `x0` itself) | `Common.forwardEntry`, A64 and x64 |
| `FPR_TYPED_IR_SPLIT_ENTRY=1` | each single-predecessor successor of the entry block gets its own copy, as a block parameter, of each entry value it carries across a call; uses in the region it dominates are renamed | `Codegen/Split.hs`, before selection, verified |
| `FPR_TYPED_IR_SHRINK_WRAP=1` | callee saves at the deepest block dominating every use of a saved register, if that block is on no cycle and dominates every return reachable from it; only those returns restore | `Common.shrinkWrap`, A64 |

With all four, a fib leaf runs the paired link, the entry, the compare and
the paired epilogue, and touches no callee-saved register; the recursive
arm saves `x19`/`x20` once.

## Measurements

Median paired ratio against `legacy-best` (below 1 is faster), 95% interval.

First run ([summary](evidence/2026-10-22-typed-ir-fib/run1-summary.md),
[raw](evidence/2026-10-22-typed-ir-fib/run1-results.json), commit `760f5eb`),
with the split moving every entry value:

| Variant | fib | sum | helpers | SHA |
|---|---:|---:|---:|---:|
| typed-ir (merged) | 1.119 | 0.639 | 0.583 | 0.913 |
| + link pairs | 1.024 | 0.634 | 0.589 | 0.914 |
| + entry args | 1.059 | 0.635 | 0.603 | 0.915 |
| + args, split | 1.029 | 0.788 | 0.604 | 0.944 |
| + args, split, wrap | 1.004 | 0.786 | 0.599 | 0.995 |
| all four | 1.005 | 0.788 | 0.597 | 0.939 |

Splitting every value added copies to each turn of sum's self loop, 23%
slower. The split now moves only values the successor's region uses after
a call-like operation (`6864b0d`); sum's loop and fib's returning arm are
untouched (`tests/TypedIR.hs`).

Second run ([summary](evidence/2026-10-22-typed-ir-fib/run2-summary.md),
[raw](evidence/2026-10-22-typed-ir-fib/run2-results.json), commit `6864b0d`):

| Variant / legacy-best | fib | sum | pipeline | helpers | SHA |
|---|---:|---:|---:|---:|---:|
| typed-ir (merged) | 1.113 (1.101..1.126) | 0.635 | 1.056 | 0.601 | 0.908 |
| + link pairs | **1.017 (0.993..1.029)** | 0.632 | 1.034 | 0.601 | 0.914 |
| + args, split, wrap | 0.997 (0.989..1.012) | 0.640 | 1.051 | 0.611 | 0.940 |
| all four | 0.986 (0.943..1.010) | 0.654 | 1.063 | 0.614 | 0.888 |

Against the merged backend directly, the link pairs alone: fib 0.902
(0.885..0.918, 31/31 faster), every other workload within 1% with its
interval containing 1. All four: fib 0.876, SHA 0.981, but sum 1.015 and
helpers 1.017, both outside their intervals.

## Decision

- **The paired link is now the backend's default** (on unless
  `FPR_TYPED_IR_LINK_PAIRS=0`; A64 selection revision 11). It removes the
  fib regression on this host: 1.017 against legacy-best with an interval
  that includes parity, and changes nothing else measurably.
- **Entry arguments, the split and shrink-wrapping stay opt-in.** Together
  they make fib slightly faster than legacy-best and SHA 2% faster than the
  merged backend, but cost sum and helpers about 1.5 to 2%. Each works and
  is tested; whether to turn them on is a per-workload trade, not a default.
- **Pipeline stays 3 to 6% slower than legacy-best** in every variant: its
  specialised main is legacy by design until typed vector kernels exist
  (the next step), so that gap is not this page's.

## Validation (this Mac, arm64)

With the link pairs on by default: `check_typed_ir.py`,
`check_typed_ir_a64.py`, `check_typed_ir_aggregates.py`,
`check_typed_ir_coverage.py`, `check_typed_ir_rv.py`, `check_registers.py`,
`check_self_loops.py`, `check_workers.py`, `check_reuse.py`,
`check_x64_local.py --require-execution` (Rosetta) and the full
`check_base.py` (105 jobs) pass. With all three opt-in experiments on as
well, `check_typed_ir_a64.py` (Mach-O TLV and x28, ELF, 1 and 4 harts,
stack-segment crossing, C both ways, caches), `check_typed_ir_aggregates.py`
and the Rosetta suite pass. `tests/TypedIR.hs` checks the split
(verification, unchanged results, traps and events on fib, sum, addovf and
the terminating-expression fixtures; only fib's calling arm split; sum
untouched); `tests/SelectedIR.hs` checks shrink-wrap placement and its
three refusals. Native Linux x86-64 is CI's leg.

## Not verified

- x86-64 and RISC-V timing: the link pairs are A64-only; entry arguments
  apply to x64 too but no x86 timing was taken. RISC-V has neither.
- The fib frame-pair benefit seen on the Mac mini (none, in M3) against
  this M4: these numbers are this host's.
- Physical boards and QOS.
