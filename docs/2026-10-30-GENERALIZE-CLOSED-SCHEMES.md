# Skipping closed schemes in `generalize`

Date: 2026-10-30. Kind: change + measurement. Applies to `main` at `7f4ad0d`.
Companion to `2026-10-30-QUADRATIC-TRAVERSALS.md` (PR #30).

## Change
`generalize` (`Infer.hs:327`) folded `schemeFtv` (snapshot, zonk, `force`)
over every environment entry at every SCC. A scheme whose stored type has no
free type or row variable outside its quantifiers (`closedScheme`) now
contributes `mempty` without the snapshot. **Why it is output-safe:** zonk
only rewrites metavariables, and `snapshotScheme` renames exactly the
quantifiers, so such a scheme's snapshot always has an empty free set,
whatever the current substitution. `snapshotScheme` and its quantifier
renaming are unchanged; open schemes take the original path.

## Measurements (Sol typecheck, N = 3200, ms, three runs)
| family | main | skip |
|---|---|---|
| wide | 3776, 2878, 2683 | 2866, 2635, 2605 |
| chain | 2665, 2458, 2444 | 2270, 2260, 2165 |

3-10% faster; the exponent stays ~2 (wide 2.00, chain 1.95 at 1600 -> 3200).
On Sol `wide` 1600 the profiled share of `generalize` fell from 29.8% to
15.7% (inclusive); it still visits every entry per SCC.

## What remains (profile, Sol `wide` 1600, after the skip)
- `inferTopsResult` self 31.9% time / 32.7% alloc, including 2.87M `zonk`
  calls: the numeric-defaulting loop zonks **every** operator site in the
  program at each SCC (`forM_ (IM.elems sites)` in `inferSCC`).
- `constrainCarrierSites` (`Infer.hs:978`) lists the whole site map with
  `IM.toList` and filters `k >= first` per SCC (5.1%).
- `inferSCC`'s `clauses n` rescans all tops per SCC (from reading the
  code; not separately measured).
- `Safety.callGraphOf` (`Safety.hs:292`) 8.2%.

## Constraint for the follow-up (Jack, 2026-10-30)
An operator site from an earlier group **can still be an unsolved type
variable that a later group's defaulting must pin to Int**. Scoping the
defaulting or carrier loops to the current group (e.g. `IM.split` at
`firstSite`) is therefore unsafe. Safe directions to explore: a worklist of
still-unsolved sites (a site leaves it once its zonked type is no longer a
bare variable, which can never revert), and indexing clauses by name once
per run instead of rescanning `tops` per SCC.

Regression test: `tests/GeneralizeClosed.hs` compares `generalize` with the
original formula on closed, open, mixed and solved environments.
