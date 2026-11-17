# C9 stage 2 / shallow-stack checkpoint (started 2026-11-17 23:29 AEDT)
Jack decisions: (1) stage 2 loop live-range splitting (2) keep platform CC (3) shallow-stack leaf skip default.
PR A loop splitting, PR B shallow-stack default, stacked on ari/regalloc (#97).
- 23:29 start
- 23:37 worktree /workspace/fpr-split branch ari/regalloc-split from d7319d6f; building

## 23:55 AEDT — PR A (b) cold keeping-call splitting coded (uncommitted, /workspace/fpr-split)
- Allocate.hs: AllocConfig.acColdCall (x64: split && keepingCall); forbiddenAt relaxes fixed-use regs at cold calls; prefs puts those regs last;
  walk saves/reloads crossers in fixed-use regs via extra slots (shared per kind) around the call.
- build log out/ra/build-split2.log; bins out/ra/sp2 (16/16 OK); asm out/ra/sp/sp2-*
- cg r1 vs ra3 median (8841b1c9 bins): fannkuch -5.38%, nbody -2.22%, wordfreq -1.14%, records -1.48%, csv -1.05%, spectralnorm +0.18%, total -0.70%
- tools: out/ra/tools/med.py, cmp2.py. NOTE cg-ra3-med.txt / cg-base-med.txt were empty; regenerated with med.py.

## 00:00 AEDT (Nov 18) — PR A feature-complete candidate "sp6" (uncommitted; earlier entry's "23:55" was really ~23:45)
- added: lean tick (Protocol.keepingEntryWith: x64 Tick/CountedTick don't claim rax under split; checkProtocols accepts),
  move hints in scan (copy src/dst already placed, not into soft regs), keep old cand order when split off.
- cg r1 vs ra3 med: total -2.14%; sim -6.82, fannkuch -7.35, fasta -4.40, records -3.53, wordfreq -2.41, nbody -2.22, spectralnorm -2.20, csv -1.86. 16/16 OK.
- next: commit, unit tests, cfgdiff no_x64_split, rev bumps, design note, full tests, before(=ari/regalloc head)/after cg x3.

## 00:08 AEDT — PR A committed+pushed: ari/regalloc-split 842a99db (parent d7319d6f)
- FPR_NO_X64_SPLIT=1 output == stage 1 (fpr-ra) for 16 benches incl. units (out/ra/sp-st1 vs sp-off8, tools/asmstat2.sh)
- A64/RV bare-metal/builtin demo identical except rev string (out/ra/rvcheck2)
- AllocIR PASS (stage 2 tests). Running: drive-spA.sh (lane.lock), drive-st1.sh (lane2.lock, before=fpr-ra), tests-spA.sh (unit, push tier, cfgdiff, budget)
  -> logs unit-spA.log runsol-spA.log cfgdiff-spA.log budget-spA.log, done markers drive-*.done tests-spA.alldone
- PR A not opened yet. Next: PR B worktree /workspace/fpr-shallow on ari/shallow-stack from ari/regalloc-split.

## 00:20 AEDT — PR B in progress (uncommitted, /workspace/fpr-shallow, branch ari/shallow-stack from 842a99db)
- Options.nativeShallowDefault (FPR_NO_SHALLOW_STACK=1 off, cache "-noshallow"); Compile.hs: StackCheckShallow default for x64 && not qapp && not builtin
- Codegen.nativeSelect: shallow only for functions C can't enter (excl. OFunValue refs, symbolNames exps, main, nullary; any fallback => all checked)
- Common.hs: bound doc + shallowReserve=1048/shallowFrameLimit=1024; runtime/actors.c FPR_SHALLOW_RESERVE 1048 + _Static_assert(HEADROOM > reserve)
- built OK (build-shallow2.log). asm sp-sh1 (default) / sp-nosh1 (off): shallow fns 1..10 per bench; tools/shallow_audit.py: 0 suspicious refs in all 16
- PR A drive-spA/st1 done; tests-spA.sh still in cfgdiff at 00:20

## 00:35 AEDT — PR A results + PR B committed
- PR A cg x3 median, before st1 (fpr-ra d7319d6f) vs after spA (842a99db): total 30,663,210,532 -> 30,023,320,555 (-2.09%);
  sim -6.78 fannkuch -7.34 fasta -3.99 records -3.48 wordfreq -2.41 nbody -2.18 spectralnorm -2.11 csv -1.77 treemap -1.32 revcomp -1.17; none worse. 16/16 OK both.
  (cg-st1-med.txt / cg-spA-med.txt). PR A unit 45/45 PASS; push tier 23 run 0 unexpected. cfgdiff+budget still running (tests-spA.sh).
- PR B committed+pushed ari/shallow-stack aa2d0612 (parent 842a99db): no_shallow cfgdiff, codegenRev 256, design note section.
  FPR_NO_SHALLOW_STACK=1 asm == PR A asm (16 benches incl units); rv64 bm/builtin + a64 unchanged (out/ra/rvcheck3).
- Running: drive-shB.sh (lane2), tests-shB.sh (waits for tests-spA.alldone). PRs not opened yet.
