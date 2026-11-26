# Run from tests/bench/e2e: sol run.sol [SESSIONS SALES ...] < /dev/null
# Builds examples/pos1.fpr (FPR selects the compiler) and posdrive, then for every
# (SESSIONS, SALES) pair starts pos1 on a fresh shop log and drives it. Default
# pairs: one cashier making 25, 50 and 200 sales, then eight cashiers making 25 each.
# PORT (default 6791) is the port used. The server runs under /usr/bin/time, so each
# run prints the driver's JSON line, the number of sales in the shop log (it must
# equal SESSIONS * SALES) and the server's wall time, peak memory and, where the
# platform reports them, instructions. SPEC.md says what the workload is.
unsafe program.
B = use "../../../sol/lib/build".
shop = "product FW 500 100000000 flat white\nproduct LB 400 100000000 long black\nproduct CT 900 100000000 cheese toastie\nproduct BR 600 100000000 brownie\nproduct CC 700 100000000 carrot cake\nproduct SW 300 100000000 sparkling water\nstaff ana 1234\ntax 1000\nlowat 3\n".
# $0 = work directory, $1 = port, $2 = sessions, $3 = sales, $4 = time flag
script = "cd \"$0\" || exit 1; rm -rf run; mkdir run; printf '%s' \"$SHOP\" > run/pos; /usr/bin/time \"$4\" ./pos1 --port=\"$1\" --store=\"$0/run/pos\" > run/server.log 2> run/time.log & n=0; until grep -q '^ready' run/server.log 2>/dev/null; do n=$((n+1)); if [ $n -gt 100 ]; then echo 'pos1 did not become ready'; cat run/server.log run/time.log; exit 1; fi; perl -e 'select(undef,undef,undef,0.1)'; done; ./posdrive \"$1\" \"$2\" \"$3\" quit || exit 1; wait; echo \"sales in the shop log: $(grep -c '^sale' run/pos) (expected $(($2*$3)))\"; grep -E ' real |maximum resident|peak memory footprint|instructions retired|Elapsed|Maximum resident' run/time.log; [ \"$(grep -c '^sale' run/pos)\" = \"$(($2*$3))\" ]".
pairs argv = case argv of
    a :: b :: rest -> (a, b) :: pairs rest
  | [] -> []
  | _ -> error "usage: sol run.sol [SESSIONS SALES ...]".
>! chosen = (case args Unit of [] -> [("1","25"),("1","50"),("1","200"),("8","25")] | argv -> pairs argv);
  compiler = B.setting "FPR" "fpr";
  port = B.setting "PORT" "6791";
  here = B.query ["pwd","-P"];
  work = "{here}/bin";
  flag = (if B.query ["uname","-s"] == "Darwin" then "-l" else "-v");
  _ = B.command ["mkdir","-p",work];
  _ = B.command ["cc","-O2","-Wall","-Wextra","-o","{work}/posdrive","posdrive.c"];
  _ = B.inDirectory "{here}/../../.." [] [compiler,"build","examples/pos1.fpr","-o","{work}/pos1"];
  _ = List.map (fn pair -> case pair of (sessions, sales) ->
        _ = print "== {sessions} cashier(s), {sales} sales each";
        B.runWith [("SHOP",shop)] ["sh","-c",script,work,port,sessions,sales,flag]) chosen;
  print "done".
