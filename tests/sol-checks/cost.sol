# Resource bounds, stages 1-4 (port of the retired tests/check_cost.py;
# docs/2026-10-02-RESOURCE-BOUNDS.md): the work/alloc equations `fpr build --cost`
# prints for measured, mutual and higher-order recursion; declared bounds checked
# coefficient by coefficient; target manifests; live and loop costs; and the
# examples/todo.fpr report within 60 s.
H = use "helpers".
must what ok detail = if ok then Unit else error "{what}\n{detail}".
after i s = Str.slice s i (Str.len s).
# the report section after "cost (work" to the next "\nunit ", plus "declared bounds:"
section out start = i = Str.indexOf start out; if i < 0 then "" else
  rest = after i out; j = Str.indexOf "\nunit " rest; if j < 0 then rest else Str.slice rest 0 j.
cost root work src = ProcessResult code out err = H.call ["{root}/fpr","build","--cost",src,"-o","{work}/probe"] [("FPR_HOME",root),("XDG_CACHE_HOME","{work}/cache")] 120000;
  _ = must "{src}: exit {code}" (code == 0) (out + err);
  _ = must "{src}: no cost report" (Str.contains "cost (work" out) out;
  section out "cost (work" + (if Str.contains "\ndeclared bounds:" out then section out "\ndeclared bounds:" else "").
# "  fn<space...>work  <= X" -> X
workAfter fname l = rest = after (Str.len fname + 2) l; t = Str.trim rest;
  if Str.startsWith "  {fname}" l and Str.len rest > 0 and Str.isSpace (Str.at rest 0) and Str.startsWith "work  <= " t then [Str.trim (after 9 t)] else [].
workOf report fname = case List.concat (List.map (workAfter fname) (Str.lines report)) of w :: _ -> w | [] -> error "no work line for {fname} in\n{report}".
allocLines : unsafe String -> List String -> List String.
allocLines fname ls = case ls of
  a :: b :: rest -> t = Str.trim b;
    if Str.startsWith "  {fname}" a and Str.startsWith "alloc <= " t and Str.endsWith " bytes" t then [Str.trim (Str.slice t 9 (Str.len t - 6))] else allocLines fname (b :: rest)
| _ -> [].
allocOf : unsafe String -> String -> String.
allocOf report fname = case allocLines fname (Str.lines report) of w :: _ -> w | [] -> error "no alloc line for {fname} in\n{report}".
expect what got want = must "{what}: got {got}, want {want}" (got == want) "".
has report needle = must "expected {needle} in the report" (Str.contains needle report) report.
outcome root work argv ok needles = ProcessResult code out err = H.call argv [("FPR_HOME",root),("XDG_CACHE_HOME","{work}/cache")] 300000;
  text = out + err;
  _ = must "{argv}: expected {if ok then "accepted" else "refused"}, exit {code}" ((code == 0) == ok) text;
  List.map (fn n -> must "{argv}: expected {n}" (Str.contains n text) text) needles.
build root work name ok needles = outcome root work ["{root}/fpr","build","{root}/tests/cases/{name}","-o","{work}/probe"] ok needles.
judged root work name manifest ok needles = outcome root work ["{root}/fpr","build","{root}/tests/cases/{name}","--manifest={root}/tests/manifests/{manifest}","-o","{work}/probe"] ok needles.
scratchLines : unsafe List String -> Bool.
scratchLines ls = case ls of
  a :: b :: c :: rest -> if Str.startsWith "  scratch" a and Str.contains "work  <= " a and Str.trim b == "alloc <= ω(?len) + 72 bytes"
      and Str.trim c == "live  <= ω(?len) + 24·(max(0, ω(?)) + 1) + 88 bytes" then True else scratchLines (b :: c :: rest)
