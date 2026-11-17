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
