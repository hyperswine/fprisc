# Sol statements: each `>` statement is its own transaction, and `>!` marks
# an immediate one (docs/2026-11-26-SOL-PROGRESSIVE-COMMITS.md). Every case
# writes a small script into its own scratch directory, runs it with
# `./fpr sol`, and checks the exit code, the files left behind and the
# output.
H = use "helpers".
must what ok detail = if ok then Unit else error "statements: {what}\n{detail}".
fresh work name = dir = "{work}/{name}"; _ = unwrap (Proc.runNow (ProcessSpec ["mkdir","-p",dir] "" [] "" 10000)); dir.
put dir file text = H.writeFile "{dir}/{file}" (unwrap (Utf8.encode text)).
# relative paths in a script resolve against its working directory: the case directory
sol root dir file env = unwrap (Proc.runNow (ProcessSpec ["{root}/fpr","sol","{dir}/{file}"] dir (List.append [("FPR_HOME",root)] env) "" 120000)).
count needle text = List.len (Str.split 10 text |> List.filter (fn l -> Str.contains needle l)).
main : unsafe Unit -> Unit.
main u = root = H.root Unit; work = tempDir "fpr-statements";
  # 1. a panic discards its own statement only; later statements never run
  a = fresh work "abort";
  _ = H.writeFile "{a}/txnabort.sol" (unwrap (Utf8.encode (readPath "{root}/tests/txnabort.sol")));
  ProcessResult ac ao ae = sol root a "txnabort.sol" [];
  _ = must "abort: exit should be nonzero" (ac != 0) ae;
  _ = must "abort: statement one committed" (H.isFile "{a}/one.txt") ae;
  _ = must "abort: the panicking statement's write landed" (not (H.isFile "{a}/two.txt")) ae;
  _ = must "abort: a statement after the panic ran" (not (H.isFile "{a}/three.txt")) ae;
  # 2. a transactional statement that reaches an immediate operation is refused before anything runs
  r = fresh work "refuse";
  _ = put r "s.sol" "> writePath \"first.txt\" \"x\".\n> writeNow \"now.txt\" \"y\".\n";
  ProcessResult rc ro re = sol root r "s.sol" [];
  _ = must "refuse: exit should be nonzero" (rc != 0) re;
  _ = must "refuse: diagnostic" (Str.contains "statement 2 (`>`) is a transaction but reaches immediate operation(s) writeNow" re) re;
  _ = must "refuse: nothing may run" (not (H.isFile "{r}/first.txt") and not (H.isFile "{r}/now.txt")) re;
  # 3. a zero-arg main runs as a transactional statement too
  m = fresh work "main";
  _ = put m "s.sol" "main = writeNow \"now.txt\" \"y\".\n";
  ProcessResult mc mo me = sol root m "s.sol" [];
  _ = must "main: refused" (mc != 0 and Str.contains "`main` (run as a transactional statement)" me) me;
  # 4. `>!` runs immediate operations without the escape notices; the next statement sees the result
  i = fresh work "immediate";
  _ = put i "s.sol" ">! writeNow \"now.txt\" \"x\".\n> print (readPath \"now.txt\").\n";
  ProcessResult ic io ie = sol root i "s.sol" [];
  _ = must "immediate: output" (ic == 0 and io == "x\n") "{io}{ie}";
  _ = must "immediate: no realtime notices" (not (Str.contains "REALTIME" ie) and not (Str.contains "NOT atomic" ie)) ie;
  # 5. Script.exit ends the run after its statement commits
  e = fresh work "exit";
  _ = put e "s.sol" "> writePath \"e1.txt\" \"a\".\n> Script.exit 0.\n> writePath \"e2.txt\" \"b\".\n";
  ProcessResult ec eo ee = sol root e "s.sol" [];
  _ = must "exit: status" (ec == 0) ee;
  _ = must "exit: files" (H.isFile "{e}/e1.txt" and not (H.isFile "{e}/e2.txt")) ee;
  # 6. a conflict re-runs only its own statement, and that statement commits once
  t = fresh work "retry";
  _ = put t "c.txt" "x";
  _ = put t "s.sol" "> writePath \"c.txt\" (readPath \"c.txt\" + \"a\").\n> writePath \"d.txt\" (readPath \"c.txt\").\n";
  ProcessResult tc to te = sol root t "s.sol" [("SOL_FORCE_RETRY","1")];
  _ = must "retry: status" (tc == 0) te;
  _ = must "retry: one retry per statement" (count "retrying statement (attempt 2)" te == 2) te;
  _ = must "retry: committed once" (readPath "{t}/c.txt" == "xa" and readPath "{t}/d.txt" == "xa") te;
  # 7. statement results: `x = > e.` binds the committed value for later statements only
  v = fresh work "results";
  _ = put v "s.sol" "total = > List.fold (fn a x -> a + x) 0 (List.range 1 10).\nlabel =\n  > \"sum=\{total\}\".\n> print label.\n";
  ProcessResult vc vo ve = sol root v "s.sol" [];
  _ = must "results: carried" (vc == 0 and vo == "sum=55\n") "{vo}{ve}";
  _ = put v "early.sol" "> print later.\nlater = > 5.\n";
  ProcessResult wc wo we = sol root v "early.sol" [];
  _ = must "results: read before bound is refused" (wc != 0 and Str.contains "reads `later`, which statement 2 binds" we) we;
  _ = put v "def.sol" "n = > 3.\ndouble u = n * 2.\n> print (double Unit).\n";
  ProcessResult dc do de = sol root v "def.sol" [];
  _ = must "results: a definition may not read one" (dc != 0 and Str.contains "`double` reads statement result `n`" de) de;
  _ = put v "c.txt" "1";
  _ = put v "retry.sol" "r = > c = readPath \"c.txt\"; _ = writePath \"c.txt\" (c + \"x\"); Str.len c.\n> writePath \"r.txt\" (str r).\n";
  ProcessResult rc2 ro2 re2 = sol root v "retry.sol" [("SOL_FORCE_RETRY","1")];
  _ = must "results: a retried statement records its result once" (rc2 == 0 and readPath "{v}/c.txt" == "1x" and readPath "{v}/r.txt" == "1") re2;
  _ = put v "dup.sol" "x = > 1.\nx = > 2.\n> print x.\n";
  ProcessResult uc uo ue = sol root v "dup.sol" [];
  _ = must "results: a result name bound twice is refused" (uc != 0 and uo == "" and Str.contains "statement result `x` is bound 2 times" ue) "{uo}{ue}";
  # 8. realtime effects the name check cannot see: the IO constructors behind
  # the Now wrappers are refused, and a closure carried in a result panics
  # before it acts
  b = fresh work "bypass";
  _ = put b "ctor.sol" "> write @leak.txt (NowSet \"x\").\n";
  ProcessResult bc bo be = sol root b "ctor.sol" [];
  _ = must "bypass: an IO constructor is refused" (bc != 0 and Str.contains "reaches immediate operation(s) NowSet" be and not (H.isFile "{b}/leak.txt")) be;
  _ = put b "sh.sol" "> read (NowSh \"echo ran > ran.txt\").\n";
  ProcessResult hc ho he = sol root b "sh.sol" [];
  _ = must "bypass: NowSh is refused" (hc != 0 and Str.contains "reaches immediate operation(s) NowSh" he and not (H.isFile "{b}/ran.txt")) he;
  _ = put b "closure.sol" "w = >! fn p -> writeNow p \"x\".\n> w \"closure.txt\".\n";
  ProcessResult cc co ce = sol root b "closure.sol" [];
  _ = must "bypass: a carried closure panics before acting" (cc != 0 and Str.contains "writeNow is an immediate operation inside a transactional" ce and not (H.isFile "{b}/closure.txt")) ce;
  # 9. a run that aborts ends its Child processes: the child would write
  # late.txt after 3 s, and its pipes must not hold the run open
  k = fresh work "child";
  _ = put k "s.sol" ">! c = unwrap (Child.open [\"sh\",\"-c\",\"sleep 3; echo late > late.txt\"]); error \"boom\".\n";
  ProcessResult kc ko ke = sol root k "s.sol" [];
  _ = Sys.sleepUs 4000000;
  _ = must "child: ended with the aborted run" (kc != 0 and not (H.isFile "{k}/late.txt")) ke;
  # 10. the isolation example: visibility inside a statement and across statements
  ProcessResult xc xo xe = H.call ["{root}/fpr","sol","{root}/sol/examples/txn_iso.sol"] [("FPR_HOME",root)] 120000;
  _ = must "txn_iso example" (xc == 0 and Str.endsWith "txn_iso: OK\n" xo) "{xo}{xe}";
  print "statements: per-statement commit and abort, refusal before running, main as a statement, quiet >!, exit, per-statement retry, statement results, escapes past the name check, Child ended on abort, isolation PASS".
>! main Unit.
