# Unboxing (C6) notes, 2026-11-17

Two findings from the stage 3/4 work that are not in a PR. Raw data, repro programs and the
microbenchmarks are in `docs/perf/2026-11-17-unbox-notes/`.

## Stage 4: monomorphizing small hot functions has no headroom

Measured with callgrind on the 16 benchmarks (3d1f8974 for sim, nbody, mandelbrot, spectralnorm,
treemap, csv, wordfreq, fannkuchredux; 26c5c459 for the other 8), plus `fpr compile --remarks=all`.

- `--remarks=all` reports no declined type specialization in any benchmark; the remarks are only
  generic-call, inline and region (plus one not-fused).
- Every hot compiled function is already monomorphic or a C2 `$typed.mono…` / `$worker` clone.
  The remaining cost is in runtime C: `g_strCompare` (19% of wordfreq, 9.6% of csv), `fpr_alloc`,
  `strcat` (27% of format), `h_pack`, `sortListWith`, `mm_find` / `mm_str_hash` / `mm_key_hash`.
- Closure dispatch (`fpr_apply*` / `callf` self cost) is 0.00% in 13 of 16 benchmarks. It shows up
  only where a C primitive calls back into a user closure:
  - treemap_mutmap 59.88% (apply2 25.39, applyN 21.80, callf 12.69), from `g_sortListWith` via
    `MutMap.freeze` -> `sortWith (byKey cmp)`, 7.23M compares. `fpr_apply2` misses its exact-arity
    fast paths here (apply2 -> applyN -> callf per compare).
  - knucleotide 21.32% (apply2 from `g_mutmapInsertWith`, 34.7M calls).
  - wordfreq_mutmap 5.30% (apply2 from `g_mutmapInsertWith`).
  callgrind charges tail-jumped callee bodies to the dispatcher, so these are upper bounds.

Conclusion: the existing C2 specialization already covers the hot fpr-side cases, so stage 4 was
stopped without building anything. The real headroom is the C-primitive callback dispatch
(sort comparators, `insertWith` combiners), which is a separate item.

## MutMap `mm_cap_for` overflow

Repro programs: `docs/perf/2026-11-17-unbox-notes/cap.fpr` and `cap2.fpr` (run on the
`ari/unbox-walkers` compiler, 26c5c459).

- `MutMap.withCapacity 1152921504606846976` (2^60): `mm_cap_for` rounds to cap 2^61, which passes
  the `cap > (uw)-1 >> 3` guard. `mm_cols` then computes `ncap * sizeof(uw)` = 2^64, which wraps to
  0, so `fpr_alloc_bulk(0)` succeeds and `mm_clear` writes 2^61 slots past it. The process is
  OOM-killed (dmesg anon-rss 12,149,504 kB); "reserved" is never printed.
- `MutMap.withCapacity 4611686018427387903` (2^62 - 1): clean panic
  `[ERR] MutMap: capacity out of range`, exit 1.

So the guard misses the range where the rounded capacity times the 8-byte slot size overflows:
the size check should be done on `ncap * sizeof(uw)` (or the guard tightened to `>> 4` to cover the
rounding), so a too-large capacity gives the clean error instead of an OOM kill. Not fixed yet.
