# C6 stage 3c: a constructor field declared I64 holds the integer's bits, not a
# box, and the raw-field masks carry an I64 mask so every walker leaves it alone.
# The program's values sweep 2^31-spaced addresses over 0x5500.. and 0x7e00..,
# where a Linux heap reservation lies (on this box's 1 TiB span 512 of the 2048
# land inside it), so a copier that followed one as a pointer would corrupt it:
# with the I64 mask withheld the round trip below returns different numbers. The
# list crosses to the last hart and back by copy, is shared by sendArc, survives
# the sweep's copy-out and the in-place rebuild, and prints and compares by value.
H = use "helpers".
prog = "profile base.\n" +
  "# C6 stage 3c: I64 constructor fields hold raw bits. Values sweep the address\n" +
  "# ranges where a Linux heap is mapped, so a walker that followed one as a\n" +
  "# pointer would read the heap; they cross harts by copy and by share, survive\n" +
  "# copy-out and in-place reuse, and print and compare by value.\n" +
  "T = Type (T I64 Int | N).\n" +
  "sweep : unsafe Int -> Int -> List T -> List T.\n" +
  "sweep lo k acc = if k == 0 then acc else sweep lo (k - 1) (T (I64.ofInt (lo + k * 2147483648)) k :: acc).\n" +
  "total : unsafe List T -> I64 -> Int -> (I64, Int).\n" +
  "total xs s n = case xs of\n" +
  "    T a k :: rest -> total rest (s + a) (n + k)\n" +
  "  | _ :: rest -> total rest s n\n" +
  "  | [] -> (s, n).\n" +
  "incr : unsafe List T -> List T.\n" +
  "incr xs = case xs of\n" +
  "    T a k :: rest -> T (a + I64.ofInt 1) k :: incr rest\n" +
  "  | x :: rest -> x :: incr rest\n" +
  "  | [] -> [].\n" +
  "echo : unsafe Int -> a.\n" +
  "echo me = case receive me of\n" +
  "    (who, xs) -> _ = send who (incr xs); echo me.\n" +
  "sharer : unsafe Int -> a.\n" +
  "sharer me =\n" +
  "  m = receive me;\n" +
  "  (who, xs) = m;\n" +
  "  (s, n) = total xs (I64.ofInt 0) 0;\n" +
  "  _ = send who (s, n);\n" +
  "  _ = drop m;\n" +
  "  sharer me.\n" +
  "main : unsafe Unit -> Unit.\n" +
  "main u =\n" +
  "  me = myself 0;\n" +
  "  far = spawnOn (Sys.harts Unit - 1) echo;\n" +
  "  arc = spawnOn (Sys.harts Unit - 1) sharer;\n" +
  "  xs = sweep 138538465099776 1024 (sweep 93458488360960 1024 [N]);\n" +
  "  _ = send far (me, xs);\n" +
  "  ys = receiveFrom me far;\n" +
  "  (s0, n0) = total xs (I64.ofInt 0) 0;\n" +
  "  (s1, n1) = total ys (I64.ofInt 0) 0;\n" +
  "  _ = print (s0, n0);\n" +
  "  _ = print (s1, n1);\n" +
  "  _ = print (incr xs == ys);\n" +
  "  _ = print (xs == ys);\n" +
  "  _ = print (List.take ys 2);\n" +
  "  _ = print (incr (sweep 0 3 [T (I64.shl (I64.ofInt 1) 63) 0]));\n" +
  "  _ = sendArc arc (me, ys);\n" +
  "  shared = receiveFrom me arc;\n" +
  "  print shared.\n".
want = "(239818879180734464, 1049600)\n(239818879180736512, 1049600)\nTrue\nFalse\n" +
  "[T 138540612583425 1, T 138542760067073 2]\n" +
  "[T 2147483649 1, T 4294967297 2, T 6442450945 3, T (-9223372036854775807) 0]\n" +
  "(239818879180736512, 1049600)\n".
quad s = parseInt (Str.trim (Str.replace ".quad" "" s)).
rawRows : unsafe List String -> List Int.
rawRows ls = case ls of
  l :: rest -> if Str.trim l == "fpr_layout_raw:" then (case rest of
      c :: more -> quad c :: List.map quad (List.take (5 * quad c) more)
    | [] -> []) else rawRows rest
| [] -> [].
main : unsafe Unit -> Unit.
main u = root = H.root Unit; work = tempDir "fpr-layout-raw-i64";
  src = "{work}/i64.fpr"; asm = "{work}/i64.s"; exe = "{work}/i64";
  _ = H.write src (unwrap (Utf8.encode prog));
  env = [("FPR_HOME",root),("FPR_PATH",root),("XDG_CACHE_HOME","{work}/cache")];
  ProcessResult code out err = H.call ["{root}/fpr","compile","--system=posix","--prelude={root}/core/prelude.fpr",src,asm] env 240000;
  _ = (if code == 0 then Unit else error "compile exit {code}\n{out}{err}");
  rows = rawRows (Str.lines (readPath asm));
  _ = (if List.drop 3 rows == [1, 0, 1] and List.take 1 rows == [1] then Unit else error "fpr_layout_raw rows: want one row, T with raw mask 1 and I64 mask 1, got {rows}");
  ProcessResult bcode bout berr = H.call ["{root}/fpr","build","-o",exe,src] env 240000;
  _ = (if bcode == 0 then Unit else error "build exit {bcode}\n{bout}{berr}");
  ProcessResult rcode rout rerr = H.call [exe] [] 60000;
  if rcode == 0 and rout == want then print "layout raw I64 fields: rows {rows}, cross-hart copy, share, copy-out, reuse, print and == PASS"
  else error "run exit {rcode}, want:\n{want}got:\n{rout}{rerr}".
> main Unit.
