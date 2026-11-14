# x64 inline bump allocation with a spilled destination (the compile-only part of
# the retired tests/check_finite_field_workers.py; fixed in #64). x64's allocator
# scratches (r10, r11) are the inline bump's own slab and hart registers. A cell
# whose destination is spilled must be built in a borrowed register: with 16 boxed
# parameters one is, and the fast path used to overwrite its slab with the cell.
H = use "helpers".
chainOf value n = Str.join "; " (List.map (fn i -> if i == 0 then "z0 = {value} + 1" else "z{i} = z{i - 1} + 1") (List.range 0 (n - 1))) + "; z{n - 1}".
# fixture('parameters', 16) of the Python check
fixture amount = xs = List.range 0 (amount - 1);
  value = Str.join " + " (List.map (fn i -> "x{i}") xs);
  body = List.fold (fn acc i -> "case c{i} of Cell x{i} -> {acc}") (chainOf value 32) (List.rev xs);
  helper = "bump {Str.join " " (List.map (fn i -> "c{i}") xs)} = {body}.\n";
  call = "bump (Cell x)" + Str.join "" (List.map (fn i -> " (Cell 0)") (List.range 1 (amount - 1)));
  "unsafe base.\nCell a = Type (Cell a).\n" + helper + "go n x = if n <= 0 then x else go (n - 1) ({call}).\nmain = print (go 1000 0).\n".
isReg s = Str.endsWith ", %r10" s or Str.endsWith ", %r11" s.
# "movq (%r10), %r1x" immediately followed by "addq $N, %r1x"
selfScratch : unsafe List String -> Int.
selfScratch ls = case ls of
  a :: b :: rest -> (if Str.endsWith "(%r10), %r10" (Str.trim a) or Str.endsWith "(%r10), %r11" (Str.trim a) then
      (if Str.startsWith "addq $" (Str.trim b) and isReg (Str.trim b) then 1 else 0) else 0) + selfScratch (b :: rest)
| _ -> 0.
# "pushq %rax" immediately followed by "movq N(%r11), %r10"
borrowed : unsafe List String -> Int.
borrowed ls = case ls of
  a :: b :: rest -> (if Str.trim a == "pushq %rax" and Str.startsWith "movq " (Str.trim b) and Str.endsWith "(%r11), %r10" (Str.trim b) then 1 else 0) + borrowed (b :: rest)
| _ -> 0.
main : unsafe Unit -> Unit.
main u = root = H.root Unit; work = tempDir "fpr-bump-spill";
  src = "{work}/bump-spill.fpr"; asm = "{work}/bump-spill.s";
  _ = H.write src (unwrap (Utf8.encode (fixture 16)));
  env = [("FPR_HOME",root),("FPR_PATH",root),("XDG_CACHE_HOME","{work}/cache"),("FPR_NO_FIELD_WORKERS","1")];
  ProcessResult code out err = H.call ["{root}/fpr","compile","--system=posix","--target=x64","--prelude={root}/core/prelude.fpr",src,asm] env 240000;
  _ = (if code == 0 then Unit else error "compile exit {code}\n{out}{err}");
  lines = Str.lines (readPath asm);
  _ = (if selfScratch lines == 0 then Unit else error "x64 inline bump builds a cell in its own scratch");
  n = borrowed lines;
  if n >= 1 then print "x64 inline bump: {n} spilled cell destination(s) built in a borrowed register PASS"
  else error "the fixture no longer spills a bump destination on x64; pick one that does".
> main Unit.
