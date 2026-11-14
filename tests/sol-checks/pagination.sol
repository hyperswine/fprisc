# (Sol's List.range is inclusive.)
# Contracted pagination arithmetic and its real inventory projection (port of
# the retired tests/check_pagination.py). The Sol reference computes the plan
# independently; native arithmetic is exercised at tagged-Int limits (63-bit).
# Only the constant pagination core has declared bounds.
H = use "helpers".
maxInt = 4611686018427387903.
minInt = 0 - maxInt - 1.
literal n = if n >= 0 then "{n}" else if n == minInt then "(0 - {maxInt} - 1)" else "(0 - {0 - n})".
sequence ns = "[{Str.join "," (List.map literal ns)}]".
maxi a b = if a > b then a else b.
mini a b = if a < b then a else b.
# size > 0 and count >= 0 here, so truncating / equals floor. The remainder is
# count - whole * size: Sol's % is wrong for large Ints (2305843009213693951 % 2 gives -1).
reference size count requested = whole = count / size; tail = count - whole * size;
  pages = maxi 1 (whole + (if tail > 0 then 1 else 0));
  index = maxi 0 (mini requested (pages - 1));
  (index, pages, index * size).
refLine size count request = (i, p, f) = reference size count request; "{size},{count},{request}:{i},{p},{f}".
groups = [
  (List.range 1 9, List.range 0 32, [0 - 3, 0, 1, 2, 9, 33]),
  ([1, 2, 3, 20, maxInt / 2, maxInt - 1, maxInt],
   [0, 1, 2, 19, 20, 21, maxInt / 2, maxInt - 1, maxInt],
   [minInt, 0 - 1, 0, 1, 2, maxInt / 2, maxInt - 1, maxInt])].
callLine g = (ss, ns, rs) = g; "  _ = group {sequence ss} {sequence ns} {sequence rs};".
wantLines g = (ss, ns, rs) = g;
  List.concat (List.map (fn s -> List.concat (List.map (fn n -> List.map (fn r -> refLine s n r) rs) ns)) ss).
build root work env name body cost = src = "{work}/{name}.fpr"; exe = "{work}/{name}";
  _ = H.write src (unwrap (Utf8.encode ("profile base.\nP = use \"std/pagination\".\n" + body)));
  ProcessResult code out err = H.call (List.concat [["{root}/fpr","build",src], (if cost then ["--cost"] else []), ["-o",exe]]) env 240000;
  (exe, code, out + err).
must what ok detail = if ok then Unit else error "{what}\n{detail}".
runLines exe env harts = ProcessResult code out err = H.call [exe] (("FPR_HARTS",harts) :: env) 240000;
  _ = must "{exe} on {harts} harts: exit {code}" (code == 0) err; Str.lines out.
hasLine report parts = List.any (fn l -> List.all (fn p -> Str.contains p l) parts) (Str.lines report).
boundaries = "L = use \"std/list\".\nemit size count request =\n  p = P.plan size count request;\n  print \"\{size\},\{count\},\{request\}:\{p.index\},\{p.pages\},\{p.first\}\".\ngroup sizes counts requests = L.fold (fn acc size ->\n  L.fold (fn acc count -> L.fold (fn acc request -> emit size count request) Unit requests) Unit counts) Unit sizes.\nmain =\n".
refuse = "Program = use \"std/program\".\ncall size count = p = P.plan size count 0; p.first.\nmain = case Program.args Unit of\n    [\"size-zero\"] -> print (call 0 1)\n  | [\"size-negative\"] -> print (call (0 - 1) 1)\n  | [\"count-negative\"] -> print (call 1 (0 - 1))\n  | [\"pages-zero\"] -> print (P.pages 0 1)\n  | [\"pages-negative\"] -> print (P.pages 1 (0 - 1))\n  | _ -> Unit.\n".
tooSmall = "small : Unit -> Int | work small <= 1 | alloc small <= 31.\nsmall _ = p = P.plan 20 100 0; p.first.\nmain = print (small Unit).\n".
inventory app = "I = use \"{app}\".\nL = use \"std/list\".\nitem n = \{id = n, name = \"item \{n\}\", loc = \"room\", sub = \"\", desc = \"\", tags = Nil,\n          created = n, at = n, by = \"sam\", moves = Nil\}.\nemit count request =\n  session = \{I.noSess | sid = 7, user = \"sam\", page = request\};\n  model = \{I.initModel | sess = [session], items = L.map item (L.range 1 count)\};\n  v = I.project 20 200 7 model;\n  ids = L.map (fn it -> it.id) v.items;\n  print \"\{count\},\{request\}:\{v.page\},\{v.pages\},\{v.first\}:\{ids\}\".\nmain =\n  _ = emit 0 100;\n  _ = emit 21 100;\n  _ = emit 41 1;\n  _ = emit 41 (0 - 1);\n  _ = emit 1 2;\n  _ = print (I.imax 1 0, I.imax 1 (0 - 1), I.imax 1 20);\n  Unit.\n".
invLine cr = (count, request) = cr; (index, pages, first) = reference 20 count request;
  ids = List.take 20 (List.drop first (List.rev (List.range 1 count)));
  "{count},{request}:{index},{pages},{first}:[{Str.join ", " (List.map (fn i -> "{i}") ids)}]".
