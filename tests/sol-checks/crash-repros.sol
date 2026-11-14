# Compiler crash regressions (port of the retired
# tests/reliability/check_crash_repros.py): every tests/reliability/crash/*.fpr is
# an ill-formed program that once crashed `fpr check`. Each must end with an
# ordinary diagnostic (exit 1), never a Haskell exception or CallStack.
H = use "helpers".
bad = ["CallStack", "Prelude.", "Exception", "error, called at", "Non-exhaustive", "impossible"].
probe root work name = ProcessResult code out err = H.call ["{root}/fpr","check","{root}/tests/reliability/crash/{name}"] [("FPR_HOME",root),("FPR_PATH",root),("XDG_CACHE_HOME","{work}/cache")] 120000;
  text = out + err;
  ok = code == 1 and not (List.any (fn b -> Str.contains b text) bad) and (Str.contains "TYPE ERRORS" text or Str.contains "unexpected" text);
  if ok then _ = print "PASS {name}"; [] else _ = print "FAIL {name}\n{text}"; [name].
> root = H.root Unit; work = tempDir "fpr-crash";
  names = List.filter (fn n -> Str.endsWith ".fpr" n) (ls "{root}/tests/reliability/crash");
  failed = List.concat (List.map (probe root work) names);
  if names == [] then error "no crash repros found" else if failed == [] then Unit else error "crash repros failed: {failed}".
