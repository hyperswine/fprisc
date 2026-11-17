# unbox checkpoint (RECREATED 12:20 after box reboot at 12:08 wiped /workspace/out)
Lost: all of /workspace/out (old checkpoint, logs, oh2 scripts, cg data, pr-s3ab.md draft, s4 notes, mutmap repro). Worktrees + pushed branches intact.
State from memory of this run:
- ari/unbox-walkers 26c5c459 (merge of unbox-range, codegenRev 248), pushed. q2 fix 9a2e1a4c. s3m: unit 45, runsol 20/0, budget 1381.18/30871.1/66766.4, bench 16/16. cfgdiff-s3m was running -> lost, rerun.
- ari/unbox-i64-fields 6701f461 (3c d6cfdc7c + test arity fix), pushed. us3c bench 16/16 OK; unit 45/45 (after fix). runsol/cfgdiff/cg lost -> rerun.
- microbench medians (lost files, numbers recorded): sendl walkers 1694.6M -> 3c 1378.3M; readl 239.47M -> 404.97M.
- stage 4 done (see s4/STAGE4.md, recreated). MutMap repro done (recreated in mutmap/).
- 12:25 /opt/tc + valgrind lost in reboot; installed libarchive13t64, valgrind, libc6-dbg from debian debs (apt mirror 500s, curl ok). Rerunning cfgdiff s3m, runsol+cfgdiff s3c, bench d/e (oh2/bench.sh, cg sizes in oh2/cg.sh).
- 12:30 new executor took over. s4/STAGE4.md + mutmap/cap*.fpr are under out/unbox/. cfgdiff s3m (fpr-unbox-d) and runsol+cfgdiff s3c (fpr-unbox-e) running from prior run (started 12:25, pkg-config now present). Killed bench.sh e (BUILDFAIL: e/bin missing). Next: readl investigation, recreate microbench.
- 12:40 recreated mb/readl.fpr, sendl.fpr (out/unbox/mb), built .d (walkers) .e (3c)
- 12:55 readl cause confirmed (mb: readl d 297.66M -> e 466.30M; fpr_alloc 136.5M->266.5M, +2M I64.ofField calls = one extra C box alloc per field read). Fix: inline OMake T_BITS/4 box + OLoad for toField in Lower.hs, worktree /workspace/fpr-unbox-f (branch ari/unbox-i64-fields-wip), diff out/unbox/readl-fix.diff, rev 250
- 13:05 installed pkgconf (dpkg), copied libgit2/libarchive/libcurl -dev files into /usr, stub .pc for private deps in /opt/tc/fprdeps/lib/pkgconfig (export PKG_CONFIG_PATH). cabal store wiped -> cabal update + rebuild deps; building fpr-unbox-f (log out/unbox/build-f.log)
