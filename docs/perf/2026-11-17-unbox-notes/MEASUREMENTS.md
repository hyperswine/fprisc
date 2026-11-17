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
