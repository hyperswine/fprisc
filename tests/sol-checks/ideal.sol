# The ideal example collection's contracts (port of the contract part of the
# retired examples/ideal/check.py): all eight programs build with --cost and
# the declared bounds of measure, pipeline, todo and transitions are proven;
# transitions prints its reference result; violated preconditions panic by name;
# linear reuse/aliasing, nondecreasing recursion and insufficient bounds are
# refused at compile time. Not ported: the behaviour comparisons of wc, report,
# todo and service (files, terminal input, a live HTTP service).
H = use "helpers".
must what ok detail = if ok then Unit else error "{what}\n{detail}".
judged out = Str.join "\n" (List.filter (fn l -> not (Str.contains "no result-size lemma; annotation is not used" l)) (Str.lines out)).
buildJob root work env name = (name, ["{root}/fpr","build","{root}/examples/ideal/{name}.fpr","-o","{work}/ideal-{name}","--cost"], root, env, 600000).
checkBuild r = (name, code, out, err) = r;
  _ = must "ideal {name}: build exit {code}" (code == 0) (out + err);
  if List.has name ["measure","pipeline","todo","transitions"] then
    must "ideal {name}: bounds not all PROVEN" (Str.contains "PROVEN" (judged out) and not (Str.contains "UNPROVED" (judged out))) out
  else Unit.
writeSrc work name text = path = "{work}/{name}.fpr"; _ = H.write path (unwrap (Utf8.encode text)); path.
# (name, source text, needle that must appear when the build fails)
refusedBuild root work env spec = (name, text, needle) = spec;
  src = writeSrc work name text;
  (name, ["{root}/fpr","build",src,"-o","{work}/{name}"], root, env, 600000).
mutated root module old new = source = readPath "{root}/examples/ideal/{module}.fpr";
  _ = must "examples/ideal/{module}.fpr no longer contains {old}" (Str.contains old source) "";
  Str.replace old new source.
harness root ideal module expr = "profile base.\nM = use \"{ideal}/{module}.fpr\".\nmain = {expr}.\n".
# z is 0, but not a literal: the precondition stays unproved (v1.0 semantics §7
# rule 4: a run-time check that panics). The literal form is refused (rule 2).
opaque root ideal module expr = "profile base.\nM = use \"{ideal}/{module}.fpr\".\nmain = z = List.len []; {expr}.\n".
expectRefused specs r = (name, code, out, err) = r;
  needle = lookupNeedle specs name;
  must "{name}: want a failed build mentioning '{needle}', got exit {code}" (code != 0 and List.all (fn n -> Str.contains n (out + err)) (Str.split 124 needle)) (out + err).
expectPanic : String -> String -> List (String, String) -> (String, Int, String, String) -> Unit.
expectPanic root work env r = (name, code, out, err) = r;
  _ = must "{name}: build exit {code}" (code == 0) (out + err);
  ProcessResult rc ro re = H.call ["{work}/{name}"] env 60000;
  want = if name == "bad-transition" then "precondition violated: addAmount" else "precondition violated:";
  must "{name}: want a panic with '{want}', got exit {rc}" (rc != 0 and Str.contains want (ro + re)) (ro + re).
lookupNeedle : (specs : List (String, String, String) | measure specs) -> String -> String.
lookupNeedle specs name = case specs of
  [] -> ""
| (n, t, k) :: rest -> if n == name then k else lookupNeedle rest name.
main : unsafe Unit -> Unit.
main u = root = H.root Unit; work = tempDir "fpr-ideal"; ideal = "{root}/examples/ideal";
  env = [("FPR_HOME",root),("FPR_PATH",root),("XDG_CACHE_HOME","{work}/cache")];
  slots = H.cpus Unit;
  builds = H.parallel slots (List.map (buildJob root work env) ["wc","report","todo","service","measure","pipeline","buffer","transitions"]);
  _ = List.map checkBuild builds;
  _ = print "eight ideal programs build; their declared bounds are proven";
  ProcessResult tc to te = H.call ["{work}/ideal-transitions"] env 60000;
  _ = must "transitions output" (tc == 0 and to == "transitions: amount=75,7 hist=5 avg=30,0\n") (to + te);
  panics = [("negative-count", opaque root ideal "buffer" "M.build (z - 1)"),
    ("large-count", opaque root ideal "buffer" "M.build (z + 4097)"),
    ("negative-index", opaque root ideal "buffer" "M.peek (z - 1) (M.build 2)"),
    ("bad-transition", opaque root ideal "transitions" "print (M.bump z \{amount = 10, hist = 0\})"),
    ("bad-column", opaque root ideal "wc" "print (M.column z 1)"),
    ("bad-kib", opaque root ideal "report" "print (M.kib (z - 1))"),
    ("bad-selection", opaque root ideal "todo" "print (M.selection (z - 1) 0)"),
    ("bad-fact", opaque root ideal "measure" "print (M.fact (z - 1) 1)"),
    ("bad-digests", opaque root ideal "service" "print (M.digests z \"alpha\")")];
  panicJobs = List.map (fn p -> (n, t) = p; (n, ["{root}/fpr","build",writeSrc work n t,"-o","{work}/{n}"], root, env, 600000)) panics;
  refusals = [
    ("literal-negative-count", harness root ideal "buffer" "M.build (0 - 1)", "which is false here"),
    ("literal-bad-column", harness root ideal "wc" "print (M.column 0 1)", "which is false here"),
    ("owner-reuse", "profile base.\nM = use \"{ideal}/buffer.fpr\".\nmain = s = M.build 10; _ = M.finish s; M.finish s.\n", "linear variable|used 2 time(s)"),
    ("owner-alias", "profile base.\nM = use \"{ideal}/buffer.fpr\".\nmain = s = M.build 10; (x, next) = M.peek 0 s; _ = M.finish s; M.finish next.\n", "linear variable|used 2 time(s)"),
    ("bad-buffer-descent", mutated root "buffer" "buildGo (n - 1)" "buildGo n", "measure does not decrease"),
    ("bad-replay-descent", mutated root "transitions" "replay rest (update" "replay events (update", "measure does not decrease"),
    ("bad-replay-bound", mutated root "transitions" "35 * len events + 35" "1", "OVER"),
    ("bad-bound", mutated root "pipeline" "23 * len xs + 27" "1", "OVER"),
    ("bad-measure", mutated root "measure" "factGo (n - 1)" "factGo n", "measure does not decrease")];
  panicResults = H.parallel slots panicJobs;
  refusedResults = H.parallel slots (List.map (refusedBuild root work env) refusals);
  _ = List.map (expectPanic root work env) panicResults;
  _ = List.map (expectRefused refusals) refusedResults;
  _ = print "literal contract violations, linear reuse/aliasing, broken buffer contracts, nondecreasing replay/build and insufficient replay bounds are refused";
  print "ideal examples: nine violated preconditions panic; insufficient work and nondecreasing recursion are refused".
>! main Unit.
