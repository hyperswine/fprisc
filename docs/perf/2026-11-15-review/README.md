# Review of main f5411dbe..beca82ea (2026-11-15)

Box: 8 vCPU Linux x86-64, no HW PMU. Compiler built at beca82ea with ghc-9.8.2.
Timing: `bench_oldnew.py`, 5 load-gated runs interleaved in one session (old 3485b92f binaries
vs new beca82ea binaries; load1 <= 0.99 at every run start). Median wall, median peak RSS.
Instruction counts: valgrind callgrind, whole program. The old numbers are from the 2026-11-14 profile.
The absolute old timings here are lower than the 2026-11-14 doc's (it was a different box session); compare old to new within this table only.

| app | old wall | new wall | delta | old RSS | new RSS | old Ir | new Ir | C Ir | new/C Ir |
|---|---|---|---|---|---|---|---|---|---|
| sim | 0.351 | 0.215 | -39% | 14 | 14 | 6.714G | 3.409G | 0.722G | 4.7x (was 9.3x) |
| csv | 0.621 | 0.496 | -20% | 170 | 144 | 5.934G | 4.817G | 0.278G | 17.3x (was 21.3x) |
| wordfreq | 1.043 | 0.907 | -13% | 342 | 236 | 6.426G | 4.717G | 0.475G | 9.9x (was 13.5x) |
| wordfreq_mutmap | 0.600 | 0.437 | -27% | 341 | 231 | 3.892G | 2.364G | - | - |
| treemap | 0.925 | 0.841 | -9% | 60 | 59 | 3.148G | 2.276G | 0.286G | 8.0x (was 11.0x) |
| treemap_mutmap | 0.371 | 0.356 | -4% | 159 | 159 | | | | |
| treemap_hashmap | 1.499 | 0.682 | -55% | 134 | 141 | 6.016G | 3.128G | | |
| csv_hashmap | 0.671 | 0.408 | -39% | 170 | 145 | | | | |
| wordfreq_hashmap* | 1.112 | 0.604 | -46% | 341 | 238 | | | | |
| format | 0.567 | 0.572 | +1% (noise) | 394 | 394 | | | | |
| records | 0.621 | 0.660 | +6% (min 0.482 -> 0.427, noise) | 125 | 125 | | | | |

*wordfreq_hashmap.fpr itself changed in c3e7cdea; old binary = old source.

Per-function (callgrind, see callgrind-top-*.txt):
- charFrom (csv): 1117.6M -> 625.7M Ir, about 28 -> about 15.7 instr/byte (scaled from the old 28/byte).
- sim run loop: 6583M -> 3314M Ir, about 166 -> about 84 instr/step.
- Unchanged C runtime: g_strCompare, g_substr, fpr_alloc identical Ir; dc_size_in (138.8M) and
  kp_reaches (73.5M) in treemap unchanged. kp_reaches in wordfreq rose 92.1M -> 143.7M.

Soundness: nodeGet/nodeSet/nodeWith are global builtins typed `Int -> a -> a` etc. (Infer.hs:825-827).
- soundness/ns.fpr: `nodeSet 0 a (P 9 9)` mutates an immutable `P 1 2` in place and the Int field
  then prints as `P 9 9` (type confusion).
- soundness/ng.fpr: `nodeGet 7 42` segfaults (rc 139).
