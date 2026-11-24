# std List.fold's monomorphised worker gets the raw-Int loop copy
# (docs/2026-11-22-RAW-INTS.md, "Accumulators"). The worker walks a list:
# its element is a cell's field, tested on the way and never "cheap", so
# before the accumulator rule no exact operation in it had two cheap operands
# and Codegen.RawInts left it on tagged words, while the same loop written by
# hand got raw words only because it was inlined into a counting loop.
# 1. The typed-IR dump (FPR_TYPED_IR=dump) of every $typed.mono List.fold
#    worker below holds raw arithmetic (`arith!`) beside its exact operations.
# 2. The answers are exact: sums and products that leave the 63-bit small
#    range promote to bignums (no wrap, no trap) mid-loop and come back, a
#    bignum element or callback capture runs the original loop. Expected
#    values computed independently (Python integers).
H = use "helpers".
stdProg =
  "List = use \"std/list\".\n" +
  "big : Unit -> Int .\n" +
  "big u = 4611686018427387903.\n" +
  "rep : unsafe List Int -> Int -> Int -> Int .\n" +
  "rep xs k acc = if k == 0 then acc else rep xs (k - 1) (acc + List.fold (fn a x -> a + x * k) 0 xs).\n" +
  "scaled : List Int -> Int -> Int .\n" +
  "scaled xs k = List.fold (fn a x -> a + x * k) 0 xs.\n" +
  "total : List Int -> Int .\n" +
  "total xs = List.fold (fn a x -> a + x) 0 xs.\n" +
  "prod : List Int -> Int .\n" +
  "prod xs = List.fold (fn a x -> a * x) 1 xs.\n" +
  "main : unsafe Unit -> Unit .\n" +
  "main u =\n" +
  "  b = big Unit;\n" +
  "  _ = print (rep (List.range 1 1000) 100 0);\n" +
  "  _ = print (total [b, b, 5]);\n" +
  "  _ = print (total [b, 1, 0 - b - 1]);\n" +
  "  _ = print (total [0 - b - 1, 0 - 1, 1]);\n" +
  "  _ = print (scaled [1, 2, 3] b);\n" +
  "  _ = print (scaled (List.range 1 1000) (b / 1000));\n" +
  "  _ = print (scaled [1, b + 1, 2] 1);\n" +
  "  _ = print (scaled [1, 2, 3] (b + 1));\n" +
  "  _ = print (List.sum [b, b, b]);\n" +
  "  _ = print (prod (List.range 1 30));\n" +
  "  print (prod [2, b, 0, 9]).\n".
stdWant =
  "2527525000\n" +
  "9223372036854775811\n" +
  "0\n" +
  "-4611686018427387904\n" +
  "27670116110564327418\n" +
  "2308148852222907193500\n" +
  "4611686018427387907\n" +
  "27670116110564327424\n" +
  "13835058055282163709\n" +
  "265252859812191058636308480000000\n" +
  "0\n".
# the prelude's List.fold (no import; its callback takes the element first)
preludeProg =
  "big : Unit -> Int .\n" +
  "big u = 4611686018427387903.\n" +
  "mk : (n : Int | measure n) -> List Int -> List Int .\n" +
  "mk n acc = if n <= 0 then acc else mk (n - 1) (n :: acc).\n" +
  "rep : unsafe List Int -> Int -> Int -> Int .\n" +
  "rep xs k acc = if k == 0 then acc else rep xs (k - 1) (acc + List.fold (fn x a -> a + x * k) 0 xs).\n" +
  "main : unsafe Unit -> Unit .\n" +
  "main u =\n" +
  "  b = big Unit;\n" +
  "  _ = print (rep (mk 1000 Nil) 100 0);\n" +
  "  _ = print (rep [b, b, 5] 1 0);\n" +
  "  print (rep (mk 1000 Nil) 3 (b - 10)).\n".
preludeWant =
  "2527525000\n" +
  "9223372036854775811\n" +
  "4611686018430390893\n".
marker = "typed-ir: | fn ".
fnName l = rest = Str.slice l (Str.len marker) (Str.len l); i = Str.find 32 rest;
  if i < 0 then rest else Str.slice rest 0 i.
# the dump's functions as (name, body)
sections : unsafe List Str -> Str -> Str -> List (Str, Str) -> List (Str, Str).
sections ls name body acc = case ls of
    Nil -> (name, body) :: acc
  | l :: rest ->
      if Str.startsWith marker l then sections rest (fnName l) "" ((name, body) :: acc)
      else if Str.startsWith "typed-ir: |" l then sections rest name "{body}\n{l}" acc
      else sections rest name body acc.
# a monomorphised list walk with exact Int arithmetic
foldWorker s = (n, body) = s;
  Str.startsWith "$typed.mono." n and Str.contains "vartest " body and Str.contains "arithval " body.
named prefix s = (n, body) = s; Str.startsWith prefix n.
check : unsafe Str -> Str -> Str -> Str -> Str -> List Str -> Int.
check root work label prog want prefixes =
  src = "{work}/{label}.fpr"; asm = "{work}/{label}.s"; exe = "{work}/{label}";
  _ = H.write src (unwrap (Utf8.encode prog));
  env = [("FPR_HOME",root),("FPR_PATH",root),("XDG_CACHE_HOME","{work}/cache-{label}")];
  ProcessResult code out err = H.call ["{root}/fpr","compile","--system=posix",src,asm] (List.append env [("FPR_TYPED_IR","dump")]) 240000;
  _ = (if code == 0 then Unit else error "{label}: compile exit {code}\n{out}{err}");
  workers = List.filter foldWorker (sections (Str.lines "{out}\n{err}") "" "" []);
  missing = List.filter (fn p -> List.filter (named p) workers == []) prefixes;
  _ = (if missing == [] then Unit else error "{label}: no List.fold worker for {Str.join ", " missing} in the typed-IR dump");
  tagged = List.filter (fn s -> (n, body) = s; not (Str.contains "arith! " body)) workers;
  _ = (if tagged == [] then Unit else error "{label}: List.fold workers left on tagged words (no raw copy): {Str.join ", " (List.map (fn s -> (n, body) = s; n) tagged)}");
  ProcessResult bcode bout berr = H.call ["{root}/fpr","build","-o",exe,src] env 240000;
  _ = (if bcode == 0 then Unit else error "{label}: build exit {bcode}\n{bout}{berr}");
  ProcessResult rcode rout rerr = H.call [exe] [] 60000;
  if rcode == 0 and rout == want then List.len workers
  else error "{label}: run exit {rcode}, want:\n{want}got:\n{rout}{rerr}".
main : unsafe Unit -> Unit.
main u = root = H.root Unit; work = tempDir "fpr-list-fold-raw-int";
  a = check root work "std" stdProg stdWant ["$typed.mono.rep.","$typed.mono.scaled.","$typed.mono.total.","$typed.mono.prod."];
  b = check root work "prelude" preludeProg preludeWant ["$typed.mono.rep."];
  print "List.fold raw Ints: {a + b} monomorphised fold workers raw-copied, exact bignum promotion PASS".
> main Unit.
