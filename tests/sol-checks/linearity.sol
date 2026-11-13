H = use "helpers".
programs root = [
  ("inferred_return_duplicate", "\nmakeUnannotated u = Token 7.\nmain = t = makeUnannotated 0; print (consume t, consume t).\n", ""),
  ("inferred_parameter_duplicate", "\nhandleUnannotated t = (consume t, consume t).\nmain = print (handleUnannotated (Token 7)).\n", ""),
  ("inferred_return_discard", "\nmakeUnannotated u = Token 7.\nmain = t = makeUnannotated 0; print \"unexpected execution\".\n", ""),
  ("inferred_tuple_duplicate", "\nmakePair u = (Token 7, 8).\nmain = (t, n) = makePair 0; print (consume t, consume t, n).\n", ""),
  ("inferred_eval_duplicate", "\nmakeUnannotated u = Token 7.\n> t = makeUnannotated 0; print (consume t, consume t).\n", ""),
  ("logic_marks_lost_successor", "\nL = use \"{root}/sol/lib/logic.sol\".\nmain = hp = Vec.new Unit; tr = Vec.new Unit;\n       (hm, tm, _) = L.marks (hp, 0, 0, tr, 0, 0);\n       print (hm, tm).\n", ""),
  ("inferred_composition", "\nmakeUnannotated u = Token 7.\nnextUnannotated owner = Token value = owner; Token (value + 1).\nmain = original = makeUnannotated 0;\n       next = nextUnannotated original;\n       print (consume next).\n", "8\n"),
  ("inferred_tuple_composition", "\nmakePair u = (Token 7, 8).\n> (t, n) = makePair 0; print (consume t + n).\n", "15\n")].
check work compiler (name, body, expected) =
  path = "{work}/{name}.sol";
  base = "Token 1 = Type (Token Int).\nconsume : Token -> Int.\nconsume owner = Token value = owner; value.\n";
  _ = H.write path (unwrap (Utf8.encode (base + body)));
  env = [("SOL_GPU","0"),("SOL_JIT","0"),("SOL_CACHE","0"),("SOL_CACHE_DIR","{work}/cache")];
  ProcessResult code out err = H.call [compiler,"sol",path] env 30000;
  ok = if expected == "" then and (code == 1) (and (out == "") (Str.contains "LINEARITY" err))
       else and (code == 0) (and (out == expected) (err == ""));
  if ok then Unit else error "{name}: exit {code}, stdout={out}, stderr={err}".
> work = tempDir "sol-linearity"; root = H.root Unit;
  compiler = H.envOr "FPR_TEST_BINARY" "{root}/fpr";
  _ = List.map (check work compiler) (programs root);
  print "Sol inferred linearity: 8 checks passed".
