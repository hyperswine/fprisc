# Report-only compile-time tracking (port of the retired
# tests/reliability/compile_time_tracking.py / check_compile_budget.py --tracked):
# front-end time (`fpr check`, cold cache) for slow-compile programs. vecwide on
# every run; clientstate (minutes) only with FPR_CHECK_FULL=1. Never fails on a
# number; fails only if the measurement itself cannot run.
H = use "helpers".
tracked root = List.append [("vecwide", "{root}/tests/base/vecwide.fpr")]
  (if H.full Unit then [("clientstate", "{root}/tests/std/clientstate.fpr")] else []).
job root work (name, file) = (name, ["{root}/fpr","check",file], root, [("XDG_CACHE_HOME","{work}/check-cache-{name}"),("FPR_HOME",root),("GHCRTS","")], 1800000).
stamp u = ProcessResult code out err = H.call ["date","+%s%N"] [] 5000; parseInt (Str.trim out) / 1000000.
measure : unsafe String -> String -> (String, String) -> Unit.
measure root work item =
  t0 = stamp Unit;
  results = H.parallel 1 [job root work item];
  ms = stamp Unit - t0;
  (name, code, out, err) = (case results of [r] -> r | _ -> error "no result");
  print "tracked {name}: fpr check {ms / 1000}.{(ms % 1000) / 100} s, exit {code}".
main : unsafe Unit -> Unit.
main u = root = H.root Unit; work = tempDir "fpr-compile-tracked";
  _ = (if H.full Unit then Unit else print "tracked clientstate: skipped (nightly only)");
  _ = List.map (measure root work) (tracked root);
  print "compile tracked: report only, not gated".
> main Unit.
