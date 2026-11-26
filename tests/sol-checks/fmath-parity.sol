# Float maths: native (runtime/runtime.c) and Sol (sol-vm/Sol/FMath.hs) give
# the same IEEE bits for sin, cos, tan, atan, atan2, asin, acos, exp, log,
# log2 and pow over 2001 inputs each (core spec Q6). The runtime is compiled
# without fused multiply-add contraction, so this also holds across targets.
H = use "helpers".
main : unsafe Unit -> Unit.
main u = root = H.root Unit; work = tempDir "fpr-fmath";
  env = [("FPR_HOME",root),("XDG_CACHE_HOME","{work}/cache")];
  ProcessResult bc bo be = H.call ["{root}/fpr","build","{root}/tests/fmath/parity.fpr","-o","{work}/parity"] env 600000;
  _ = (if bc != 0 then error "fmath: native build failed\n{bo}{be}" else Unit);
  ProcessResult nc no ne = H.call ["{work}/parity"] env 120000;
  ProcessResult sc so se = H.call ["{root}/fpr","sol","{root}/tests/fmath/parity.sol"] env 300000;
  _ = (if nc != 0 or sc != 0 then error "fmath: a run failed\n{ne}{se}" else Unit);
  nl = Str.lines no; sl = Str.lines so;
  _ = (if List.len nl != 2001 then error "fmath: native printed {List.len nl} rows" else Unit);
  diff = List.filter (fn p -> (a, c) = p; a != c) (List.zip nl sl);
  if diff == [] and List.len sl == 2001 then print "fmath parity: 12 functions x 2001 inputs, native and Sol bit-identical PASS"
  else error "fmath: {List.len diff} of 2001 rows differ; first: {List.take 1 diff}".
>! main Unit.
