# The v1.0 conformance suite, stage 0 of the core spec (§5.5): one program per
# clause of the v1.0 semantics and core spec, in tests/conformance/.
#
#   NAME.fpr        the program; its first line names the clause it tests
#   NAME.expected   the exact standard output of a run
#   NAME.exit       optional: the expected exit code of the run (default 0)
#   NAME.refused    instead of .expected: the program must NOT compile, and the
#                   compiler's output must contain this file's text
#
# Each program is built once with ./fpr (in parallel) and run one at a time.
# Native posix only for now; running the same cases under Sol is the next step
# (core spec Q6). A clause that the compiler does not meet yet is a row
# "conformance:NAME" in tests/sol-checks-known-failures.tsv: the check fails if
# such a case starts passing, so fixing a defect means deleting its row.
H = use "helpers".
stemOf suffix p = if Str.endsWith suffix p then [Str.slice p 0 (Str.len p - Str.len suffix)] else [].
conformanceCases dir = List.concat (List.map (stemOf ".fpr") (ls dir)).
buildJob root dir work name = (name, ["{root}/fpr","build","{dir}/{name}.fpr","-o","{work}/{name}"], root,
  [("FPR_HOME",root),("FPR_PATH",root),("XDG_CACHE_HOME","{work}/cache")], 900000).
tail n s = if Str.len s > n then Str.slice s (Str.len s - n) (Str.len s) else s.
fail name why = _ = print "FAIL {name}: {why}"; [name].
pass name = _ = print "PASS {name}"; [].
refusedCase name want code out err = all = "{out}{err}";
  if code == 0 then fail name "compiled, but the clause says it must be refused"
  else if Str.contains want all then pass name
  else fail name "refused, but the diagnostic lacks \"{want}\":\n{tail 1500 all}".
runCase : unsafe String -> String -> String -> List (String, Int, String, String) -> String -> List String.
runCase root dir work builds name =
  (b, bcode, bout, berr) = (case List.filter (fn r -> (n, c, o, e) = r; n == name) builds of r :: _ -> r | [] -> (name, -1, "", "no build"));
  refusal = "{dir}/{name}.refused";
  if H.isFile refusal then refusedCase name (Str.trim (readPath refusal)) bcode bout berr
  else if bcode != 0 then fail name "build failed: exit {bcode}\n{tail 1500 bout}{tail 1500 berr}"
  else
    results = H.parallel 1 [(name, ["{work}/{name}"], work, [("FPR_HOME",root)], 120000)];
    (l, code, out, err) = (case results of [r] -> r | _ -> error "no result");
    wantExit = if H.isFile "{dir}/{name}.exit" then parseInt (Str.trim (readPath "{dir}/{name}.exit")) else 0;
    want = readPath "{dir}/{name}.expected";
    if code != wantExit then fail name "exit {code}, want {wantExit}\n--- stdout\n{tail 1500 out}\n--- stderr\n{tail 1500 err}"
    else if out != want then fail name "stdout differs\n--- want\n{want}--- got\n{out}"
    else pass name.
main : unsafe Unit -> Unit.
main u = root = H.root Unit; dir = "{root}/tests/conformance"; work = tempDir "fpr-conformance";
  names = conformanceCases dir;
  builds = H.parallel (H.cpus Unit) (List.map (buildJob root dir work) names);
  failed = List.concat (List.map (runCase root dir work builds) names);
  _ = print "conformance: {List.len names} cases, {List.len failed} failed";
  H.settle "conformance" root failed.
> main Unit.
