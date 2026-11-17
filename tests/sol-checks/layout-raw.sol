# C6 stage 3a: the raw-field masks (fpr_layout_raw). A constructor field declared
# F64 or F32 holds the float's bit pattern, never a pointer; the root image says so
# per (tid, variant), beside the layout table, and the runtime registers it. A type
# variable is not marked, even where it is instantiated at F64. The check reads
# the emitted rows, then runs a program that sends such a cell between actors in a
# FPR_LAYOUT_CHECK build, whose report must name the mask the runtime looked up.
H = use "helpers".
fixture = "profile base.\nP = Type (P F64 Int | Q Int).\nW a = Type (W a F64 F32 a).\n" +
  "echo parent me = case receiveRes me of\n    Ok v -> send parent (Ok v)\n  | Err why -> send parent (Err why).\n" +
  "main =\n  me = myself 0;\n  child = spawn (echo me);\n  w = W 1 0.5 (F32.ofF64 0.25) 2;\n" +
  "  _ = send child (Ok [P 2.5 3, Q 4]);\n  case receiveRes me of\n    Ok [P a b, Q c] -> (case w of W x f g y -> print (F64.toInt (a * 2.0) + b + c + x + y))\n  | _ -> print 0.\n".
quad s = parseInt (Str.trim (Str.replace ".quad" "" s)).
# the count word and the masks of the rows after the fpr_layout_raw label
rawRows : unsafe List String -> List Int.
rawRows ls = case ls of
  l :: rest -> if Str.trim l == "fpr_layout_raw:" then (case rest of
      c :: more -> n = quad c; quad c :: List.map (fn i -> quad (List.fold (fn acc x -> x) "" (List.take (3 * i + 3) more))) (List.range 0 (n - 1))
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
  _ = (if rows == [2, 1, 6] or rows == [2, 6, 1] then Unit else error "fpr_layout_raw rows: want count 2 with masks 1 (P) and 6 (W), got {rows}");
  ProcessResult bcode bout berr = H.call ["{root}/fpr","build","-o",exe,src] (List.append env [("FPR_LAYOUT_CHECK","1"),("FPR_LAYOUT_REPORT","1")]) 240000;
  _ = (if bcode == 0 then Unit else error "build exit {bcode}\n{bout}{berr}");
  ProcessResult rcode rout rerr = H.call [exe] [] 60000;
  text = rout + rerr;
  _ = (if rcode == 0 and Str.contains "15" text then Unit else error "run exit {rcode}, want 15:\n{text}");
  if Str.contains "[layout] raw fields 1" text then print "layout raw masks: rows {rows}, runtime mask 1 PASS"
  else error "the runtime never reported the raw mask of P:\n{text}".
> main Unit.
