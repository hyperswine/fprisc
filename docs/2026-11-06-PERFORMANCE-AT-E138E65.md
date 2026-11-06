# fprisc performance at e138e65

Date: 2026-11-06. Same-box remeasure of tip (`e138e65`) against the
[26 October baseline](2026-10-26-PERFORMANCE-BASELINE.md) commit (`ed05cd9`),
plus the list/Option/tree comparison from the
[1 November unboxing proposal](2026-11-01-UNBOXING-ZERO-OVERHEAD-PROPOSAL.md)
and Sol startup from the
[29 October analysis](2026-10-29-SOL-STARTUP-ANALYSIS.md).
Host: Linux x86_64, Intel Xeon, 8 vCPU, VM. Compiler built with GHC 9.8.2
(pinned by `cabal.project.freeze`).

Measured 6 Nov 2026 (AEDT) on the shared box: Linux x86_64, Intel Xeon, 8 vCPU, VM.
Tip: `e138e65` (Merge branch 'fix-spawn-result-free', 6 Nov 11:49 AEDT), clean worktree, compiler built with GHC 9.8.2 (pinned by `cabal.project.freeze`).
Old reference: `ed05cd9` (26 Oct 19:18 AEDT, the base of `docs/2026-10-26-PERFORMANCE-BASELINE.md`), built and run on the same box. There are 257 commits between them (164 first-parent).

## Verdict
- No regression since 26 Oct. On the same box, tip is as fast or faster than `ed05cd9` on every bench I reran. The worse fib/C and pingpong ratios came from comparing an M4 run with an x86 VM run, so no bisect was needed.
- Lists are now zero-overhead when fused: `range |> sum` and `map` match the hand loop and beat a C cons list. Unfused shapes (filter, Option, trees, reverse) are still 1.5–5x GHC -O2.
- Byte/string loops remain the worst gap to C (11–31x).
- Sol warm start is about 12 ms (Perl 1.4 ms). The first run with a cache miss dropped from 100 ms to 24 ms.
- The hello compile peak is now 25.4 MB of live memory, under the 32.5 MB limit.

## Same-box check: ed05cd9 vs e138e65 (`tools/bench.py`, fastest of 9, two rounds each)
| Bench | ed05cd9 (ms) | e138e65 (ms) | Change | C -O2 (ms) | fpr/C at tip |
|---|---|---|---|---|---|
| fib | 80.0 / 79.9 | 71.2 / 71.5 | 11% faster | 13.6 | 5.3x |
| pingpong | 1089 / 1130 | 921 / 953 | 15% faster | — | — |
| xpingpong | 1250 / 1200 | 993 / 989 | 19% faster | — | — |
| byteloop | 127.2 / 127.0 | 126.0 / 126.2 | same | 10.9–11.4 | 11.1–11.5x |
| sha | 295.9 / 297.5 | 128.9 / 133.1 | 2.3x faster | 4.1–4.2 | 31x |

`ed05cd9`'s `bench.py` predates `--c`, so the C times come from the tip run (the C sources are the same).
pingpong and xpingpong medians vary by about 10% between runs on this VM.
Conclusion: fib at 5.3x C on x86 against 2.6x on the M4 is a platform effect (call cost on x86, plus VM noise), not a code regression. On this box `ed05cd9` would be about 5.9x.

## Lists and abstractions vs C and GHC (`tests/bench/unbox/measure.py`, 9 interleaved runs, median ms)
"Nov 1" is the table in `docs/2026-11-01-UNBOXING-ZERO-OVERHEAD-PROPOSAL.md` (x86-64).
| Bench | Nov 1 | Now | C | GHC 9.10 -O2 |
|---|---|---|---|---|
| list_sum | 235 | 28.1 (hand loop 28.6) | 49.3 cons / 18.0 array | 2.4 (fused) |
| list_map | 779 | 24.0 | 119.9 | 1.8 (fused) |
| list_filter | 439 | 202.1 | 85.0 | 2.4 (fused) |
| list_fold | 97 | 74.7 | 35.6 | 69.8 |
| length (reverse) | 358 | 187.1 | 71.3 | 123.1 |
| option_loop | 167 | 81.3 | 8.0 | 17.3 |
| tuple_loop | 164 | 125.5 | 62.7 | 3085 (`ref.hs` space leak, ignore) |
| tree_sum | 423 | 382.4 | 92.7 | 160.1 |
| string_scan | 69 | 70.2 | 7.4 | — |
| Sol map/filter/fold | 2786 | 2748 | — | — |
| Sol scalar loop | 1492 | 1474 | — | — |

