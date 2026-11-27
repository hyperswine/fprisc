# Zero-cost pairs 26 and 02 (docs/2026-11-22-RAW-INTS.md, "Branches and
# conversions"). Codegen.RawInts' loop copy:
# 1. pair 26, `both (isSmall i) (isSmall (i / 3))`: both tests are evaluated
#    before the call, so the second one's i / 3 sat before the first test's
#    branch with that test's predicate live across it; the division could not
#    be a test point there and stayed tagged, and so did the band of the
#    quotient. The dump of `loop` now holds a raw division by the literal
#    (`arith! /`, no fit test) and two raw `bit band`.
# 2. loop 02: `F64.ofInt (band n 7)` was the runtime entry on every element;
#    the copy converts the raw word inline (`f64.ofint`).
# 3. The answers are exact: counters that start past the 63-bit small range
#    (bignums) run the original loop and cross into the copy, with floored
#    division and two's-complement band. Expected values computed
#    independently (Python integers and floats).
H = use "helpers".
boolProg =
  "isSmall : Int -> Bool .\n" +
  "isSmall x = band x 255 < 100.\n" +
  "both : Bool -> Bool -> Bool .\n" +
  "both a b = a and b.\n" +
  "loop : unsafe Int -> Int -> Int -> Int .\n" +
  "loop i n acc = if n == 0 then acc else loop (i - 1) (n - 1) (if both (isSmall i) (isSmall (i / 3)) then acc + 1 else acc).\n" +
  "big : Unit -> Int .\n" +
  "big u = 4611686018427387903.\n" +
  "main : unsafe Unit -> Unit .\n" +
  "main u =\n" +
  "  b = big Unit;\n" +
  "  _ = print (loop 1000000 1000000 0);\n" +
  "  _ = print (loop (b + 200) 400 0);\n" +
  "  print (loop (300 - b) 400 0).\n".
boolWant = "187552\n88\n46\n".
floatProg =
  "loop : unsafe F64 -> Int -> F64 .\n" +
  "loop acc n = if n == 0 then acc else loop (acc * 0.5 + F64.ofInt (band n 7)) (n - 1).\n" +
  "sumTo : unsafe F64 -> Int -> Int -> F64 .\n" +
  "sumTo acc i n = if n == 0 then acc else sumTo (acc + F64.ofInt i) (i - 1) (n - 1).\n" +
  "big : Unit -> Int .\n" +
  "big u = 4611686018427387903.\n" +
  "main : unsafe Unit -> Unit .\n" +
  "main u =\n" +
  "  b = big Unit;\n" +
  "  _ = print (F64.toInt (loop 0.0 1000000));\n" +
  "  _ = print (F64.toInt (sumTo 0.0 1000 10));\n" +
  "  print (F64.toInt (sumTo 0.0 (b + 5) 10 * 0.0625) / 1000000000).\n".
floatWant = "3\n9955\n2882303761\n".
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
count : Str -> List Str -> Int.
count needle ls = List.len (List.filter (fn l -> Str.contains needle l) ls).
check : unsafe Str -> Str -> Str -> Str -> Str -> List (Str, Int) -> Int.
check root work label prog want needles =
  src = "{work}/{label}.fpr"; asm = "{work}/{label}.s"; exe = "{work}/{label}";
  _ = H.writeFile src (unwrap (Utf8.encode prog));
  env = [("FPR_HOME",root),("FPR_PATH",root),("XDG_CACHE_HOME","{work}/cache-{label}")];
  ProcessResult code out err = H.call ["{root}/fpr","compile","--system=posix",src,asm] (List.append env [("FPR_TYPED_IR","dump")]) 240000;
  _ = (if code == 0 then Unit else error "{label}: compile exit {code}\n{out}{err}");
  loops = List.filter (fn s -> (n, body) = s; n == "loop") (sections (Str.lines "{out}\n{err}") "" "" []);
  body = (case loops of (n, b) :: _ -> b | Nil -> error "{label}: no `loop` in the typed-IR dump");
  lines = Str.lines body;
  short = List.filter (fn nd -> (needle, least) = nd; count needle lines < least) needles;
  _ = (if short == [] then Unit else error "{label}: `loop` lacks {Str.join ", " (List.map (fn nd -> (needle, least) = nd; "{least} x `{needle}`") short)}:\n{body}");
  ProcessResult bcode bout berr = H.call ["{root}/fpr","build","-o",exe,src] env 240000;
  _ = (if bcode == 0 then Unit else error "{label}: build exit {bcode}\n{bout}{berr}");
  ProcessResult rcode rout rerr = H.call [exe] [] 60000;
  if rcode == 0 and rout == want then List.len needles
  else error "{label}: run exit {rcode}, want:\n{want}got:\n{rout}{rerr}".
main : unsafe Unit -> Unit.
main u = root = H.root Unit; work = tempDir "fpr-raw-int-hotspots";
  a = check root work "boolpred" boolProg boolWant [("arith! / ", 1), ("= bit band ", 2)];
  b = check root work "floats" floatProg floatWant [("f64.ofint ", 1)];
  print "raw-Int hot spots: {a + b} copy shapes (raw literal division, raw band of the quotient, inline F64.ofInt), exact across the small range PASS".
>! main Unit.
