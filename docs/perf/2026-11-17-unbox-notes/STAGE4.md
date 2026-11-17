# Stage 4 (monomorphization of small hot functions): headroom measurement
(recreated after the 12:08 box reboot; numbers from callgrind r1 runs made 12:01-12:05: us3b 3d1f8974 for
sim/nbody/mandelbrot/spectralnorm/treemap/csv/wordfreq/fannkuchredux, us3m 26c5c459 for the other 8)

- `fpr compile --remarks=all` on all 16 benches: only generic-call / inline / region (+1 not-fused) remarks;
  no declined type specialization reported anywhere.
- Every compiled hot function is already monomorphic or a C2 `$typed.mono…`/`$worker` clone. Remaining cost is
  runtime C: g_strCompare (19% wordfreq, 9.6% csv), fpr_alloc, strcat (27% format), h_pack, sortListWith,
  mm_find / mm_str_hash / mm_key_hash.
- Closure dispatch (fpr_apply*/callf self cost) is 0.00% in 13/16 benches. Only where a C prim calls a user closure:
  treemap_mutmap 59.88% (apply2 25.39, applyN 21.80, callf 12.69; g_sortListWith via MutMap.freeze -> sortWith (byKey cmp), 7.23M compares),
  knucleotide 21.32% (apply2, from g_mutmapInsertWith, 34.7M calls), wordfreq_mutmap 5.30% (apply2, g_mutmapInsertWith).
  callgrind charges tail-jumped callee bodies to the dispatcher, so these are upper bounds.
  In treemap_mutmap fpr_apply2 misses its exact-arity fast paths (apply2 -> applyN -> callf per compare).
- Conclusion: existing C2 specialization already covers the hot fpr-side cases; no headroom for monomorphizing small
  fpr functions. Stage 4 stopped, no tables built. Real headroom is C-prim callback dispatch (separate item).
