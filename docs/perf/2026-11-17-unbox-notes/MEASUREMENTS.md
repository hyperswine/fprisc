# C6 unboxing scratch measurements (2026-11-17, Sydney time)

Scratch notes, not for merge. callgrind instruction counts (Ir), x86-64 Linux box.

## Microbench (microbench/readl.fpr, sendl.fpr; recreated 12:40 after the 12:08 wipe)
Single run, before the readl fix:
- readl: walkers 26c5c459 297,663,318 -> 3c 6701f461 466,299,172 (+56.7%)
  - fpr_alloc 136,486,954 -> 266,486,723; I64.ofField 2,000,000 calls (20 reps x 100k fields)
  - cause: an I64 field read re-boxes through a C call to I64.ofField and fpr_alloc
- sendl: walkers 24,790,033,637 / 3c 2,394,494,156 (cross-hart, under valgrind's serialised threads:
  dominated by waiting, not a usable comparison)

## Microbench median of 3 (13:45)
d = ari/unbox-walkers 26c5c459, e = 3c 6701f461, f = 3c + inline box/unbox 258d8d63

| bench | d | e | f |
|---|---|---|---|
| readl | 298,986,723 | 467,064,581 (+56.2%) | 354,758,726 (+18.7%) |
| sendl0 (same-hart send, microbench/sendl0.fpr) | 1,287,189,576 | 1,040,470,502 (-19.2%) | 1,041,618,681 (-19.1%) |

Runs: readl d 297663318 298986723 299334878; e 466299172 467064581 467991151; f 354705507 354758726 355348815.
sendl0 d 1282919717 1287189576 1288032835; e 1038608529 1040470502 1041753643; f 1040901306 1041618681 1042241426.

## MutMap mm_cap_for (13:10, walkers fpr)
- cap.fpr, MutMap.withCapacity 2^60: cap 2^61 passes the guard (cap > (uw)-1 >> 3), mm_cols' ncap * sizeof(uw) = 2^64 wraps to 0,
  fpr_alloc_bulk(0), then mm_clear writes 2^61 slots past it: OOM-killed (anon-rss 12,149,504 kB), "reserved" never printed.
- cap2.fpr, 2^62 - 1: clean panic "MutMap: capacity out of range", exit 1.

## 16 benches, callgrind median of 3 (cg.sh sizes): walkers 26c5c459 vs 3c+fix 258d8d63
```
sim                2,887,613,614   2,887,438,114  -0.01%  spread 0.10%
csv                4,229,738,081   4,229,166,650  -0.01%  spread 0.04%
wordfreq           4,490,599,603   4,492,220,391  +0.04%  spread 0.03%
wordfreq_mutmap    2,169,583,557   2,170,185,313  +0.03%  spread 0.15%
format             2,781,009,735   2,791,458,554  +0.38%  spread 0.21%
records            2,255,062,357   2,255,840,000  +0.03%  spread 0.12%
treemap            1,810,558,756   1,810,517,346  -0.00%  spread 0.05%
treemap_mutmap     2,221,673,045   2,221,672,396  -0.00%  spread 0.01%
binarytrees        1,968,100,986   1,967,399,949  -0.04%  spread 0.11%
fannkuchredux        820,873,366     820,899,480  +0.00%  spread 0.11%
nbody              1,552,511,654   1,552,447,074  -0.00%  spread 0.03%
spectralnorm         833,559,886     833,618,653  +0.01%  spread 0.02%
mandelbrot           821,141,340     821,193,732  +0.01%  spread 0.10%
fasta                400,747,993     400,766,668  +0.00%  spread 0.02%
knucleotide        2,413,237,220   2,413,339,427  +0.00%  spread 0.04%
revcomp              257,396,925     257,411,755  +0.01%  spread 0.01%
```
Outputs 16/16 match on both. 3c tests at 258d8d63: unit 45/45, run.sol 21 checks 0 unexpected (layout-raw-i64 PASS), compile budget hello 1,381,507,216 / std-live 30,879,008,736 / pos1 66,782,558,768 bytes allocated (ghc-9.8.2).
