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
  _ = (if diff == [] and List.len sl == 2001 then Unit else error "fmath: {List.len diff} of 2001 rows differ; first: {List.take 1 diff}");
  # the bit operations: band/bor/bxor and BITSHIFTL/R, BITSET/CLEAR/TEST, BITMASK
  ProcessResult b2 bo2 be2 = H.call ["{root}/fpr","build","{root}/tests/fmath/bits.fpr","-o","{work}/bits"] env 600000;
  _ = (if b2 != 0 then error "bits: native build failed\n{bo2}{be2}" else Unit);
  ProcessResult n2 no2 ne2 = H.call ["{work}/bits"] env 120000;
  ProcessResult s2 so2 se2 = H.call ["{root}/fpr","sol","{root}/tests/fmath/bits.sol"] env 300000;
  _ = (if n2 != 0 or s2 != 0 or no2 != so2 or List.len (Str.lines no2) != 345 then error "bits: native and Sol differ\n{ne2}{se2}" else Unit);
  # strings: lengths and positions in UTF-8 bytes, raw bytes from chr and mid-character slices
  ProcessResult b3 bo3 be3 = H.call ["{root}/fpr","build","{root}/tests/fmath/strings.fpr","-o","{work}/strings"] env 600000;
  _ = (if b3 != 0 then error "strings: native build failed\n{bo3}{be3}" else Unit);
  _ = unwrap (Proc.runNow (ProcessSpec ["sh","-c","\"$1\" > \"$2\"","sh","{work}/strings","{work}/strings-native.out"] "" env "" 120000));
  _ = unwrap (Proc.runNow (ProcessSpec ["sh","-c","\"$1\" sol \"$2\" > \"$3\"","sh","{root}/fpr","{root}/tests/fmath/strings.sol","{work}/strings-sol.out"] "" env "" 300000));
  ProcessResult cc co ce = H.call ["cmp","{work}/strings-native.out","{work}/strings-sol.out"] [] 5000;
  _ = (if cc != 0 then error "strings: native and Sol bytes differ\n{co}{ce}" else Unit);
  print "fmath parity: 12 float functions x 2001 inputs, 345 bit-operation rows and byte-indexed strings, native and Sol identical PASS".
>! main Unit.
