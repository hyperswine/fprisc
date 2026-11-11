# Decisions: copy-out, memory gates and the next memory work

Date: 11 November 2026. Kind: decision record. The owner's answers to the
open questions of the [automatic copy-out](2026-11-11-AUTOMATIC-COPY-OUT.md) work.

| # | Question | Decision |
|---|---|---|
| 1 | Is copy-out on by default acceptable under the semantic policy? A failure from exhausted memory can land at a different point, because copy timing follows the per-hart allocation clock. | **Accepted completely.** Copy-out stays on by default. |
| 2 | Survival threshold (`FPR_REGION_SURVIVAL`) | **Keep 1/16.** Revisit only with a cheaper copier. |
| 3 | The `bench/apps` branch | **Merge everything into main and push**, these decisions included. |
| 4 | A transfer slab may point into the caller's pool, while `sendArc` pins only a root's slab | **Accepted.** It is the per-slab escape rule that ordinary pool graphs already rely on. |
| 5 | The next memory work | **Static reuse**: element reuse in consuming maps, freshness through `List.reverse`, the region cycle re-entering the consuming twin, and consuming `Map` updates. |
| 6 | Should memory be a gate? | **Yes: add a ceiling.** The app suite gets peak-RSS ceilings that fail the run. |
| 7 | The four checks already failing at `57201f0` (`check_x64_scalar`, `check_x64_qos`, `check_trmc_arc`, `check_trust`) | **Triage them.** |

## How each is carried out

1. No change. The default stays as committed in `1261f167`.
2. No change.
3. `bench/apps` is merged into `main` and pushed once the triage and ceiling work is on the branch.
4. No change. The automatic copy-out page records the review point.
5. Work on a new branch from `main` after the merge, and merged and pushed the same way.
6. `tests/bench/apps/ceilings.json` and `run.py --check-ceilings`. Each workload's ceiling is
   about 1.5x the peak RSS measured with copy-out on (M4, 11 November). A run
   above it fails.
7. Each failure is diagnosed and either fixed or recorded with its cause in the
   [triage page](2026-11-11-TRIAGE-FOUR-CHECKS.md).
