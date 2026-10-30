# Quadratic traversals in compile time: measured scaling

Date: 2026-10-30. Kind: measurement. Applies to `main` at `7f4ad0d`.
Follows [the redundant-work review](2026-10-28-REDUNDANT-WORK-REVIEW.md).

**Method.** Synthetic inputs at N = 100..6400, one compiler per run, fresh
`XDG_CACHE_HOME`, wall clock (fpr) or `SOL_TIMINGS` phases (Sol), exponent =
log-log slope of the last doubling. Hot spots from the late-cost-centre
profiled build (`make fpr-prof` equivalent). One box, 8 cores, other jobs
idle except where noted; single runs, so treat exponents as ±0.2.

## Families
- `let`: one function with an N-line let chain (`vI = vI-1 + I;`)
- `wide`: N independent one-line functions; `chain`: fI calls fI-1
- Sol `seq`: N `> print I.` lines; Sol `case`: one N-arm case

## fpr compile --system=posix (whole compile, main)

| family | 800 | 1600 | 3200 | 6400 | exponent (last) |
|---|---|---|---|---|---|
| let | 1.13 s | 2.92 s | 10.94 s | 43.67 s | 2.00 |
| wide | 0.81 s | 2.04 s | 5.55 s | 21.54 s | 1.96 |
| chain | 1.49 s | 3.43 s | 9.12 s | 31.14 s | 1.77 |

Profile shares (self time): `let` 3200: `Core.Typed.FusionSafety.facts` 20.8%,
`Codegen.Bounds.analyse` 11.1%, `Codegen.Allocate.within` 9.9%, `Workers` 9.1%,
`Reuse.nodes` 6.3%, `Core.Syntax.freeVars` 5.3%. `wide` 3200: `Infer`
(`inferTopsResult` 22%, `zonk` 8.9%, `freshenScheme` 6.1%, `generalize` 5.2%),
`Safety.callGraphOf` 4.4%, `sourceGroups` 4.3%.

## Sol phases (ms, main)

| family | phase | 200 | 400 | 800 | 1600 | 3200 | exp |
|---|---|---|---|---|---|---|---|
| wide | typecheck | 35 | 59 | 156 | 566 | 2407 | 2.09 |
| wide | lower | 1.6 | 3.7 | 10.6 | 41 | 232 | 2.49 |
| chain | typecheck | 34 | 65 | 154 | 618 | 2450 | 1.99 |
| seq | lower | 2.2 | 7.3 | 27.6 | 197 | 1262 | 2.68 |
| seq | typecheck | 2.1 | 3.6 | 5.5 | 26 | 111 | 2.11 |
| case | typecheck | 2.1 | 3.2 | 10.4 | 30 | 73 | 1.29 |

## Confirmed sites
1. `Frontend/Traverse.hs:136` `sourceGroups`: `nub` + a full rescan per
   name, O(names × tops). 51.7% of the Sol `seq` 1600 profile; the whole of
   Sol `lower`'s super-linearity. **Fixed** (perf-source-groups): one pass with
   a Map; seq 3200 lower 1262 ms -> under 20 ms, startup 1486 -> 203 ms.
2. `Infer.hs:327` `generalize` folds `schemeFtv` (snapshot + zonk + freshen)
   over the whole environment at every SCC: 1694 calls × ~925 schemes =
   1.57M `snapshotScheme` on Sol `wide` 1600, ~30% of time and 53% of
   allocation. Cause of Sol typecheck and fpr `wide`/`chain` ~N². Not fixed.

## Suspected, not confirmed as a wall-time cost
- `Core/Syntax.hs:45` `freeVars` (filter per binder, left `++`): rewritten
  with an accumulator (branch perf-freevars, byte-identical corpus) but no
  measurable change on `let`/`wide`/`chain`; not proposed as a PR.
- `Infer.hs:1716` nub + `clausesOf` rescan and `acc ++ rws` per SCC: fixed
  locally (perf-infer-groups), no measurable typecheck change; dominated by 2.
- `FusionSafety.facts`, `Bounds.analyse`, `Allocate.within` (review 3.4) on
  the `let` family: top of the profile, per-node re-walks suspected; not yet
  scaled per phase.
- `Safety.callGraphOf` (`Safety.hs:292`): 7.6% on Sol `wide` 1600.

## Larger fixes (estimates)
- Cache the free type variables of closed environment entries (a closed
  scheme stays closed under the solver substitution), or keep a level-based
  generalization: removes 2; medium effort, medium risk (quantifier
  renaming in `snapshotScheme` must stay observable-identical).
- Per-function re-walk in `FusionSafety`/`Bounds`/`Allocate`: needs a
  per-phase breakdown of the `let` family first.

Reproduce: `tools/sol-scaling-bench.py ./fpr`.
