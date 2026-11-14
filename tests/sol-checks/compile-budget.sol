# Compile-time budget (port of the retired tests/check_compile_budget.py): the
# compiler's own allocation on fixed programs, compiled cold with ./fpr and read
# from GHC's runtime statistics (+RTS -t). Allocation is deterministic for a given
# compiler binary and GHC, so it is gated (10% margin); peak residency is gated
# with a 25% margin; wall time is never gated. Baselines are per GHC version and
# platform in tests/compile_budget.json. An environment without a baseline is
# measured and reported, and passes (FPR_REQUIRE_BASELINE=1 makes it fail).
# A program well under budget passes and says so: record the new baseline in
# tests/compile_budget.json in the same commit as the improvement.
H = use "helpers".
J = use "../../sol/lib/json".
programs root = [
  ("hello", "profile base.\nmain = print 42.\n", ""),
  ("std-live", "profile base.\nLive = use \"std/live\".\nmain = print 42.\n", ""),
  ("pos1", "", "{root}/examples/pos1.fpr")].
# value of ("key", "value") in GHC's Haskell-show statistics / --info output
field key text = lead = "(\"{key}\", \""; i = Str.indexOf lead text;
  if i < 0 then error "no {key} in RTS output" else
    rest = Str.slice text (i + Str.len lead) (Str.len text);
    Str.slice rest 0 (Str.find 34 rest).
environment root = ProcessResult code out err = H.call ["{root}/fpr","+RTS","--info","-RTS"] [] 60000;
  if code != 0 then error "fpr +RTS --info: {err}" else "ghc-{field "GHC version" out} {field "Host platform" out}".
inline work name text = p = "{work}/{name}.fpr"; _ = H.write p (unwrap (Utf8.encode text)); p.
job root work (name, text, file) =
  source = if file != "" then file else inline work name text;
  (name, ["{root}/fpr","compile","--system=posix",source,"{work}/{name}.s","+RTS","-t{work}/{name}.rts","--machine-readable","-RTS"],
   root, [("XDG_CACHE_HOME","{work}/cache-{name}"),("FPR_HOME",root),("GHCRTS","")], 900000).
# signed change in tenths of a percent, rendered like "+3.2%"
pct got want = d = (got - want) * 1000 / want; s = if d < 0 then "-" else "+"; a = if d < 0 then 0 - d else d;
  "{s}{a / 10}.{a % 10}%".
baseline budget key name kind = case J.path [key, name, kind] budget |>? J.num of Ok n -> n | Err e -> 0.
judge root work budget key (name, code, out, err) =
  _ = (if code != 0 then error "{name}: exit {code}\n{out}\n{err}" else Unit);
  stats = readPath "{work}/{name}.rts";
  alloc = parseInt (field "bytes allocated" stats); peak = parseInt (field "max_bytes_used" stats);
  wantAlloc = baseline budget key name "allocated_bytes"; wantPeak = baseline budget key name "max_bytes_used";
  line = "{name}: {alloc} bytes allocated, {peak} bytes peak live";
  if wantAlloc == 0 or wantPeak == 0 then _ = print "{line} (no baseline)"; ([name], [])
  else
    _ = print "{line} ({pct alloc wantAlloc} allocation, {pct peak wantPeak} peak vs baseline){if alloc * 10 < wantAlloc * 9 then " -- under budget: record the new baseline" else ""}";
    over = List.append (if alloc * 10 > wantAlloc * 11 then ["{name}: allocation {pct alloc wantAlloc} is over the 10% margin"] else [])
                       (if peak * 4 > wantPeak * 5 then ["{name}: peak residency {pct peak wantPeak} is over the 25% margin"] else []);
    ([], over).
noBaseline key missing = if missing == [] then Unit else
  msg = "compile budget: no baseline for {Str.join ", " missing} on {key}";
  if H.envOr "FPR_REQUIRE_BASELINE" "0" == "1" then error msg else print "{msg} (measured above)".
main : unsafe Unit -> Unit.
main u = root = H.root Unit; work = tempDir "fpr-compile-budget";
  key = environment root;
  budget = unwrap (J.parse (readPath "{root}/tests/compile_budget.json"));
  results = H.parallel 3 (List.map (job root work) (programs root));
  judged = List.map (judge root work budget key) results;
  missing = List.concat (List.map (fn r -> (m, o) = r; m) judged);
  failures = List.concat (List.map (fn r -> (m, o) = r; o) judged);
  _ = noBaseline key missing;
  if failures == [] then print "compile budget: {key} within budget"
  else _ = List.map print failures; error "compile budget FAILED".
> main Unit.
