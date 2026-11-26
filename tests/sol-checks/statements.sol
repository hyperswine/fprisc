# Sol statements: each `>` statement is its own transaction, and `>!` marks
# an immediate one (docs/2026-11-26-SOL-PROGRESSIVE-COMMITS.md). Every case
# writes a small script into its own scratch directory, runs it with
# `./fpr sol`, and checks the exit code, the files left behind and the
# output.
H = use "helpers".
must what ok detail = if ok then Unit else error "statements: {what}\n{detail}".
fresh work name = dir = "{work}/{name}"; _ = unwrap (Proc.runNow (ProcessSpec ["mkdir","-p",dir] "" [] "" 10000)); dir.
put dir file text = H.write "{dir}/{file}" (unwrap (Utf8.encode text)).
# relative paths in a script resolve against its working directory: the case directory
sol root dir file env = unwrap (Proc.runNow (ProcessSpec ["{root}/fpr","sol","{dir}/{file}"] dir (List.append [("FPR_HOME",root)] env) "" 120000)).
count needle text = List.len (Str.split 10 text |> List.filter (fn l -> Str.contains needle l)).
main : unsafe Unit -> Unit.
main u = root = H.root Unit; work = tempDir "fpr-statements";
  # 1. a panic discards its own statement only; later statements never run
  a = fresh work "abort";
  _ = H.write "{a}/txnabort.sol" (unwrap (Utf8.encode (readPath "{root}/tests/txnabort.sol")));
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
  # 7. the isolation example: visibility inside a statement and across statements
  ProcessResult xc xo xe = H.call ["{root}/fpr","sol","{root}/sol/examples/txn_iso.sol"] [("FPR_HOME",root)] 120000;
  _ = must "txn_iso example" (xc == 0 and Str.endsWith "txn_iso: OK\n" xo) "{xo}{xe}";
  print "statements: per-statement commit and abort, refusal before running, main as a statement, quiet >!, exit, per-statement retry, isolation PASS".
>! main Unit.
