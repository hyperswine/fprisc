# followups checkpoint (items: 1 mutmap-cap, 2 closure-callbacks, 3 unbox-i64-locals)
- 13:40 start. main 2e1873e6; #88 merged; #89/#90/#91 open. worktree /workspace/fpr-mmcap on ari/mutmap-cap-overflow (from origin/main)
- 13:55 item1 fix in runtime/vec.c (COL_CAP_MAX; mm_cap_for check bound on doubled cap; mm_cols/col_grow/h_range/sortWith guards). built fpr-mmcap. c60/c62 -> clean MutMap panic exit1; c59 -> heap exhausted panic exit1; Vec.range 0 2^61 -> Vec capacity panic. building fpr-fumain (origin/main 2e1873e6 baseline) log out/build-fumain.log
- 14:05 item1 commit pushed ari/mutmap-cap-overflow (93f84a32); sol check capacity-overflow PASS (note: Sol lexer quirk: a top-level name 'cases' fails to parse; renamed)
- 14:15 fpr-fumain built. running oh2/bench.sh fm (main) and fmm (item1) -> oh2/bench-fm*.log; tests.sh mm running (out/fu/*-mm.log)
- 14:35 item2 measured on main (fm): treemap_mutmap 2,223.8M Ir; g_sortListWith->apply2 1331M incl over 7.23M compares = 184 Ir/compare (apply2 self 78 incl tail-called byKey, applyN 67, callf 39). x86 generated code has no inline exact-arity apply (A64 has, rev 235). knucleotide 2,413.3M; apply2 self 59/call (8.45M) = F2 fast path + tail-called lambda body (full frame+stack check+fuel ~38 insns): dispatch itself ~8. Plan: port A64 inline apply to X64 (rev 243) + C call2 cache for sort. worktree /workspace/fpr-cb branch ari/closure-callbacks; building (out/build-cb.log)
- 14:42 unit mm 45 PASS; bench fm 16/16, fmm 16/16. started cg fm (main) x3 in two lanes -> oh2/cg-fm-{a,b}-r*.txt
- 14:50 NOTE #88 merged (main now eef6df0d, codegenRev 245). killed cg fm; rebuilding fpr-fumain at eef6df0d. item1/2 branches need merge of origin/main (merge commit); item2 rev -> 246
- 14:55 FOUND: Jack merged #89/#90/#91 at 13:37 into their STACKED bases (ari/unbox-f64, ari/unbox-range, ari/unbox-walkers), not main. main has only #88 (stage 1). Full stack lives at origin/ari/unbox-walkers a2ab41d4. Need to tell parent: stages 2-3c not on main (a PR ari/unbox-walkers->main would land them).
- 15:10 item2 commit d3b8f6c4 pushed ari/closure-callbacks (on main eef6df0d). quick: treemap_mutmap 1,581.7M Ir (old-main 2,223.8M) output OK. Next: bench fm (new main) + fcb, cg x3 both
- 15:15 rebuilt fpr-mmcap (merged main ef22d6ad). started fu/drive1.sh (bench fmm,fcb; cg fm,fcb x3 in 2 lanes; then cg fmm x3; flag oh2/drive1.done) and tests.sh mm
- 14:08 (earlier timestamps in this file were off; box clock is authoritative) item3 worktree /workspace/fpr-i64l branch ari/unbox-i64-locals (from origin/ari/unbox-i64-fields + merge main e84bab9a). Implemented OI64Arith/OI64Bit/OI64Cmp, Lower inline, Simplify forward-i64-bits + dropDeadBoxes, LoopOptimize.carryRawI64; rev 251. building (out/build-i64l.log)
- 14:12 item3 built OK (rev 251). t1 semantics test matches python+baseline. readl: l 126,625,191 x3 (f 354.76M, d 298.99M medians)
- 14:13 item3 commit d27050ee pushed ari/unbox-i64-locals; sol check i64-raw-locals PASS; IR dump confirms raw loop carry in readl total. started tests.sh l

## 14:16 AEDT update
- Item 2: records +7.21% traced to g_sortListWith self 504M->670M (per-compare switch in call2 + struct reloads). Fixed in 51fbb59e: sort merges instantiated per held count (always_inline, local copy of call2_t). Spot: records 2,306,396,184 (fm 2,300,592,659, +0.25%), treemap_mutmap 1,543,967,343. Full bench fcb2 + cg x3 + tests.sh cb running via fu/drive2.sh.
- Item 3: unit-l EXIT 0, runsol-l done; cfgdiff-l running.
- Main compile budget running -> fu/budget-fm.log.
- 14:26 item1 medians fm vs fmm all within +0.4% (noise); budget main hello 1380757968 / std-live 30864827448 / pos1 66762083456 vs mm 1380702000/30863234304/66758280232. Started drive3 (bench l + cg l x3); f baseline = existing cg-f (258d8d63 == item3 merge-parent tree).
- 14:27 resumed after interrupt: still running cfgdiff-mm, runsol-l (tests.sh l), drive2 (cg fcb2 r2), drive3 (bench l). Nothing restarted.
- 14:36 drive2 done: fm vs fcb2 treemap_mutmap -30.55%, records +0.12%, rest within +0.3%; bench fcb2 16/16. tests.sh cb running. bench l 16/16; cg l running.
- 14:45 item1 cfgdiff-mm: 43x10, only loopcalls/vecinline no_reuse mismatches (allowed). item1 DONE testing. runsol-l 22 run 0 unexpected; budget l hello 1382225032 std-live 30895447488 pos1 66815647840. cg l done; old cg-f csv/wordfreq* invalid (288K Ir) -> drive4 re-benches f2 (fpr-unbox-f) + cg x3 + budget-f. mb medians: readl d 298.97M f 355.39M l 126.92M; sendl0 d 1287.21M f 1041.60M l 1042.26M.
- 14:46 item1 PR #93 opened https://github.com/hyperswine/fprisc/pull/93 (head ef22d6ad).
- 14:58 item2 unit 45/45, runsol-cb 19 run 0 unexpected (known allocation-counters/trust), budget cb hello 1382859408 std-live 30904064064 pos1 66878924752. waiting cfgdiff-cb, cfgdiff-l, drive4.
- 15:10 cfgdiff-l only allowed mismatches. f2 vs l all within noise (+0.24% max). budget f hello 1381612592 std-live 30880096448 pos1 66787866592. opening item3 PR.
- 15:11 item3 PR #94 https://github.com/hyperswine/fprisc/pull/94 (head d27050ee, base ari/unbox-i64-fields). waiting cfgdiff-cb.
- 15:18 main now 37613e62 (#92 merged); item2 conflicts on codegenRev. Merged main in separate worktree /workspace/fpr-cb2 (detached) -> 63f526b1, rev 252 (251 taken by #94). building (fu/build-cb2.log). cfgdiff-cb (pre-merge 51fbb59e) still running in fpr-cb.
- 15:31 cfgdiff-cb (51fbb59e): only allowed mismatches. merged tree 63f526b1 built, bench fcb3 16/16, spot cg r1 treemap_mutmap 1541506691 records 2259123395 knucleotide 2415156168. pushed ari/closure-callbacks 63f526b1. tests.sh cb2 (merged tree) running. opening PR.
- 15:31 item2 PR #95 https://github.com/hyperswine/fprisc/pull/95 (head 63f526b1, base main). tests.sh cb2 on merged head still running (fu/*-cb2.log).
