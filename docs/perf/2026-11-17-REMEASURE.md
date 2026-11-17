# Overhead remeasure, 17 November 2026: main 830cb768 against the 16 November audit (18fce327)

Kind: measurement notes on `ari/unbox-notes`. Not a design decision.
Trees: `main` at **830cb768** (all of #81-#95 merged) and the audit's **18fce327**, both built on the same Linux x86-64 box
(Debian trixie, 8 vCPU VM, no hardware PMU) on 17 November, ghc-9.8.2 via `cabal.project.local`. C is `cc -O2` (gcc 14.2.0)
from `tests/bench/{apps,clbg}/c`; the C and `.fpr` benchmark sources are identical in the two trees.

## Method (the audit's, reused)

- Harness: the audit's `docs/perf/2026-11-16-overhead-audit/tools` on `ari/overhead-audit-2026-11-16`. The audit's
  binaries in `/workspace/out/audit-1116` no longer exist, so the C programs and both FP-RISC binary sets were rebuilt
  (`fpr build -o`, `FPR_HOME` = each tree, separate cache). Apps inputs are the same `sales.csv` (15.8 MB) and
  `corpus.txt` (19.3 MB); the fasta inputs were regenerated with the C fasta.
- Instructions: `valgrind --tool=callgrind --dump-instr=yes`, **median of 3**, at most 2 runs at once, at the audit's
  `cgjobs.txt` sizes (nbody 500k, spectralnorm 1000, mandelbrot 1000, binarytrees 16, fannkuchredux 10, fasta 1M,
  knucleotide fasta-1M, revcomp fasta-2.5M; apps at their defaults). Spread across the 3 runs is at most 0.13%.
  Every FP-RISC output at these sizes matches the C output byte for byte.
- Wall time: `tools/timeit3.py.txt`, the audit's `timeit.py` extended to interleave 18fce327, 830cb768 and C in each
  round. Two passes of 5 rounds on an idle box, **median of 10** per cell. CLBG at the `clbg/run.sol` sizes (as the audit).
  stdout md5 matches C for every program in both trees.
- Check: the rebuilt 18fce327 reproduces the audit. Instructions agree to within 0.2% (sim 3.571 G against 3.573 G) and
  CLBG wall comes out at 3.18x against the audit's 3.2x.

## 1. Before and after (ratios against C)


| Apps | wall C | wall 18fce327 | wall 830cb768 | wall change | instr C | instr 18fce327 | instr 830cb768 | instr change |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| sim | 0.033 s | 0.157 s = 4.69x | 0.157 s = **4.69x** | -0.0% | 0.722 G | 3.571 G = 4.95x | 2.887 G = **4.00x** | -19.2% |
| csv | 0.033 s | 0.407 s = 12.50x | 0.385 s = **11.84x** | -5.3% | 0.278 G | 4.447 G = 16.00x | 4.230 G = **15.22x** | -4.9% |
| wordfreq | 0.081 s | 0.799 s = 9.88x | 0.759 s = **9.39x** | -5.0% | 0.475 G | 4.881 G = 10.28x | 4.493 G = **9.47x** | -8.0% |
| wordfreq_mutmap | 0.081 s | 0.353 s = 4.38x | 0.321 s = **3.97x** | -9.2% | 0.475 G | 2.458 G = 5.18x | 2.169 G = **4.57x** | -11.8% |
| treemap | 0.106 s | 0.561 s = 5.28x | 0.557 s = **5.25x** | -0.6% | 0.286 G | 2.086 G = 7.30x | 1.811 G = **6.34x** | -13.2% |
| treemap_mutmap | 0.107 s | 0.309 s = 2.89x | 0.263 s = **2.47x** | -14.6% | 0.286 G | 2.320 G = 8.12x | 1.541 G = **5.39x** | -33.6% |
| records | 0.193 s | 0.376 s = 1.95x | 0.331 s = **1.72x** | -12.0% | 1.146 G | 2.325 G = 2.03x | 2.257 G = **1.97x** | -2.9% |
| format | 0.188 s | 0.466 s = 2.47x | 0.472 s = **2.50x** | +1.3% | 2.565 G | 2.808 G = 1.09x | 2.787 G = **1.09x** | -0.7% |
| **geomean** | | 4.56x | **4.29x** | | | 5.22x | **4.58x** | |

| CLBG | wall C | wall 18fce327 | wall 830cb768 | wall change | instr C | instr 18fce327 | instr 830cb768 | instr change |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| binarytrees | 0.933 s | 0.648 s = 0.69x | 0.677 s = **0.73x** | +4.5% | 3.409 G | 2.059 G = 0.60x | 1.969 G = **0.58x** | -4.3% |
| fannkuchredux | 0.177 s | 0.790 s = 4.45x | 0.543 s = **3.06x** | -31.2% | 1.038 G | 10.809 G = 10.41x | 9.155 G = **8.82x** | -15.3% |
| nbody | 0.195 s | 0.957 s = 4.91x | 0.666 s = **3.42x** | -30.4% | 0.300 G | 2.018 G = 6.72x | 1.552 G = **5.17x** | -23.1% |
| spectralnorm | 0.163 s | 0.946 s = 5.79x | 0.653 s = **4.00x** | -30.9% | 0.581 G | 3.933 G = 6.77x | 3.331 G = **5.74x** | -15.3% |
| mandelbrot | 0.856 s | 2.214 s = 2.59x | 1.092 s = **1.28x** | -50.7% | 0.387 G | 1.250 G = 3.23x | 0.821 G = **2.12x** | -34.3% |
| fasta | 0.277 s | 0.524 s = 1.90x | 0.454 s = **1.64x** | -13.4% | 0.356 G | 1.980 G = 5.57x | 1.602 G = **4.50x** | -19.1% |
| knucleotide | 0.210 s | 0.970 s = 4.62x | 0.937 s = **4.46x** | -3.4% | 1.182 G | 9.620 G = 8.14x | 9.598 G = **8.12x** | -0.2% |
| revcomp | 0.044 s | 0.233 s = 5.32x | 0.216 s = **4.94x** | -7.2% | 0.414 G | 2.709 G = 6.54x | 2.533 G = **6.12x** | -6.5% |
| **geomean** | | 3.18x | **2.47x** | | | 4.78x | **4.05x** | |

Headline: **CLBG wall 3.18x -> 2.47x C** (geomean), **CLBG instructions 4.78x -> 4.05x**, **apps instructions
5.22x -> 4.58x**, **apps wall 4.56x -> 4.29x**. The same-day 18fce327 apps wall geomean is 4.56x, not the audit's 5.1x:
the same 18fce327 binaries gave lower ratios today for records (1.95x against 3.4x), treemap (5.3x against 6.8x) and
format (2.5x against 2.9x). The cause was not investigated, so compare apps wall only within this table.

Notes on the table:

- The float-heavy CLBG programs moved most in wall time: mandelbrot 2.6x -> 1.28x, nbody 4.9x -> 3.4x,
  spectralnorm 5.8x -> 4.0x, fannkuchredux 4.5x -> 3.1x.
- treemap_mutmap -33.6% instructions: #95 alone measured -30.6% on this benchmark when it was opened.
- sim's wall did not move although its instructions fell 19%: it runs for 0.16 s and the new tree's spread over the
  10 runs is 17%, so this is noise-limited. treemap and format are also within their spread (14-19%).
- binarytrees is the one wall regression: +4.5% (0.648 s -> 0.677 s, spreads 9% / 5%) while its instructions fell 4.3%.
  Not investigated; it is still faster than C.
- knucleotide (-0.2%) and format (-0.7%) barely moved: they are dominated by runtime C code (section 2).

## 2. Where the remaining instructions go (830cb768, callgrind run 1, self cost by symbol)

Share of each program's instructions. `gen` is compiled FP-RISC code; the last four columns break part of `gen`
down with the audit's regex classifier (`classify.py`), so they are approximate. `alloc` = fpr_alloc, alloc_in_size,
fpr_in_heap, fpr_layout_fields, vdir_alloc, free_block, vfree, fpr_alloc_bulk/object_bulk, fpr_free. `strings` =
g_strCompare, strcat, g_substr, fpr_mkstr, g_strJoin. `MutMap` = mm_*, g_mutmap*. `sort/apply` = g_sortListWith,
fpr_apply*. `regioncopy` = kp_reaches/kp_dup (the copy-out size walk at region close). `vec` = h_* (Vec.pack, dup).
`shlib` = code outside the binary (libc, ld.so).

| program | total G | gen | alloc | strings | MutMap | sort/apply | regioncopy | vec | shlib | otherrt | gen spill/frame | gen tag/untag | gen overflow | gen fuel |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| sim | 2.888 | 98.6 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 1.3 | 0.0 | 12.5 | 4.2 | 1.4 |
| csv | 4.232 | 67.6 | 10.4 | 15.2 | 0.0 | 0.0 | 1.6 | 0.0 | 0.2 | 5.0 | 9.7 | 5.5 | 0.7 | 2.6 |
| wordfreq | 4.493 | 64.7 | 7.0 | 22.0 | 0.0 | 0.5 | 3.2 | 0.0 | 0.0 | 2.6 | 12.3 | 4.2 | 0.2 | 2.7 |
| wordfreq_mutmap | 2.168 | 40.9 | 14.9 | 6.0 | 24.9 | 3.6 | 6.3 | 0.0 | 0.0 | 3.3 | 2.5 | 3.4 | 0.3 | 1.8 |
| format | 2.787 | 18.9 | 24.2 | 31.9 | 0.0 | 0.0 | 7.2 | 0.0 | 5.3 | 12.5 | 1.4 | 0.9 | 1.1 | 0.6 |
| records | 2.258 | 63.4 | 8.7 | 0.0 | 0.0 | 22.5 | 3.0 | 0.0 | 0.1 | 2.5 | 5.5 | 4.0 | 1.2 | 2.2 |
| treemap | 1.811 | 91.8 | 2.0 | 0.0 | 0.0 | 0.0 | 3.1 | 0.0 | 0.0 | 3.1 | 11.2 | 11.4 | 2.1 | 1.3 |
| treemap_mutmap | 1.542 | 57.2 | 15.1 | 0.0 | 13.4 | 12.7 | 0.0 | 0.0 | 0.0 | 1.5 | 10.2 | 3.6 | 0.9 | 1.2 |
| binarytrees | 1.969 | 96.1 | 1.0 | 0.0 | 0.0 | 0.0 | 1.3 | 0.0 | 0.0 | 1.6 | 13.7 | 6.1 | 1.5 | 3.1 |
| fannkuchredux | 9.155 | 73.6 | 19.9 | 0.0 | 0.0 | 0.0 | 0.0 | 3.8 | 1.3 | 1.3 | 7.5 | 6.0 | 0.5 | 1.5 |
| nbody | 1.552 | 99.3 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.7 | 5.4 | 0.0 | 1.6 | 1.2 |
| spectralnorm | 3.331 | 99.1 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.9 | 2.4 | 4.8 | 9.6 | 1.2 |
| mandelbrot | 0.821 | 99.1 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.1 | 0.0 | 0.7 | 2.7 | 1.2 | 0.5 | 3.5 |
| fasta | 1.603 | 90.4 | 1.6 | 0.1 | 0.0 | 0.0 | 0.0 | 4.0 | 2.3 | 1.6 | 5.6 | 7.8 | 3.0 | 2.1 |
| knucleotide | 9.600 | 35.2 | 0.8 | 2.8 | 47.6 | 10.5 | 0.2 | 0.0 | 1.5 | 1.4 | 2.6 | 3.0 | 1.8 | 1.0 |
| revcomp | 2.533 | 77.3 | 5.4 | 1.7 | 0.0 | 0.0 | 1.0 | 7.9 | 4.2 | 2.6 | 5.0 | 6.7 | 1.1 | 2.2 |

Top remaining buckets:

1. **Compiled-code frames and closure bodies.** The spill/frame class alone is 9.7-13.7% of csv, wordfreq, treemap,
   treemap_mutmap and binarytrees. The comparator lambdas themselves are the biggest single symbols in the sort-heavy
   apps: `cmp` is 46.5% of records, `byKey` + `int` are 41.7% of treemap_mutmap. Each call pays a full frame, stack
   check and fuel tick; register allocation (not dispatch, which #95 already cut to about 8 instructions) is what is left.
2. **Allocator.** 24.2% of format, 19.9% of fannkuchredux, 15.1% of treemap_mutmap, 14.9% of wordfreq_mutmap,
   10.4% of csv, 8.7% of records, 7.0% of wordfreq.
3. **String runtime.** 31.9% of format (strcat 29.2%), 22.0% of wordfreq (g_strCompare 19.4%), 15.2% of csv
   (g_strCompare 9.6%).
4. **MutMap runtime.** 47.6% of knucleotide (g_mutmapInsertWith 18.6%, mm_find 17.7%, mm_key_hash 10.6%),
   24.9% of wordfreq_mutmap (mm_str_hash 12.1%), 13.4% of treemap_mutmap.
5. **C-side sort and apply.** 22.5% of records and 12.7% of treemap_mutmap (g_sortListWith), 10.5% of knucleotide
   (fpr_apply2 from the insertWith combiner).

Smaller but visible: tag/untag is still 12.5% of sim and 11.4% of treemap (Int fields stay tagged by decision);
overflow checks are 9.6% of spectralnorm; the region-close copy walk (kp_reaches) is 7.2% of format and 6.3% of
wordfreq_mutmap.

## 3. CI on main 830cb768

The `ci` push run for 830cb768 (https://github.com/hyperswine/fprisc/actions/runs/44025315550) succeeded: jobs
`sol-native` and `sol-checks` both green (started 16:36 AEDT, finished 16:52 AEDT on 17 November). The scheduled
nightly has not yet run on 830cb768. The last three nightlies (14-16 November; the 16 November one at 028377a4) failed
on the known `loopcalls`/`vecinline` `no_reuse` config-differential mismatches.

## Caveats

- No hardware counters on this VM: instruction counts are exact (callgrind), but the cycle cost of each bucket is not
  measured. Bucket classes inside compiled code come from a regex heuristic.
- Wall times under 0.2 s (sim, csv's C, revcomp) have 4-17% spread; the C side of treemap and wordfreq_mutmap had
  32-42% spread from a few outliers, which the median absorbs.
- CLBG instruction counts use the reduced callgrind sizes while wall uses the `run.sol` sizes, as in the audit.
- `wordfreq_mutmap` and `treemap_mutmap` are compared against the same C programs as `wordfreq` and `treemap`.

Raw data: `docs/perf/2026-11-17-remeasure/raw`. Helpers (`.py.txt`, `.sh.txt`, not run from the repo):
`docs/perf/2026-11-17-remeasure/tools`.
