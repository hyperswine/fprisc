# Privileged builtins (compiler/Compile.hs privilegedBuiltins): nodeGet, nodeWith
# and nodeSet read and store a cell by field number, under schemes the checker
# cannot make safe, so only std/hashmap may name them. Every
# tests/reliability/privileged/*.fpr names one from user code and must be
# refused at compile time with the privileged-builtin diagnostic (exit 1, no
# Haskell exception). The positive controls must still check: std/hashmap
# itself and the hash-trie bench apps that import it.
H = use "helpers".
bad = ["CallStack", "Prelude.", "Exception", "error, called at", "Non-exhaustive", "impossible"].
fpr root work path = H.call ["{root}/fpr","check",path] [("FPR_HOME",root),("FPR_PATH",root),("XDG_CACHE_HOME","{work}/cache")] 120000.
refused root work name = ProcessResult code out err = fpr root work "{root}/tests/reliability/privileged/{name}";
  text = out + err;
  ok = code == 1 and not (List.any (fn b -> Str.contains b text) bad) and Str.contains "PRIVILEGED BUILTINS" text and Str.contains "is a privileged builtin" text;
  if ok then _ = print "PASS refused {name}"; [] else _ = print "FAIL {name}: want a privileged-builtin refusal (exit 1), got exit {code}\n{text}"; [name].
accepted root work rel = ProcessResult code out err = fpr root work "{root}/{rel}";
  if code == 0 then _ = print "PASS accepted {rel}"; [] else _ = print "FAIL {rel}: want exit 0, got exit {code}\n{out}{err}"; [rel].
>! root = H.root Unit; work = tempDir "fpr-privileged";
  names = List.filter (fn n -> Str.endsWith ".fpr" n) (ls "{root}/tests/reliability/privileged");
  controls = ["std/hashmap.fpr", "tests/bench/apps/treemap_hashmap.fpr", "tests/bench/apps/wordfreq_hashmap.fpr", "tests/bench/apps/csv_hashmap.fpr"];
  failed = List.append (List.concat (List.map (refused root work) names)) (List.concat (List.map (accepted root work) controls));
  if names == [] then error "no privileged-builtin repros found" else if failed == [] then Unit else error "privileged builtins: {failed}".
