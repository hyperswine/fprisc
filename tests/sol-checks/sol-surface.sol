# Sol surface: one script per row of the Sol review's porting-gap table
# (docs/2026-11-26-SOL-SCRIPTING-REVIEW.md §3.2 and §5.2) that is fixed or
# confirmed working. Rows that wait on an owner decision (`<=` on strings,
# guards on local functions, `fn _ ->`) are not here; see
# docs/2026-11-26-SOL-SURFACE-FIXES.md.
H = use "helpers".
must what ok detail = if ok then Unit else error "sol-surface: {what}\n{detail}".
# each case gets its own directory and runs there, so relative paths stay inside it
runCase root work name text =
  dir = "{work}/{name}";
  _ = unwrap (Proc.runNow (ProcessSpec ["mkdir","-p",dir] "" [] "" 10000));
  _ = H.writeFile "{dir}/s.sol" (unwrap (Utf8.encode text));
  ProcessResult code out err = unwrap (Proc.runNow (ProcessSpec ["{root}/fpr","sol","{dir}/s.sol"] dir [("FPR_HOME",root)] "" 120000));
  (dir, code, out, err).
absent dir p = ProcessResult c _ _ = H.call ["test","-e","{dir}/{p}"] [] 5000; c != 0.
main : unsafe Unit -> Unit.
main u = root = H.root Unit; work = tempDir "fpr-sol-surface";
  (d1, c1, o1, e1) = runCase root work "keyword-prefix" "casesArg = 3.\nofTen = 10.\n> print (casesArg + ofTen).\n";
  _ = must "a name may begin with case/of" (c1 == 0 and o1 == "13\n") "{o1}{e1}";
  (d2, c2, o2, e2) = runCase root work "prelude-name" "writeNow p s = Unit.\n> writeNow \"x\" \"y\".\n";
  _ = must "defining a prelude name is refused, naming it" (c2 != 0 and Str.contains "writeNow is defined by the Sol prelude" e2) e2;
  (d3, c3, o3, e3) = runCase root work "missing-reads" "> print (exists \"m1/a/b.txt\", isOk (Try.stat \"m2/a/b.txt\"), isOk (Try.readPath \"m3/a/b.txt\")).\n";
  _ = must "reads of missing paths" (c3 == 0 and o3 == "(False, False, False)\n") "{o3}{e3}";
  _ = must "reads of missing paths leave no folders" (absent d3 "m1" and absent d3 "m2" and absent d3 "m3") "";
  (d4, c4, o4, e4) = runCase root work "nested-string" "> print \"v=\{Str.len \"abc\"\} \\\{braces\\\}\".\n";
  _ = must "a string inside interpolation, and escaped braces" (c4 == 0 and o4 == "v=3 \{braces\}\n") "{o4}{e4}";
  (d5, c5, o5, e5) = runCase root work "builtin-shadow" "read x = x + 1.\n> print (read 2).\n";
  _ = must "a runtime builtin may be shadowed" (c5 == 0 and o5 == "3\n") "{o5}{e5}";
  # strings are byte-indexed (v1.0 semantics §5); JSON \u escapes and raw UTF-8 survive, and
  # two halves of a character joined back compare equal to it
  (d6, c6, o6, e6) = runCase root work "byte-strings" "J = use \"std/jsondoc\".\n> v = unwrap (J.parse \"\\\{\\\"a\\\":\\\"caf\\\\u00e9 \\\\ud83d\\\\ude00\\\"\\\}\");\n  a = unwrap (J.text (unwrap (J.get \"a\" v)));\n  print (a == \"café 😀\", strlen a, strlen \"é\", strcat (substr \"é\" 0 1) (substr \"é\" 1 1) == \"é\").\n";
  _ = must "byte-indexed strings and JSON unicode" (c6 == 0 and o6 == "(True, 10, 2, True)\n") "{o6}{e6}";
  # a script's own type named like a builtin or preamble type is its own (the two used to merge)
  (d7, c7, o7, e7) = runCase root work "type-shadow" "Option = Type (Option String Int).\nCmd = Type (Go Int).\nf o = case o of Option s n -> n.\ng c = case c of Go n -> n.\n> print (f (Option \"a\" 2), g (Go 4), Some 3).\n";
  _ = must "a script type may shadow Option and Cmd" (c7 == 0 and o7 == "(2, 4, Some 3)\n") "{o7}{e7}";
  # @Shape.field literals in a statement, and inside a used module (qualified shape names)
  (d8, c8, o8, e8) = runCase root work "path-statement" "Model = \{hp : Int, name : String\}.\n> p = @Model.hp; m = p.set 5 \{hp = 1, name = \"a\"\}; print m.hp.\n";
  _ = must "a path literal in a statement" (c8 == 0 and o8 == "5\n") "{o8}{e8}";
  _ = unwrap (Proc.runNow (ProcessSpec ["mkdir","-p","{work}/path-module"] "" [] "" 10000));
  _ = H.writeFile "{work}/path-module/m.fpr" (unwrap (Utf8.encode "Model = \{hp : Int, name : String\}.\nmain =\n  p = @Model.hp;\n  m = p.set 7 \{hp = 1, name = \"a\"\};\n  m.hp.\n"));
  (d9, c9, o9, e9) = runCase root work "path-module" "T = use \"m.fpr\".\n> print T.main.\n";
  _ = must "a path literal inside a used module" (c9 == 0 and o9 == "7\n") "{o9}{e9}";
  # F64 ^ is exact when the power is representable (double-double, runtime.c fpow_)
  (d10, c10, o10, e10) = runCase root work "pow-exact" "> print (F64.str (2.5 ^ 2.0), F64.str ((0.0 - 1.5) ^ 3.0), F64.str (2.0 ^ (0.0 - 2.0))).\n";
  _ = must "exact powers" (c10 == 0 and o10 == "(6.25, -3.375, 0.25)\n") "{o10}{e10}";
  print "sol-surface: keyword-prefixed names, prelude names refused, missing-path reads, strings in interpolation, builtin shadowing, byte-indexed strings, type shadowing, path literals, exact powers PASS".
>! main Unit.
