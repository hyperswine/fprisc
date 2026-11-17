# C6 unboxing scratch measurements (2026-11-17, Sydney time)

Scratch notes, not for merge. callgrind instruction counts (Ir), x86-64 Linux box.

## Microbench (microbench/readl.fpr, sendl.fpr; recreated 12:40 after the 12:08 wipe)
Single run, before the readl fix:
- readl: walkers 26c5c459 297,663,318 -> 3c 6701f461 466,299,172 (+56.7%)
  - fpr_alloc 136,486,954 -> 266,486,723; I64.ofField 2,000,000 calls (20 reps x 100k fields)
  - cause: an I64 field read re-boxes through a C call to I64.ofField and fpr_alloc
- sendl: walkers 24,790,033,637 / 3c 2,394,494,156 (cross-hart, under valgrind's serialised threads:
  dominated by waiting, not a usable comparison)
