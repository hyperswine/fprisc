# Keyed-list fold rewrite checkpoint (started 2026-11-18 14:45 AEDT)
Ask (t153u): compiler rewrite rules so the inventory journal-load and pos1 void wins happen automatically; Vector 1/append rule if clean; design note.
- 14:45 worktree /workspace/fpr-rw branch ari/keyed-list-fold from main f5a6bd9d; baseline build = /workspace/fpr-l1 (f5a6bd9d clean). building -> out/rw/build-0.log
- 15:20 design: surface rewrite (like OwnedMapFold) + Infer special form `fprKeyedFold# orig (fn t0 -> fast)` typed with site on key type: Int -> fast with mutmapInts, String -> mutmapStrings, else orig (dead branch dropped in applySites). Guard START.F == Nil else orig. Record mode (acc record, field F keyed list, twins __keyedfold with extra kt param returning (m,kt)) and list mode. std/keyedlist.fpr written + smoke-tested (/tmp/kltest.fpr OK).
- rule 2 planned: List.map (fn x -> if P then NEW else x) -> List.mapShared (P effect-free) sharing untouched suffix (pos1 void, inventory live putItem).
- rule 3 planned: List.fold snoc (acc + [e]) -> cons + reverse.
- 16:05 compiler builds; Frontend/KeyedListFold.hs + Frontend/ListRewrites.hs (mapWhere, snoc fold), Infer special form fprKeyedFold# + site keyedfold!, Elaboration.applySites + Desugar/Typed KeyedTable plan. Options FPR_NO_KEYED_LIST_FOLD / FPR_NO_SHARED_MAP / FPR_NO_SNOC_FOLD; FPR_LIST_REWRITE_NOTES=1 prints counts; FPR_KL_DEBUG=1 traces (temporary). Test out/rw/t/keyed.fpr: on == off output, keyed twins present in binary.
- unmodified inventory clone /workspace/fpr-rw-apps/inventory @cba3771; building with rewrites.

## 15:10 (Sydney)
- Inventory clone (cba3771, unmodified) builds with rewrites: notes "2 keyed-list folds, 1 shared maps, 0 snoc folds" (replayed fold, record mode items/id; bulk-rename fold line 591 = runtime-guarded fallback since m.items non-Nil; shared map = putItem replace).
- Root-file dump driver /workspace/fpr-rw-apps/inventory/src/dumproot.fpr (src + dump main; outside repo). on==off md5 on inv-big (eae7c3b9), edge (3000 random ops incl re-adds, dels, bad json, renames), only-dels, empty. Wall dump inv-big: on 0.211s vs off 2.3s (single run, not a measurement).
- pos1 root driver /workspace/fpr-rw-apps/pos1/pos1drv.fpr (examples/pos1.fpr main + drive.fpr body). on/off/base all md5 f59de3c9; shared map fires 1 (markVoid). Wall ~equal.
- NOTE: rewrites apply to root file only -> the module-import drivers (tests/dump.fpr, drv/drive.fpr) would NOT see them; root copies used instead.

## 15:25 (Sydney)
- Removed FPR_KL_DEBUG tracing; fixed GHC warnings in new modules.
- FIX: dropped a redundant capture check (helper args that reuse the helper's param names, e.g. pos1 `markVoid x n who at`) -- substitute is simultaneous + refuses binder clashes. pos1 markVoid now rewritten (pos1: 2 shared maps; earlier "1" was mapP, not markVoid).
- Notes now list sites: FPR_LIST_REWRITE_NOTES=1 prints "<kind> in <function>".
- std/keyedlist restructured for cost precision (map-only inner fns; emit recursion with measure). Contracts PROVEN: empty (2/40), updateIn, mapWhere work/alloc (+size). Lazy forms/toList: no contract (opaque key length / shrinking map) -- like List.map/fold.
- tests/std/keyedlistfold.fpr + .expected (on==off, compares vs plain recursion); cfgdiff config no_list_rewrites + subset entry.
- Micro progs /workspace/out/rw/micro/{keyed,keyeds,shared,snoc}.fpr: base/on/off outputs equal.
- Running: unit + run.sol push + cfgdiff nightly (tests.sh rw), bench.sh rwbase(done)/rwnew, examples notes survey (/tmp/exnotes).

## 15:32 (Sydney) -- resumed after interruption; nothing restarted (pgrep: tests.sh/run.sol, cglane.sh, cglane2.sh all alive)
- Commit 6e3d7ff6 pushed to origin ari/keyed-list-fold (no PR yet; doc still to add).
- unit-tests: EXIT 0. cfgdiff nightly: earlier killed run superseded; current tests.sh run in progress (push tier first).
- 16/16 bench outputs OK with branch compiler; 0 rewrites fire in any bench (notes), binaries differ from main (std/list hash).
- Examples survey (FPR_LIST_REWRITE_NOTES): inventory.fpr keyed fold in replayed + renameCmd (runtime-guarded fallback), shared map in putItem; pos1.fpr shared map in applyVoid + mapP; logbook.fpr shared map in withSess; others none.
- Compile budget (sol run.sol --only compile-budget, no committed baseline for this env -> both PASS): alloc main->branch hello 1,404,029,768->1,404,222,800 (+0.01%), std-live 31,889,939,264->31,945,299,256 (+0.17%), pos1 68,327,139,208->68,688,444,928 (+0.53%); peak live pos1 528.9MB->616.5MB (+16.6%, within 25% gate; runs were concurrent), std-live 301.0->282.6MB.
- Inventory full app workloads functional: import appended tail identical base/on/off; member differs only in salt/hash/at (random).
- callgrind lane (ONE lane, cglane.sh then cglane2.sh for benches) running; r1 so far: inv-member-base 10,185,979,038; inv-import-base 17,284,381,523; pos1-base 3,240,923,041.
