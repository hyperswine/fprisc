# Performance baseline on the typed IR (review step 0)

Date: 2026-10-26. Step 0 of [the native performance review](2026-10-25-PERFORMANCE-REVIEW.md):
re-measure the benchmark set on the current compiler (`ed05cd9`), with C
references, before any of the review's structural changes. Record:
[bench/2026-10-26-step0-baseline.json](../bench/2026-10-26-step0-baseline.json).
Host: Apple M4 (`macm4`), AArch64 only; x86-64 is not measured here (this Mac
would run it under Rosetta).

`tools/bench.py --c` now also builds `tests/bench/c/<name>.c` with `cc -O2`
where one exists, checks it prints the benchmark's `.expected`, and prints
FP-RISC over C. References exist for fib, byteloop and sha.

## Results

Fastest of nine runs:

| Benchmark | ms | vs 2026-10-01 baseline | C -O2 | FP-RISC / C |
|---|---|---|---|---|
| byteloop | 88.9 | 1.16x faster | 3.9 | 22.9 |
| fib | 49.5 | 1.11x faster | 19.3 | 2.6 |
| sha | 133.9 | 1.14x faster | 4.7 | 28.8 |
| helpers | 109.8 | 2.53x faster | | |
| nbody | 233.1 | 1.90x faster | | |
| pingpong | 360.6 | **2.13x slower** | | |
| xpingpong | 389.2 | **1.52x slower** | | |
| strbuild | 177.4 | **1.69x slower** | | |
| vecread | 219.0 | **1.39x slower** | | |
| floatcmp | 43.1 | | | |
| mixed_locals | 4.0 | | | |
| specialization | 6.3 | | | |

`bench/baseline.json` (2026-10-01, the retired generator) is left as it is, so
`tools/bench.py` keeps flagging the four regressions until they are explained.
fib's gap to C was 3.4x on 2026-10-20 ([fib gap](2026-10-20-FIB-GAP-TO-C.md)).
`workers.fpr` is a fixture for `measure_workers.py`, not a standalone
benchmark: it links only with its C probe.

## The four regressions

Region switches, fastest of seven, repeated twice (agreeing within 2 ms):

| | default | `FPR_NO_LOOP_REGIONS=1` | `FPR_NO_CALL_REGIONS=1` | both |
|---|---|---|---|---|
| strbuild | 174.3 | 125.4 | 122.4 | 124.5 |
| vecread | 216.3 | 199.4 | 221.2 | 200.7 |

**Correction (same day):** the "both" column first read 174.2 and 219.2.
Those runs set both variables in one unquoted zsh word, so neither switch took
effect; the values above are a corrected rerun. strbuild is slow only with
both kinds of region on. Loop regions cost vecread about 8%.
[The regression investigation](2026-10-26-PERFORMANCE-REGRESSIONS.md) found
the causes.
pingpong and xpingpong do not move with either switch; their regression since
2026-10-01 has another cause (message lifetime and receive-turn changes are
the candidates). None of these causes is established yet.

## What the gaps point at

byteloop and sha are 23-29x from C. Both are byte loops that keep a bounds
check and an overflow check per step (review section 3), and sha's work is in
`std/digest`, a separate unit the root cannot inline from (section 2). fib's
remaining 2.6x is call cost (section 1 and the earlier fib page).
