# C6 stage 3a/3b: the raw-field masks (fpr_layout_raw) and the walkers that read them. A constructor field declared
# F64 or F32 holds the float's bit pattern, never a pointer; the root image says so
# per (tid, variant), with the F32 fields among them, beside the layout table, and the runtime registers it. A type
# variable is not marked, even where it is instantiated at F64. The check reads
# the emitted rows, then runs a program that sends such a cell between actors in a
# FPR_LAYOUT_CHECK build, whose report must name the mask the runtime looked up.
# Then the walkers (3b): an F64 whose bits are 2^40 + 4096, an address in the heap
# on many hosts, crosses a send, prints, and compares; float fields compare as IEEE
# values (0.0 == -0.0, NaN != NaN) and print as floats. Before the masks, printing
# such a value dereferenced the float as a header (a segfault).
H = use "helpers".
fixture = "profile base.\nP = Type (P F64 Int | Q Int).\nW a = Type (W a F64 F32 a).\n" +
  "echo parent me = case receiveRes me of\n    Ok v -> send parent (Ok v)\n  | Err why -> send parent (Err why).\n" +
  "main =\n  me = myself 0;\n  child = spawn (echo me);\n  w = W 1 0.5 (F32.ofF64 0.25) 2;\n" +
  "  _ = send child (Ok [P 2.5 3, Q 4]);\n  case receiveRes me of\n    Ok [P a b, Q c] -> (case w of W x f g y -> print (F64.toInt (a * 2.0) + b + c + x + y))\n  | _ -> print 0.\n".
walk = "profile base.\nP = Type (P F64 Int | Q Int).\nW a = Type (W a F64 F32 a).\n" +
  "echo parent me = case receiveRes me of\n    Ok v -> send parent (Ok v)\n  | Err why -> send parent (Err why).\n" +
  "main =\n  me = myself 0;\n  child = spawn (echo me);\n  big = P (I64.toF64Bits (I64.ofInt 1099511631872)) 7;\n" +
  "  ws = [W 1 (0.0 - 1.5) (F32.ofF64 0.25) 2, W 3 2.0e300 (F32.ofF64 (0.0 - 0.5)) 4];\n" +
  "  _ = send child (Ok (big, ws, [P 2.5 3, Q 4]));\n  case receiveRes me of\n    Ok (b, w2, xs) ->\n" +
  "      _ = print xs;\n      _ = print w2;\n      _ = print (b == big);\n      _ = print (w2 == ws);\n" +
  "      _ = print (P 0.0 1 == P (0.0 - 0.0) 1);\n      print (P (0.0 / 0.0) 1 == P (0.0 / 0.0) 1)\n  | Err why -> print why.\n".
walkWant = "[P 2.5 3, Q 4]\n[W 1 (-1.5) 0.25 2, W 3 2e300 (-0.5) 4]\nTrue\nTrue\nTrue\nFalse\n".
quad s = parseInt (Str.trim (Str.replace ".quad" "" s)).
# the count word, then each row's raw and F32 masks, after the fpr_layout_raw label
rawRows : unsafe List String -> List Int.
rawRows ls = case ls of
  l :: rest -> if Str.trim l == "fpr_layout_raw:" then (case rest of
      c :: more -> n = quad c; nth k = quad (List.fold (fn acc x -> x) "" (List.take k more));
        quad c :: List.concat (List.map (fn i -> [nth (4 * i + 3), nth (4 * i + 4)]) (List.range 0 (n - 1)))
    | [] -> []) else rawRows rest
| [] -> [].
main : unsafe Unit -> Unit.
main u = root = H.root Unit; work = tempDir "fpr-layout-raw";
  src = "{work}/raw.fpr"; asm = "{work}/raw.s"; exe = "{work}/raw";
  _ = H.write src (unwrap (Utf8.encode fixture));
  env = [("FPR_HOME",root),("FPR_PATH",root),("XDG_CACHE_HOME","{work}/cache")];
  ProcessResult code out err = H.call ["{root}/fpr","compile","--system=posix","--prelude={root}/core/prelude.fpr",src,asm] env 240000;
  _ = (if code == 0 then Unit else error "compile exit {code}\n{out}{err}");
  rows = rawRows (Str.lines (readPath asm));
  _ = (if rows == [2, 1, 0, 6, 4] or rows == [2, 6, 4, 1, 0] then Unit else error "fpr_layout_raw rows: want count 2, P with raw mask 1 (no F32) and W with raw mask 6 (F32 mask 4), got {rows}");
  ProcessResult bcode bout berr = H.call ["{root}/fpr","build","-o",exe,src] (List.append env [("FPR_LAYOUT_CHECK","1"),("FPR_LAYOUT_REPORT","1")]) 240000;
  _ = (if bcode == 0 then Unit else error "build exit {bcode}\n{bout}{berr}");
  ProcessResult rcode rout rerr = H.call [exe] [] 60000;
  text = rout + rerr;
  _ = (if rcode == 0 and Str.contains "15" text then Unit else error "run exit {rcode}, want 15:\n{text}");
  _ = (if Str.contains "[layout] raw fields 1" text then Unit else error "the runtime never reported the raw mask of P:\n{text}");
  wsrc = "{work}/walk.fpr"; wexe = "{work}/walk";
  _ = H.write wsrc (unwrap (Utf8.encode walk));
  ProcessResult wb wbo wbe = H.call ["{root}/fpr","build","-o",wexe,wsrc] env 240000;
  _ = (if wb == 0 then Unit else error "walk build exit {wb}\n{wbo}{wbe}");
  ProcessResult wcode wout werr = H.call [wexe] [] 60000;
  if wcode == 0 and wout == walkWant then print "layout raw masks: rows {rows}, runtime mask 1, walkers PASS"
  else error "walk: exit {wcode}, want:\n{walkWant}got:\n{wout}{werr}".
> main Unit.
