# Step 7b measured: splitting at loop boundaries

2026-10-28. The remaining piece of plan step 7
(`docs/2026-10-27-STEPS-6-8-REMAINING.md`, "7b. Splitting at loop
boundaries") was measured before building it, since steps 3-6 (inline
vector and string reads, the difference-bound discharge) landed in
between and reduce the pressure that would make it matter.

## The measurement

A temporary diagnostic in `Codegen.Allocate` (removed afterwards)
profiled every spilled value in the bench suite with cold unit caches:
accesses at loop depth > 0 vs outside, and whether the interval crosses
a loop block. Raw data in `bench/2026-10-28-splitting-7b-survey.json`.

- **a64**: 40 spilled values suite-wide. Exactly **8** are 7b-shaped
  (live across a loop, *no* use or definition inside it, spilled
  everywhere): one each in floatcmp's loop, sha's
  extend/blocks/rounds/sha1Rounds, and three std/string scan loops.
  Their outside accesses total **19** — all cold.
- **x64** (12 allocatable registers): 699 spills in three programs, 78
  of them 7b-shaped with 189 outside accesses — still every one outside
  the loops.

## Why the verdict is "not now"

The split a 7b value gets — register outside, slot inside, a store and
a reload on the loop boundary edges — leaves the hot loop body
**byte-identical**: the value is unused there, so the loop emits the
same instructions either way. The entire benefit is turning a handful of
cold loads and stores into register reads. No benchmark would move.

The genuinely valuable form of step 7 is the other direction: splitting
at *call* boundaries, so a value crosses a call in a slot but lives in a
(caller-saved) register elsewhere — aimed at loops whose calls force the
small callee-saved budget. The suite shows no such victim today:
pingpong's call-heavy loops are spill-free, and sha's 23 spills in
`rounds` sit in a body with no call — that is pure over-pressure (the
hash state simply exceeds the bank), which splitting cannot fix. Its
remedy is fewer live values: cross-block sharing of the repeated
`untag`/`load` pairs (plan step 4.3, the same repetition the interval
pass now resolves analytically) and, eventually, rematerialization.

If either shape appears in real programs — a spilled value crossing a
loop unused inside and read on a hot path outside it, or a hot loop
whose call forces callee-saved spills — the survey here is the way to
see it, and edge move resolution becomes worth its complexity then.