refusal root exe env spec = (arg, function, predicate) = spec;
  ProcessResult code out err = H.call [exe, arg] env 240000;
  must "refuse {arg}: exit {code}, want 1 naming {function} and {predicate}" (code == 1 and Str.contains function (out + err) and Str.contains predicate (out + err)) (out + err).
firstDiff : unsafe List String -> List String -> String.
firstDiff got want = case (got, want) of
  (g :: gs, w :: ws) -> if g == w then firstDiff gs ws else "got {g}, want {w}"
| _ -> "got {List.len got} lines".
main : unsafe Unit -> Unit.
main u = root = H.root Unit; work = tempDir "fpr-pagination";
  env = [("FPR_HOME",root),("XDG_CACHE_HOME","{work}/cache")];
  (exe, code, report) = build root work env "boundaries" (boundaries + Str.join "\n" (List.map callLine groups) + "\n  Unit.\n") True;
  _ = must "boundaries build: exit {code}" (code == 0) report;
  _ = must "pages work <= 8 not PROVEN" (hasLine report ["pages@", ": declared work <= 8 ", "PROVEN"]) report;
  _ = must "plan work <= 25 not PROVEN" (hasLine report ["plan@", ": declared work <= 25 ", "PROVEN"]) report;
  _ = must "plan alloc <= 32 not PROVEN" (hasLine report ["plan@", ": declared alloc <= 32 ", "PROVEN"]) report;
  judged = Str.join "\n" (List.filter (fn l -> not (Str.contains "no result-size lemma; annotation is not used" l)) (Str.lines report));
  _ = must "an UNPROVED or OVER bound in the report" (not (Str.contains "UNPROVED" judged) and not (Str.contains " OVER " judged)) report;
  want = List.concat (List.map wantLines groups);
  _ = List.map (fn h -> got = runLines exe env h; must "boundaries on {h} harts: {firstDiff got want}" (got == want) "") ["1","4"];
  nw = List.len want;
  _ = print "Pagination: {nw} independent-reference cases on 1/4 harts, including tagged Int extrema; constant budgets prove";
  ProcessResult gb gout gerr = H.call ["{root}/fpr","build","{root}/tests/std/pagination.fpr","-o","{work}/golden"] env 240000;
  _ = must "golden build" (gb == 0) (gout + gerr);
  ProcessResult gr gro gre = H.call ["{work}/golden"] env 240000;
  _ = must "golden output differs" (gr == 0 and gro == readPath "{root}/tests/std/pagination.expected") (gro + gre);
  (rexe, rcode, rout) = build root work env "refuse" refuse True;
  _ = must "refuse build" (rcode == 0) rout;
  _ = List.map (refusal root rexe env) [("size-zero","plan","size > 0"),("size-negative","plan","size > 0"),
    ("count-negative","plan","count >= 0"),("pages-zero","pages","size > 0"),("pages-negative","pages","count >= 0")];
  (sexe, scode, refused) = build root work env "too-small" tooSmall True;
  _ = must "too-small must not compile" (scode != 0) refused;
  _ = must "too-small work bound not reported OVER" (Str.contains "small: declared work <= 1" refused and Str.contains "OVER" refused) refused;
  _ = must "too-small alloc bound not reported" (Str.contains "small: declared alloc <= 31" refused and Str.contains "derived 32" refused) refused;
  _ = print "Pagination: invalid internal size/count fail with named contracts; insufficient work/allocation bounds fail compilation";
  (iexe, icode, iout) = build root work env "inventory-project" (inventory "{root}/examples/inventory.fpr") False;
  _ = must "inventory build" (icode == 0) iout;
  iwant = List.append (List.map invLine [(0, 100), (21, 100), (41, 1), (41, 0 - 1), (1, 2)]) ["(1, 1, 20)"];
  _ = List.map (fn h -> got = runLines iexe env h; must "inventory on {h} harts: {firstDiff got iwant}" (got == iwant) "") ["1","4"];
  print "Inventory: actual projection keeps sorted page contents, empty/shrunk/late/negative requests, and historical config normalization on 1/4 harts".
> main Unit.