| _ -> False.
stampMs u = ProcessResult code out err = H.call ["date","+%s%N"] [] 5000; parseInt (Str.trim out) / 1000000.
main : unsafe Unit -> Unit.
main u = root = H.root Unit; work = tempDir "fpr-cost"; dir = "{root}/tests/cases";
  r1 = cost root work "{root}/tests/measure.fpr";
  _ = expect "fact work" (workOf r1 "fact") "5·(max(0, n) + 1)";
  _ = expect "lsum work" (workOf r1 "lsum") "6·(len l + 1)";
  _ = expect "sumTo work" (workOf r1 "sumTo") "6·(max(0, (-1)·i + lim) + 1)";
  _ = expect "fact alloc" (allocOf r1 "fact") "0";
  r2 = cost root work "{dir}/measure_mutual_ok.fpr";
  _ = expect "ping work" (workOf r2 "ping") "5·(max(0, n) + 1)";
  _ = expect "pong work" (workOf r2 "pong") "5·(max(0, n) + 1)";
  r3 = cost root work "{dir}/cost_ho.fpr";
  _ = expect "apply work" (workOf r3 "apply") "work f + 1";
  _ = expect "twice work" (workOf r3 "twice") "2·work f + 2";
  _ = expect "useIt work" (workOf r3 "useIt") "11";
  _ = expect "mk alloc" (allocOf r3 "mk") "24";
  _ = has r3 "opaque: print";
  _ = build root work "bound_ok.fpr" True [];
  _ = build root work "bound_signed_unsafe.fpr" False ["UNPROVED", "signed input domain"];
  _ = build root work "bound_caller.fpr" True [];
  _ = build root work "bound_over.fpr" False ["OVER (max(0, n): derived 5, declared 4)"];
  _ = build root work "bound_unused_over.fpr" False ["OVER (max(0, n): derived 5, declared 4)"];
  _ = build root work "bound_free_name.fpr" False ["the bound names `omega`, which is not a parameter of count"];
  _ = build root work "bound_unproved.fpr" False ["UNPROVED (opaque: print)"];
  r4 = cost root work "{dir}/bound_caller.fpr";
  _ = expect "g work (inc's declared 10)" (workOf r4 "g") "12";
  _ = has r4 "inc: declared work <= 10   derived 1   PROVEN";
  _ = has (cost root work "{dir}/bound_ok.fpr") "count: declared work <= 5·max(0, n) + 5   derived 5·(max(0, n) + 1)   PROVEN";
  _ = has (cost root work "{dir}/bound_pipeline.fpr") "total: declared work <= 23·len xs + 27   derived 9·len xs + 14·(len xs + 1) + 13   PROVEN";
  old = "{work}/bound-pipeline-19.fpr";
  _ = H.write old (unwrap (Utf8.encode (Str.replace "23 * len xs + 27" "19 * len xs + 27" (readPath "{dir}/bound_pipeline.fpr"))));
  _ = outcome root work ["{root}/fpr","build",old,"-o","{work}/probe"] False ["OVER (len xs: derived 23, declared 19)"];
  r5 = cost root work "{dir}/bound_pipeline_direct.fpr";
  _ = expect "total work" (workOf r5 "total") "16·(len xs + 1) + 6";
  _ = expect "main work" (workOf r5 "main") "ω(print) + 257";
  _ = has r5 "total: declared work <= 16·len xs + 22   derived 16·(len xs + 1) + 6   PROVEN";
  _ = judged root work "bound_pipeline_direct.fpr" "host.fprt" True ["target host-test:", "1.3 ns/op", "main       work 2257 ops → 2.93 µs   PROVEN within budget 5 µs", "total      work <= 16·(len xs + 1) + 6   (parametric; × 1.3 ns)"];
  _ = judged root work "bound_pipeline_direct.fpr" "host-tight.fprt" False ["main       work 2257 ops → 2.93 µs   OVER budget 1 µs"];
  _ = build root work "bound_coef.fpr" False ["a named coefficient needs a target manifest"];
  _ = judged root work "bound_coef.fpr" "host.fprt" True ["count: declared work <= 5·max(0, n) + 5   derived 5·(max(0, n) + 1)   PROVEN"];
  _ = judged root work "bound_coef.fpr" "host-omega4.fprt" False ["OVER (max(0, n): derived 5, declared 4)"];
  bad = "{work}/bad-manifest.fprt";
  _ = H.write bad (unwrap (Utf8.encode "name x\nns_per_op fast\n"));
  _ = outcome root work ["{root}/fpr","build","{dir}/bound_ok.fpr","--manifest={bad}","-o","{work}/probe"] False ["not a number: fast"];
  r6 = cost root work "{dir}/live_bounds.fpr";
  _ = has r6 "build: declared live <= 24·max(0, n) + 24   derived 24·(max(0, n) + 1)   PROVEN";
  _ = must "scratch work/alloc/live lines (two-argument closure reserves 48 bytes)" (scratchLines (Str.lines r6)) r6;
  r7 = cost root work "{root}/tests/base/loopwith.fpr";
  _ = must "run work charges ω(loop:Sys.loopWith)" (Str.contains "ω(loop:Sys.loopWith)" (workOf r7 "run")) r7;
  _ = has r7 "per scoped step: work <= ω(diffc) + ω(draw) + ω(junk) + ω(lenL) + 27, alloc <= ω(diffc) + ω(draw) + ω(junk) + 96 bytes";
  r8 = cost root work "{root}/tests/base/loopstate.fpr";
  _ = must "run work charges ω(loop:Sys.loop)" (Str.contains "ω(loop:Sys.loop)" (workOf r8 "run")) r8;
  _ = has r8 "per scoped step: work <=";
  t0 = stampMs Unit;
  r9 = cost root work "{root}/examples/todo.fpr";
  ms = stampMs Unit - t0;
  _ = must "todo cost report took {ms} ms (limit 60 s)" (ms < 60000) "";
  _ = must "updateWith work starts with max(" (Str.startsWith "max(" (workOf r9 "updateWith")) r9;
  _ = must "view work keeps ω(?len)·(" (Str.contains "ω(?len)·(" (workOf r9 "view")) r9;
  _ = must "view work has no varying-recursive-parameter term" (not (Str.contains "varying-recursive-parameter:" (workOf r9 "view"))) r9;
  _ = expect "dropGo work" (workOf r9 "dropGo") "(max(0, k) + 1)·(len s + 15)";
  _ = expect "dropLastChar work" (workOf r9 "dropLastChar") "(max(0, ω(?)) + 1)·(len s + 15) + 2";
  _ = must "todo report keeps ω(?len) and ω(str)" (Str.contains "ω(?len)" r9 and Str.contains "ω(str)" r9) r9;
  print "Cost: measured, mutual and higher-order recursion compose; declared bounds and manifest judgements (2.93 µs within 5 µs, over 1 µs), scoped live/loop costs and the Todo report ({ms / 1000} s) PASS".
> main Unit.
