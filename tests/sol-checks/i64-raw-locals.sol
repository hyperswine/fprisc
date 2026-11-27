# C6 stage 3d: I64 +, -, *, and/or/xor and the comparisons run inline on the
# raw 64-bit words, an I64 box made in the function answers its own bits, and
# an I64 loop value is carried raw. The program wraps at INT64_MAX/MIN, mixes
# Int and I64 loop values, exits loops through boxed results, and still sends
# / and rem to their C entries (truncating today; D9's floored rules are a
# separate change). The answers were computed independently (Python, 64-bit
# two's complement) and match the boxed C-entry build before this change.
H = use "helpers".
prog = 
  "profile base.\n" +
  "mx : Unit -> I64.\n" +
  "mx u = I64.shl (I64.trunc 1) 63 - I64.trunc 1.\n" +
  "mn : Unit -> I64.\n" +
  "mn u = I64.shl (I64.trunc 1) 63.\n" +
  "acc : unsafe Int -> I64 -> I64 -> I64.\n" +
  "acc k s step = if k == 0 then s else acc (k - 1) (s * step + I64.trunc k) step.\n" +
  "sumTo : unsafe Int -> I64 -> I64.\n" +
  "sumTo k s = if k == 0 then s else (if k % 3 == 0 then sumTo (k - 1) (s - I64.trunc k) else sumTo (k - 1) (s + I64.trunc k)).\n" +
  "bits : unsafe Int -> I64 -> I64.\n" +
  "bits k s = if k == 0 then s else bits (k - 1) (I64.xor (I64.or (I64.and s (I64.trunc 1048575)) (I64.trunc (k * 4096))) (s * I64.trunc 31)).\n" +
  "count : unsafe Int -> I64 -> I64 -> Int -> Int.\n" +
  "count k lim s n = if k == 0 then n else (if s < lim then count (k - 1) lim (s + s + I64.trunc 1) (n + 1) else count (k - 1) lim (s + s + I64.trunc 1) n).\n" +
  "main : unsafe Unit -> Unit.\n" +
  "main u =\n" +
  "  _ = print (mx Unit + I64.trunc 1 == mn Unit);\n" +
  "  _ = print (mn Unit - I64.trunc 1 == mx Unit);\n" +
  "  _ = print (mx Unit * I64.trunc 2);\n" +
  "  _ = print (mn Unit * I64.trunc (-1));\n" +
  "  _ = print (mn Unit < mx Unit, mx Unit > mn Unit, mn Unit <= mn Unit, mx Unit >= mx Unit, mn Unit != mx Unit, I64.trunc (-3) < I64.trunc 2);\n" +
  "  _ = print (acc 50 (I64.trunc 7) (I64.trunc 1000003));\n" +
  "  _ = print (sumTo 100000 (I64.trunc 0));\n" +
  "  _ = print (bits 1000 (I64.trunc 12345));\n" +
  "  _ = print (count 70 (I64.trunc 1000000) (I64.trunc 0) 0);\n" +
  "  print (I64.trunc (-7) / I64.trunc 2, I64.rem (I64.trunc (-7)) (I64.trunc 2)).\n".
want =
  "True\n" +
  "True\n" +
  "-2\n" +
  "-9223372036854775808\n" +
  "(True, True, True, True, True, True)\n" +
  "-44292833161408722\n" +
  "1666683334\n" +
  "6463574126994362368\n" +
  "26\n" +
  "(-4, -1)\n".
main : unsafe Unit -> Unit.
main u = root = H.root Unit; work = tempDir "fpr-i64-raw-locals";
  src = "{work}/t.fpr"; asm = "{work}/t.s"; exe = "{work}/t";
  _ = H.writeFile src (unwrap (Utf8.encode prog));
  env = [("FPR_HOME",root),("FPR_PATH",root),("XDG_CACHE_HOME","{work}/cache")];
  ProcessResult code out err = H.call ["{root}/fpr","compile","--system=posix",src,asm] env 240000;
  _ = (if code == 0 then Unit else error "compile exit {code}\n{out}{err}");
  calls = List.filter (fn l -> Str.contains "call" l and (Str.contains "I64_x2e_x2b" l or Str.contains "I64_x2e_x2d" l or Str.contains "I64_x2e_x2a" l or Str.contains "I64_x2e_x3c" l or Str.contains "I64_x2e_x3e" l or Str.contains "I64_x2e_x3d" l or Str.contains "I64_x2exor" l or Str.contains "I64_x2eand" l)) (Str.lines (readPath asm));
  _ = (if calls == [] then Unit else error "I64 operators still call their C entries: {calls}");
  ProcessResult bcode bout berr = H.call ["{root}/fpr","build","-o",exe,src] env 240000;
  _ = (if bcode == 0 then Unit else error "build exit {bcode}\n{bout}{berr}");
  ProcessResult rcode rout rerr = H.call [exe] [] 60000;
  if rcode == 0 and rout == want then print "I64 raw locals: inline operators, wrapping, comparisons, raw loop values PASS"
  else error "run exit {rcode}, want:\n{want}got:\n{rout}{rerr}".
>! main Unit.
