# The standard library golden tests (port of the plain-program part of the
# retired tests/check_std.py): every tests/std/<name>.fpr with a <name>.expected
# is built once with ./fpr and must print exactly its expected output, with the
# same arguments, working directories and environment check_std.py gave it.
# Builds run in parallel; the programs run one at a time (several use sockets,
# timers and actors). clientstate takes minutes to compile, so it runs only with
# FPR_CHECK_FULL=1. Known per-program failures are rows "std-golden:<name>" in
# tests/sol-checks-known-failures.tsv; one of those that passes fails the check.
# Not ported here: the examples/ runs, the PTY terminal app and the websocket app.
H = use "helpers".
# (label, program, arguments, "root" or "tmp" working directory, extra environment)
special = [
  ("store", "store", ["@/store"], "tmp", []),
  ("storewire", "storewire", ["@/store"], "tmp", []),
  ("storeconc-1", "storeconc", ["@/store1"], "tmp", [("FPR_HARTS","1")]),
  ("storeconc-4", "storeconc", ["@/store4"], "tmp", [("FPR_HARTS","4")]),
  ("call-4", "call", [], "root", [("FPR_HARTS","4")]),
  ("call", "call", [], "root", []),
  ("durable", "durable", ["@/durable.kvlog"], "tmp", []),
  ("compact", "compact", [], "tmp", []),
  ("kvwire", "kvwire", [], "tmp", []),
  ("apps", "apps", [], "tmp", [("T16_HOST","from-env")]),
  ("posix", "posix", ["one","two words"], "tmp", [])].
specialNames = List.map (fn c -> (l, n, a, w, e) = c; n) special.
expectedStem p = if Str.endsWith ".expected" p then [Str.slice p 0 (Str.len p - 9)] else [].
plain n = (n, n, [], "root", []).
stdCases root = stems = List.concat (List.map expectedStem (ls "{root}/tests/std"));
  wanted = List.filter (fn s -> s != "clientstate" or H.full Unit) stems;
  List.append (List.map plain (List.filter (fn s -> not (List.has s specialNames)) wanted))
    (List.filter (fn c -> (l, n, a, w, e) = c; List.has n wanted) special).
programs cs = List.fold (fn acc c -> (l, n, a, w, e) = c; if List.has n acc then acc else List.append acc [n]) [] cs.
buildJob root work name = (name, ["{root}/fpr","build","{root}/tests/std/{name}.fpr","-o","{work}/bin/{name}"], root,
  [("FPR_HOME",root),("FPR_PATH",root),("XDG_CACHE_HOME","{work}/cache")], 1800000).
mkdir path = _ = unwrap (Proc.runNow (ProcessSpec ["mkdir","-p",path] "" [] "" 10000)); path.
# The posix program walks a small tree in its working directory.
posixTree dir = _ = mkdir "{dir}/tree/sub/deep";
  _ = H.write "{dir}/tree/a.txt" (unwrap (Utf8.encode "hello\n"));
  _ = H.write "{dir}/tree/sub/b.fpr" (unwrap (Utf8.encode "fn main\n"));
  _ = H.write "{dir}/tree/sub/deep/c d.fpr" (unwrap (Utf8.encode "x\n")); Unit.
tail n s = if Str.len s > n then Str.slice s (Str.len s - n) (Str.len s) else s.
verdict label ok code out err = if ok then _ = print "PASS {label}"; []
  else _ = print "FAIL {label}: exit {code}\n--- stdout (tail)\n{tail 1500 out}\n--- stderr (tail)\n{tail 1500 err}"; [label].
runCase : unsafe String -> String -> List String -> (String, String, List String, String, List (String, String)) -> List String.
runCase root work built (label, name, argv, where, env) =
  if not (List.has name built) then ["{label}: build failed"] else
    dir = if where == "tmp" then mkdir "{work}/run-{label}" else root;
    _ = (if name == "posix" then posixTree dir else Unit);
    full = List.map (fn a -> if Str.startsWith "@/" a then "{dir}/{Str.slice a 2 (Str.len a)}" else a) argv;
    results = H.parallel 1 [(label, "{work}/bin/{name}" :: full, dir, List.append [("FPR_HOME",root),("FPR_PATH",root)] env, 300000)];
    (l, code, out, err) = (case results of [r] -> r | _ -> error "no result");
    want = readPath "{root}/tests/std/{name}.expected";
    verdict label (code == 0 and out == want) code out err.
knownItems root = List.concat (List.map (fn row -> case Str.split 9 row of
    key :: _ -> if Str.startsWith "std-golden:" key then [Str.slice key 11 (Str.len key)] else []
  | [] -> []) (Str.lines (readPath "{root}/tests/sol-checks-known-failures.tsv"))).
okBuild r = (n, code, out, err) = r; code == 0.
nameOf r = (n, code, out, err) = r; n.
buildError r = (n, code, out, err) = r; if code == 0 then Unit else print "BUILD FAILED {n}: exit {code}\n{tail 1500 out}{tail 1500 err}".
main : unsafe Unit -> Unit.
main u = root = H.root Unit; work = tempDir "fpr-std-golden"; _ = mkdir "{work}/bin";
  cs = stdCases root;
  builds = H.parallel (H.cpus Unit) (List.map (buildJob root work) (programs cs));
  _ = List.map buildError builds;
  built = List.map nameOf (List.filter okBuild builds);
  failed = List.concat (List.map (runCase root work built) cs);
  known = knownItems root;
  unexpected = List.filter (fn l -> not (List.has l known)) failed;
  fixed = List.filter (fn k -> not (List.has k failed) and List.has k (List.map (fn c -> (l, n, a, w, e) = c; l) cs)) known;
  _ = List.map (fn l -> print "KNOWN FAIL std-golden:{l}") (List.filter (fn l -> List.has l known) failed);
  _ = List.map (fn l -> print "NOW PASSES std-golden:{l}: remove it from tests/sol-checks-known-failures.tsv") fixed;
  nc = List.len cs; nf = List.len failed;
  _ = print "std golden: {nc} cases, {nf} failed ({List.len unexpected} unexpected), {List.len fixed} known failures now passing";
  if unexpected == [] and fixed == [] then Unit else error "std golden failed".
> main Unit.
