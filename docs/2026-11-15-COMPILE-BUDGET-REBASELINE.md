# Compile budget: ghc-9.6.6 re-baseline and where the allocation went (15 November)

The `compile-budget` Sol check (`tests/sol-checks/compile-budget.sol`) gates the
compiler's own allocation on three fixed programs at 10% over the per-GHC
baseline in `tests/compile_budget.json`. The ghc-9.6.6 x86-64 baseline was
recorded on CI at `4363e729` (1 November). Since the Sol checks returned to CI
(#75), `sol-checks` has failed on it on every `main` run. At `ea8509cf`
(CI run 43614330393):

| program  | allocated (CI, GHC 9.6.6) | vs 4363e729 baseline | peak live | vs baseline |
|----------|---------------------------|----------------------|-----------|-------------|
| hello    | 1,533,390,688             | +14.1%               | 46,279,688  | +1.9%  |
| std-live | 34,312,233,976            | +22.2%               | 374,199,576 | -11.3% |
| pos1     | 70,914,254,352            | +16.6%               | 623,059,016 | -8.4%  |

This change records those exact CI measurements as the new ghc-9.6.6 baseline.
The darwin (ghc-9.8.2) baseline is unchanged.

## Where the growth came from

Bisected on the first-parent history with GHC 9.8.2 on x86-64 Linux, using the
same programs and flags as the check (`./fpr compile --system=posix`, cold
cache, `+RTS -t --machine-readable`). Allocation is deterministic to within
about 0.01% between runs. The 9.8.2 totals track CI's 9.6.6 deltas closely:
`4363e729` 1.294 / 27.54 / 59.96 GB against `ea8509cf` 1.485 / 33.77 /
70.04 GB (hello / std-live / pos1) is +14.8% / +22.6% / +16.8%.

| commit (first parent) | hello GB | std-live GB | pos1 GB | note |
|---|---|---|---|---|
| 4363e729 (baseline, Nov 1) | 1.294 | 27.54 | 59.96 | |
| f05f089a | 1.334 | 28.16 | 61.12 | |
| 22fd51b1 | 1.344 | 28.46 | 62.03 | |
| 2d3b9d67 Move TRMC to checked typed IR | 1.409 | 30.11 | 65.48 | +4.8 / +5.8 / +5.6%; the only compiler change since 22fd51b1 |
| 15bad00f Merge inline bump allocation | 1.419 | 30.39 | 66.13 | +0.7 / +0.9 / +1.0% |
| a7f4fd6f (after 7b24f9cc typed case tests, interval bounds) | 1.456 | 31.32 | 67.83 | +2.6 / +3.0 / +2.6% over 15bad00f |
| 43f02dcb (after 5e4f248a zero-overhead completion) | 1.488 | 31.31 | 64.54 | |
| 042fce3f | 1.497 | 31.49 | 64.82 | |
| ba33b2d1 | 1.346 | 29.20 | 60.60 | an improvement landed between 042fce3f and here |
| 00aca3a1 | 1.372 | 30.62 | 62.46 | |
| aee9ce39 (after static reuse increments 592d266b..69d893a0) | 1.414 | 32.00 | 65.35 | +3.1 / +4.5 / +4.6% over 00aca3a1, not split further |
| 1b139bdd | 1.430 | 32.38 | 65.97 | |
| 11ae6aba | 1.415 | 32.05 | 65.51 | |
| 8040c386 String-scan versioning and early loops on by default | 1.483 | 33.52 | 67.65 | +4.8 / +4.6 / +3.3% |
| 77c3261a Weighted ticks | 1.596 | 36.11 | 72.10 | +7.6 / +7.7 / +6.6% |
| c24f3542 (after b82cb49e: render once, ticks again) | 1.515 | 34.23 | 68.80 | weighted ticks net +2.2 / +2.1 / +1.7% |
| bd92c978 | 1.515 | 34.23 | 68.79 | |
| 23f10023 | 1.536 | 34.98 | 70.05 | |
| ea8509cf (main) | 1.485 | 33.77 | 70.04 | |

On `ea8509cf`, `FPR_NO_TICK_WEIGHT=1` gives 1.461 / 33.30 / 69.21 GB, so
weighted ticks now cost 1.6% / 1.4% / 1.2%.

The growth is spread over deliberate compiler work: TRMC on the typed IR
(about 5%), typed case tests and interval bounds (about 3%), static reuse
(about 3-5%), String-scan versioning and early loops (about 4%) and weighted
ticks (about 2%). No single commit accounts for more than about 6%, and each
step lines up with a pass that is meant to do more work. The passes were not
profiled, so an accidental cost inside one of them is not ruled out, but there
was no single cheap, safe fix to make here. Peak residency is below
the old baseline for std-live and pos1. That is why this re-records the
baseline rather than reverting or gating any of these passes.

## Follow-ups

- Profile the weighted-tick pass and `Codegen.Bounds.tickWeights` (it still
  measures every function's rendered stream) and the typed-IR TRMC pass if
  compile time becomes a priority; neither was profiled here.
- Record the baseline in the same commit as each intended compile-cost change
  from now on, as the check's header asks, so the next drift is attributable
  from CI logs alone.
