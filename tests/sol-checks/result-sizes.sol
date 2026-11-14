# Result-size facts before composing source resource equations (port of the
# retired tests/check_result_sizes.py, without its --baseline/--record modes).
# A forged size annotation and a false recursive size invariant are refused;
# substring bounds compose from the actual code, not the annotation text; the
# std list size lemmas prove; byte-string lengths and the minimum-range overflow
# trap are preserved. Every build uses --cost --harts 4 with regions off.
H = use "helpers".
J = use "../../sol/lib/json".
strings size bound = "make : Int -> String | size make <= {size}.\nmake n = substr \"abcdefgh\" 0 n.\ncombine : Int -> String{bound}.\ncombine n = strcat (make n) (make n).\nmain = print (strlen (combine 8)).\n".
duplicate = "duplicate : (xs : List Int | measure xs) -> List Int | size duplicate <= len xs.\nduplicate xs = case xs of [] -> [] | x :: r -> x :: x :: duplicate r.\ncopy : (xs : List Int | measure xs) -> List Int.\ncopy xs = case xs of [] -> [] | x :: r -> x :: copy r.\ncombine : (xs : List Int) -> List Int | alloc combine <= 72 * len xs + 72.\ncombine xs = copy (duplicate xs).\nmain = combine [1,2,3].\n".
library = "L = use \"std/list\".\nmain =\n  _ = print (L.length (L.repeat (-3) 7));\n  _ = print (L.length (L.range 4 2));\n  _ = print (L.length (L.range 4611686018427387903 4611686018427387903));\n  _ = print (L.length (L.map (fn x -> x + 1) [1,2,3]));\n  _ = print (L.length (L.zip [1,2,3] [4,5]));\n  _ = print (L.length (L.unique [1,2,1,3,2]));\n  print (L.length (L.append [1,2] [3,4,5])).\n".
byteString = "literal = \"éλ🙂\\x00\\xff\".\nmain = print (strlen literal).\n".
minTrap = "L = use \"std/list\".\nmain = _ = print \"before\"; print (L.length (L.range (0 - 4611686018427387903 - 1) (0 - 4611686018427387903 - 1))).\n".
must what ok detail = if ok then Unit else error "{what}\n{detail}".
envFor root work probe = List.append [("FPR_HOME",root),("FPR_PATH",root),("XDG_CACHE_HOME","{work}/cache"),("FPR_NO_CALL_REGIONS","1"),("FPR_NO_LOOP_REGIONS","1")]
  (if probe then [("FPR_COST_PROBE","1"),("FPR_COST_REPORT","1")] else []).
build root work name source probe = src = "{work}/{name}.fpr"; exe = "{work}/{name}";
  _ = H.write src (unwrap (Utf8.encode source));
  ProcessResult code out err = H.call ["{root}/fpr","build","--cost",src,"--harts","4","-o",exe] (envFor root work probe) 240000;
  (code, out, err, exe).
costProbe err = case List.filter (fn l -> Str.contains "[fpr cost] " l) (Str.lines err) of
  l :: _ -> i = Str.indexOf "[fpr cost] " l; obj = unwrap (J.parse (Str.slice l (i + 11) (Str.len l)));
    (unwrap (J.get "alloc_requests" obj |>? J.num), unwrap (J.get "alloc_bytes" obj |>? J.num))
| [] -> (0 - 1, 0 - 1).
# Returns the failed item "allocation-counters" when the probe counters differ.
execute root work name exe probe expected = List.concat (List.map (fn h ->
  ProcessResult code out err = H.call [exe] (("FPR_HARTS",h) :: envFor root work probe) 30000;
  _ = must "{name} on {h} harts: exit {code}, stdout {out}" (code == 0 and out == expected) err;
  counters probe name h err) ["1","4"]).
counters probe name h err = if not probe then [] else
  (r, b) = costProbe err;
  if r == 3 and b == 112 then [] else
    _ = print "FAIL allocation-counters: {name} on {h} harts: {r} requests / {b} bytes, want 3 / 112"; ["allocation-counters"].
# "  name@...: declared size ... PROVEN"
sizeProven out name = List.any (fn l -> Str.startsWith "  {name}@" l and Str.contains ": declared size" l and Str.endsWith "PROVEN" l) (Str.lines out).
# "combine: declared alloc <= 80   derived 80   PROVEN", whitespace-insensitive
squash l = Str.join " " (Str.words l).
main : unsafe Unit -> Unit.
main u = root = H.root Unit; work = tempDir "fpr-result-sizes";
  _ = List.map (fn c -> (name, source) = c; (code, out, err, exe) = build root work name source False;
      must "{name} must be refused with COST: ERRORS (exit {code})" (code != 0 and Str.contains "COST: ERRORS" out) (out + err))
    [("forged-string-size", strings 0 " | alloc combine <= 64"), ("false-recursive-invariant", duplicate)];
  _ = print "Forged size annotation and false recursive size invariant refused PASS";
  failed = List.concat (List.map (fn c -> (label, size) = c; (code, out, err, exe) = build root work label (strings size " | alloc combine <= 80") True;
      _ = must "{label}: build exit {code}" (code == 0) (out + err);
      lines = List.map squash (Str.lines out);
      _ = must "{label}: combine alloc <= 80 not derived 80 PROVEN" (List.any (fn l -> Str.contains "combine: declared alloc <= 80 derived 80 PROVEN" l) lines) out;
      _ = must "{label}: make size <= {size} not verified size <= 8" (List.any (fn l -> Str.contains "make: declared size <= {size} verified size <= 8" l) lines) out;
      execute root work label exe True "16\n") [("false-annotation", 0), ("correct-annotation", 8)]);
  _ = print "Actual substring upper bounds compose independently of annotation text on 1/4 harts{if failed == [] then " PASS" else " (allocation counters differ)"}";
  (lc, lout, lerr, lexe) = build root work "library" library False;
  _ = must "library build exit {lc}" (lc == 0) (lout + lerr);
  missing = List.filter (fn n -> not (sizeProven lout n)) ["range","repeat","reverse","append","map","indexedMap","filter","filterMap","take","drop","zip","zipWith","unique","sortWith","sortBy"];
  _ = must "std/list size lemmas not PROVEN: {missing}" (missing == []) lout;
  _ = execute root work "library" lexe False "0\n0\n1\n3\n2\n3\n5\n";
  _ = print "Standard list size proofs, including unique and sorting, and signed endpoints PASS";
  (bc, bout, berr, bexe) = build root work "byte-string" byteString False;
  _ = must "byte-string build exit {bc}" (bc == 0) (bout + berr);
  _ = execute root work "byte-string" bexe False "10\n";
  _ = print "UTF-8 and raw byte payload lengths preserve native outputs PASS";
  (tc, tout, terr, texe) = build root work "minimum-trap" minTrap False;
  _ = must "minimum-trap build exit {tc}" (tc == 0) (tout + terr);
  _ = List.map (fn h -> ProcessResult rc ro re = H.call [texe] (("FPR_HARTS",h) :: envFor root work False) 30000;
      must "minimum-trap on {h} harts: want a nonzero exit, stdout 'before' and an overflow, got exit {rc}" (rc != 0 and ro == "before\n" and Str.contains "overflow" (Str.lower (ro + re))) (ro + re)) ["1","4"];
  _ = print "Partial-correctness size lemmas preserve endpoint overflow and its effect prefix PASS";
  H.settle "result-sizes" root (List.fold (fn acc i -> if List.has i acc then acc else List.append acc [i]) [] failed).
> main Unit.
