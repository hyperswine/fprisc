# String interpolation pieces (Core.Opt.Pipeline buildStrings, runtime.c
# strcat_pieces): three pieces are one call to $strcat3 and four one call to
# $strcat4, their pieces as arguments (no tuple); five or more stay $strcatT
# of a tuple. Every piece kind renders as str would: negative, 0-9 (the
# static byte strings), wide and small-range-edge Ints, bignums, Strings
# (empty, UTF-8), a tuple, a float, a list, and pieces past the inline bump
# window (a 6000-byte String: fpr_alloc's path). Expected output is main's
# (c16fe82a: $strcatT for three or more pieces), checked against Python
# integers for the bignum lines.
H = use "helpers".
prog =
  "big : Unit -> Int .\n" +
  "big u = 4611686018427387903.\n" +
  "grow : unsafe Str -> Int -> Str .\n" +
  "grow s n = if n == 0 then s else grow \"\{s\}ab\" (n - 1).\n" +
  "three : Int -> Str .\n" +
  "three x = \"k=\{x\};\".\n" +
  "four : Int -> Int -> Str .\n" +
  "four x y = \"\{x\}=\{y\};\".\n" +
  "five : Int -> Str -> Str .\n" +
  "five x s = \"<\{x\}|\{s\}>\".\n" +
  "main : unsafe Unit -> Unit .\n" +
  "main u =\n" +
  "  b = big Unit;\n" +
  "  _ = print (three (0 - 7));\n" +
  "  _ = print (three 0);\n" +
  "  _ = print (three 9);\n" +
  "  _ = print (three 10);\n" +
  "  _ = print (three (0 - 10));\n" +
  "  _ = print (three 123456789);\n" +
  "  _ = print (three b);\n" +
  "  _ = print (three (0 - b - 1));\n" +
  "  _ = print (three (b + 1));\n" +
  "  _ = print (three (b * b));\n" +
  "  _ = print (three (0 - b * 3));\n" +
  "  _ = print (four (0 - 1) 99);\n" +
  "  _ = print (four b (b + b));\n" +
  "  _ = print (five 42 \"\");\n" +
  "  _ = print (five (0 - 5) \"héllo\");\n" +
  "  m = \"mid\";\n" +
  "  _ = print \"s=\{m\}!\";\n" +
  "  _ = print \"t=\{(1, 2)\};\";\n" +
  "  _ = print \"f=\{1.5\};\";\n" +
  "  _ = print \"r=\{[1, 2, 3]\}.\";\n" +
  "  long = grow \"\" 3000;\n" +
  "  _ = print (Str.len \"[\{long\}]\");\n" +
  "  _ = print (Str.len \"\{b\}:\{long\}:\{b\}\");\n" +
  "  print \"a\{1\}b\{2\}c\{3\}d\{4\}e\".\n".
want =
  "k=-7;\n" +
  "k=0;\n" +
  "k=9;\n" +
  "k=10;\n" +
  "k=-10;\n" +
  "k=123456789;\n" +
  "k=4611686018427387903;\n" +
  "k=-4611686018427387904;\n" +
  "k=4611686018427387904;\n" +
  "k=21267647932558653957237540927630737409;\n" +
  "k=-13835058055282163709;\n" +
  "-1=99;\n" +
  "4611686018427387903=9223372036854775806;\n" +
  "<42|>\n" +
  "<-5|héllo>\n" +
  "s=mid!\n" +
  "t=(1, 2);\n" +
  "f=1.5;\n" +
  "r=[1, 2, 3].\n" +
  "6002\n" +
  "6040\n" +
  "a1b2c3d4e\n".
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
# fn `name`'s body calls `needle` and none of `others`
shape : List (Str, Str) -> (Str, Str, List Str) -> Int.
shape secs want = (name, needle, others) = want;
  found = List.filter (fn s -> (n, b) = s; n == name) secs;
  body = (case found of (n, b) :: _ -> b | Nil -> error "no `{name}` in the typed-IR dump");
  bad = List.filter (fn o -> Str.contains o body) others;
  if Str.contains needle body and bad == [] then 1
  else error "`{name}` should call `{needle}` and not {Str.join ", " bad}:\n{body}".
main : unsafe Unit -> Unit.
main u = root = H.root Unit; work = tempDir "fpr-str-interp-pieces";
  src = "{work}/pieces.fpr"; asm = "{work}/pieces.s"; exe = "{work}/pieces";
  _ = H.write src (unwrap (Utf8.encode prog));
  env = [("FPR_HOME",root),("FPR_PATH",root),("XDG_CACHE_HOME","{work}/cache")];
  ProcessResult code out err = H.call ["{root}/fpr","compile","--system=posix",src,asm] (List.append env [("FPR_TYPED_IR","dump")]) 240000;
  _ = (if code == 0 then Unit else error "compile exit {code}\n{out}{err}");
  secs = sections (Str.lines "{out}\n{err}") "" "" [];
  n = List.sum (List.map (shape secs)
        [("three", "$strcat3@", ["$strcat4@", "$strcatT@"]),
         ("four", "$strcat4@", ["$strcat3@", "$strcatT@"]),
         ("five", "$strcatT@", ["$strcat3@", "$strcat4@"])]);
  ProcessResult bcode bout berr = H.call ["{root}/fpr","build","-o",exe,src] env 240000;
  _ = (if bcode == 0 then Unit else error "build exit {bcode}\n{bout}{berr}");
  ProcessResult rcode rout rerr = H.call [exe] [] 60000;
  if rcode == 0 and rout == want then print "string pieces: {n} call shapes ($strcat3, $strcat4, $strcatT), every piece kind renders as str PASS"
  else error "run exit {rcode}, want:\n{want}got:\n{rout}{rerr}".
>! main Unit.