Turning reuse off (`FPR_NO_REUSE`) moves no row by more than about 4%. Turning specialisation and inlining off costs 2–8x.

## Sol startup (median / 10th percentile ms, 30 runs; same box as the Oct 29 doc)
| Case | Oct 29 | Now |
|---|---|---|
| `fpr sol --version` | 8.6 / 8.3 | 9.2 / 8.6 |
| hello, warm | 11.9 / 11.1 | 12.2 / 11.5 |
| hello, `SOL_CACHE=0` | 95.8 / 93.4 | 50.7 / 47.0 |
| hello, first run (cache miss) | 99.6 / 93.6 | 24.2 / 22.4 |
| peak RSS warm / cache miss | 23 MB | 22 / 37 MB |
| perl / bash / python3 -S | 1.3 / 1.0 / 6.3 | 1.4 / 1.1 / 6.7 |

## Compile budget (`tests/check_compile_budget.py`, GHC 9.8.2 build)
| Program | Allocated | Peak live | Wall |
|---|---|---|---|
| hello | 1.49 GB | 25.4 MB | 1.1 s |
| std-live | 31.3 GB | 346 MB | 26.9 s |
| pos1 | 64.5 GB | 498 MB | 58.4 s |
Peak live is GHC `max_bytes_used`, not process RSS. There is no stored baseline for this compiler and host yet.

## Nov 5 representation work (from `bench/2026-11-05-*-throughput.json`, mostly M4)
| Change | Before → after (ms) | Hand-written |
|---|---|---|
| finite-field-workers | 601 → 268 (2.24x) | 268 |
| unary-returns | 87.5 → 71.0 | 99 |
| base-product-trees | 222 → 193 | 193 |
| base-transport | 18.4 → 15.8 | 16.1 |
| base-variant | 37.2 → 33.4 | 33.0 |
| base-products | 198 → 187 | 187 |
| storage / header / wide-scalar | 5–8% faster | about equal |
| tree-storage, imported/map carriers | within 2% | about equal |
After each change the generic code matches the hand-written version. None regressed.

## Recommended next steps (priority order)
1. **Fuse `filter`, and `filter` composed with `map`/`sum`, all the way to a scalar loop.** It is the largest remaining list gap (202 ms against 24 ms for fused map; about 100x GHC).
2. **Drop per-byte bounds and overflow checks in byte/string loops** where interval facts prove them, and inline `std/digest` across units. byteloop is 11x C, sha 31x, string_scan 9.5x C.
3. **Unbox Option/tuple returns in loops** (extend the Nov 5 worker/return work to `Option`). option_loop is 4.7x GHC and 10x C.
4. **Lower the cost of tree and recursive data** (tree_sum is 2.4x GHC): compact cells or arena reuse for non-tail recursion, and check reuse actually fires (turning it off changes nothing today).
5. **Call cost:** fib is 5.3x C on x86. Profile the prologue and fuel tick on x86 specifically, since the M4 gap was 2.6x.
6. **Sol warm floor:** 9 ms is spent before any Sol work (exec, about 56 shared libraries, RTS). Static linking or a smaller Sol-only binary would get closer to Perl's 1–2 ms.
7. **Housekeeping:** record x86 baselines (`tools/bench.py --record`, `check_compile_budget.py --record`) so future runs on this box gate automatically. Fix or exclude the `workers` fixture in `bench.py`. Add OCaml/MLton references to `tests/bench/unbox` for a fairer ML-family comparison. Rerun the 38-unit qos cold/warm compile timing.

## Not measured
- OCaml, MLton, Racket and Chez (not installed).
- WCET in cycles (bounds are still counted in instructions).
- Hardware runs on simple-risc or the Pi.
- Commit-by-commit bisect (not needed: no regression).

