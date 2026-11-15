# Reject repository-owned Python/shell files, including extensionless launchers.
B = use "../sol/lib/build".
query argv = ProcessResult code out err = unwrap (Proc.runNow (ProcessSpec argv "" [] "" 0));
  if code == 0 or code == 1 then out else error "policy query failed: {err}".
# The Python programs of the Benchmarks Game suite are what is measured, not tooling: the suite compares
# the same eight programs across languages (tests/bench/clbg/SPEC.md).
measured path = Str.startsWith "tests/bench/clbg/python/" path.
legacy path = (Str.endsWith ".py" path or Str.endsWith ".sh" path) and not (measured path).
script path = if not (B.exists "-f" path) then False else
  first = case Str.lines (readPath path) of line :: _ -> line | [] -> "";
  not (measured path) and Str.startsWith "#!" first and List.any (fn word -> Str.contains word first) ["/sh","bash","python"].
main : unsafe Unit -> Unit .
main Unit =
  tracked = List.filter (fn p -> p != "" and B.exists "-f" p) (Str.lines (query ["git","ls-files","--cached","--others","--exclude-standard","--","*.py","*.sh"]));
  candidates = List.filter (fn p -> p != "") (Str.lines (query ["git","grep","--untracked","-I","-l","-E","^#!.*(bash|/sh|python)","--"]));
  bad = List.append (List.filter legacy tracked) (List.filter script candidates);
  if bad == [] then print "Sol-only script policy: passed" else error "retired script files: {bad}".
> main Unit.
