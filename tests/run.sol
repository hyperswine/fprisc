# From the repository root: sol tests/run.sol [--jobs N] [--nightly] [--only NAME]
# tests/sol-checks.tsv columns: name, deadline in seconds, Sol implementation, tier.
# Tier "push" runs on every CI run; "nightly" only with --nightly. With --nightly every
# check also sees FPR_CHECK_FULL=1 and runs at its full size.
# tests/sol-checks-known-failures.tsv lists checks that fail on main for a recorded
# reason (name<TAB>reason). Such a check is still run and reported as KNOWN; it fails
# the run only if it starts passing, so the list has to shrink when a fix lands.
# FPR_CHECK_SOL selects the launcher for child Sol checks (default: sol on PATH).
must r = case r of Ok x -> x | Err e -> error "{e}".
rows path = List.filter (fn line -> line != "" and not (Str.startsWith "#" line)) (Str.lines (readPath path)).
parse launcher row = case Str.split 9 row of
  [name, seconds, port, tier] -> (name, parseInt seconds, [launcher,port], tier)
| _ -> error "invalid check row (want name, seconds, sol path, tier): {row}".
known = List.map (fn row -> case Str.split 9 row of name :: _ -> name | [] -> row) (rows "tests/sol-checks-known-failures.tsv").
start env (name, seconds, argv, tier) =
  stage = ProcessSpec argv "" env "" 0;
  pipe = PipelineSpec [stage] (PipeBytes (Bytes.empty Unit)) (PipeCapture 4194304) (PipeCapture 4194304) (seconds * 1000) PipeFail;
  (name, must (Proc.start pipe)).
# Returns 1 when the check's outcome should fail the run.
finish (name, job) = expected = List.has name known; case Proc.wait job of
  Ok (PipelineResult 0 _ out _) -> _ = unwrap (IO.stdout out);
    if expected then _ = print "NOW PASSES {name}: remove it from tests/sol-checks-known-failures.tsv"; 1 else _ = print "PASS {name}"; 0
| Ok (PipelineResult code _ out errs) -> _ = unwrap (IO.stdout out); _ = List.map IO.stderr errs;
    if expected then _ = print "KNOWN FAIL {name} (exit {code}; see tests/sol-checks-known-failures.tsv)"; 0 else _ = print "FAIL {name}: exit {code}"; 1
| Err why -> if expected then _ = print "KNOWN FAIL {name}: {why}"; 0 else _ = print "FAIL {name}: {why}"; 1.
pool : unsafe List (String, String) -> Int -> List (String, Int, List String, String) -> List (String, ProcessJob) -> List Int -> List Int.
pool env slots pending active done = case pending of
  item :: rest -> if slots > 0 then pool env (slots - 1) rest (List.append active [start env item]) done
    else (case active of first :: others -> pool env 1 pending others (finish first :: done) | [] -> error "empty pool")
| [] -> List.append done (List.map finish active).
selected nightly only (name, seconds, argv, tier) =
  if only != "" then name == only else (tier == "push" or nightly).
execute : unsafe Int -> Bool -> String -> Unit.
execute count nightly only =
  _ = (if count < 1 then error "jobs must be positive" else Unit);
  launcher = (case unwrap (Env.get "FPR_CHECK_SOL") of EnvText path -> path | EnvMissing -> "sol");
  listed = List.map (parse launcher) (rows "tests/sol-checks.tsv");
  chosen = List.filter (selected nightly only) listed;
  _ = (if chosen == [] then error "no checks selected" else Unit);
  env = if nightly then [("FPR_CHECK_FULL","1")] else [];
  status = must (Proc.streamNow (ProcessSpec ["make","fpr"] "" [] "" 600000));
  _ = (if status == 0 then Unit else error "build exited {status}");
  bad = List.sum (pool env count chosen [] []);
  total = List.len chosen;
  _ = print "sol checks: {total} run, {bad} unexpected outcomes";
  if bad == 0 then Unit else Script.exit 1.
opts : unsafe Int -> Bool -> String -> List String -> Unit.
opts count nightly only argv = case argv of
  [] -> execute count nightly only
| "--jobs" :: n :: rest -> opts (parseInt n) nightly only rest
| "--nightly" :: rest -> opts count True only rest
| "--only" :: name :: rest -> opts count nightly name rest
| _ -> error "usage: sol tests/run.sol [--jobs N] [--nightly] [--only NAME]".
> opts 1 False "" (args Unit).
