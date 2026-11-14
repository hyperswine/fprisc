# `fpr stdcheck` (the std proof pass: intervals, measures, WCET terms) over every
# std/*.fpr and tests/reliability/stdcheck/*.fpr (port of the retired
# tests/reliability/stdcheck_std.py). Modules in
# tests/reliability/stdcheck-known-failures.txt are expected to fail; any other
# failure, or a listed module that now passes, fails this check.
H = use "helpers".
stem p = Str.slice p 0 (Str.len p - 4).
fprFiles dir = List.map (fn n -> "{dir}/{n}") (List.filter (fn n -> Str.endsWith ".fpr" n) (ls dir)).
baseName p = case List.rev (Str.split 47 p) of n :: _ -> stem n | [] -> p.
job root work path = (baseName path, ["{root}/fpr","stdcheck",path], root, [("FPR_HOME",root),("FPR_PATH",root),("XDG_CACHE_HOME","{work}/cache")], 300000).
lastLine text = case List.rev (List.filter (fn l -> l != "") (Str.lines (Str.trim text))) of l :: _ -> l | [] -> "".
firstError text = case List.filter (fn l -> Str.startsWith "error" l or Str.contains "<-- signed" l) (Str.lines text) of l :: _ -> l | [] -> lastLine text.
passed r = (n, c, o, e) = r; Str.startsWith "stdcheck: OK" (lastLine (o + e)).
known root = List.concat (List.map (fn row -> if row == "" or Str.startsWith "#" row then [] else case Str.split 9 row of k :: _ -> [k] | [] -> [])
  (Str.lines (readPath "{root}/tests/reliability/stdcheck-known-failures.txt"))).
judge kn r = (n, c, o, e) = r; ok = passed r;
  if not ok and not (List.has n kn) then _ = print "FAIL {n}: {firstError (o + e)}"; 1
  else if ok and List.has n kn then _ = print "NOW PASSES {n}: remove it from tests/reliability/stdcheck-known-failures.txt"; 1
  else 0.
main : unsafe Unit -> Unit.
main u = root = H.root Unit; work = tempDir "fpr-stdcheck";
  mods = List.append (fprFiles "{root}/std") (fprFiles "{root}/tests/reliability/stdcheck");
  results = H.parallel (H.cpus Unit) (List.map (job root work) mods);
  kn = known root;
  bad = List.sum (List.map (judge kn) results);
  ok = List.len (List.filter passed results);
  _ = print "stdcheck: {ok}/{List.len results} modules (std + regressions) OK, {List.len kn} known failures";
  if bad == 0 then Unit else error "stdcheck: {bad} unexpected outcomes".
> main Unit.
