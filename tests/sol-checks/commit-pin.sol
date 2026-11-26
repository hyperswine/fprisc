# `fpr pin` writes the pins `fpr commit` asks for, and `fpr commit` compares a
# new version with the prior one without re-running today's safe/unsafe lint on
# the immutable prior blob (compiler/Commit.hs; docs/2026-11-25-FPR-COMMIT-REPIN.md).
H = use "helpers".
text s = unwrap (Utf8.encode s).
# H.write creates; replacing a file removes it first
replace path s = ProcessResult c _ e = unwrap (Proc.runNow (ProcessSpec ["rm","-f",path] "" [] "" 5000));
  if c == 0 then H.write path (text s) else error "rm {path}: {e}".
# fpr in the work directory: (exit, stdout + stderr)
fpr root work env argv = ProcessResult c o e = unwrap (Proc.runNow (ProcessSpec (List.append ["{root}/fpr"] argv) work env "" 300000)); (c, o + e).
expect what ok out = if ok then Unit else error "commit-pin: {what}:\n{out}".
inDir work argv = ProcessResult c _ e = unwrap (Proc.runNow (ProcessSpec argv work [] "" 5000));
  if c == 0 then Unit else error "commit-pin: {argv}: {e}".
has needle file work = ProcessResult c _ _ = unwrap (Proc.runNow (ProcessSpec ["grep","-qF",needle,file] work [] "" 5000)); c == 0.
# the pin hash the compiler prints for an unpinned module
pinOf out = case List.filter (fn l -> Str.contains "use: Lib resolves to" l) (Str.lines out) of
    l :: _ -> (case Str.split 35 l of _ :: rest :: _ -> Str.slice rest 0 16 | _ -> error "commit-pin: no pin in {l}")
  | [] -> error "commit-pin: no pin line in:\n{out}".
>! root = H.root Unit; work = tempDir "fpr-commit-pin";
  env = [("FPR_HOME",root),("FPR_PATH",root),("XDG_CACHE_HOME","{work}/cache")];
  _ = H.write "{work}/a.fpr" (text "f : Int -> Int .\nf x = x + 1.\n");
  _ = H.write "{work}/b.fpr" (text "# b uses a\nA = use \"a\".\ng : Int -> Int .\ng x = A.f x.\n");
  # 1. an unpinned use is refused, and the refusal names the fix
  (c1, o1) = fpr root work env ["commit","b.fpr"];
  _ = expect "unpinned use refused with a fix" (c1 != 0 and Str.contains "fix: fpr pin b.fpr --deps" o1) o1;
  # 2. fpr pin writes the pin, keeps the comment, and commit then succeeds
  (c2, o2) = fpr root work env ["pin","b.fpr","--deps"];
  _ = expect "pin --deps" (c2 == 0 and has "A = use \"a#" "b.fpr" work and has "# b uses a" "b.fpr" work) o2;
  (c3, o3) = fpr root work env ["commit","a.fpr"];
  (c4, o4) = fpr root work env ["commit","b.fpr"];
  _ = expect "first versions" (c3 == 0 and c4 == 0 and Str.contains "first version" o4) (o3 + o4);
  # 3. a moved dependency keeps resolving from the store until --update re-pins it
  _ = replace "{work}/a.fpr" ("f : Int -> Int .\nf x = x + 2.\nf2 : Int -> Int .\nf2 x = x.\n");
  (c5, o5) = fpr root work env ["pin","b.fpr"];
  _ = expect "plain pin leaves a pinned use alone" (c5 == 0 and Str.contains "nothing to change" o5) o5;
  (c6, o6) = fpr root work env ["pin","b.fpr","--update=a"];
  (c7, o7) = fpr root work env ["commit","a.fpr"];
  (c8, o8) = fpr root work env ["commit","b.fpr"];
  _ = expect "update re-pins, then patch commits" (c6 == 0 and Str.contains "rewrote 1 file" o6 and c7 == 0 and Str.contains "patch" o7 and c8 == 0 and Str.contains "patch" o8) (o6 + o7 + o8);
  # 4. a prior version that today's safe/unsafe lint flags (a recursion with no
  #    declared `unsafe` signature) still serves as the comparison baseline
  w4 = tempDir "fpr-commit-prior";
  _ = H.write "{w4}/c.fpr" (text "h n = if n <= 0 then 0 else h (n - 1).\n");
  (c9, o9) = fpr root w4 env ["commit","c.fpr"];
  _ = expect "the lint refuses the current file, naming it" (c9 != 0 and Str.contains "commit refused: c.fpr does not pass the checker" o9) o9;
  old = pinOf o9;
  _ = inDir w4 ["mkdir","-p",".fpr/store"];
  _ = inDir w4 ["cp","c.fpr",".fpr/store/{old}.fpr"];
  _ = H.write "{w4}/.fpr/versions.db" (text "c v1.0 {old}\n");
  _ = replace "{w4}/c.fpr" ("h : unsafe Int -> Int .\nh n = if n <= 0 then 0 else h (n - 1).\nk : Int -> Int .\nk x = x.\n");
  (c10, o10) = fpr root w4 env ["commit","c.fpr"];
  _ = expect "patch over a lint-flagged prior" (c10 == 0 and Str.contains "committed c.v1.1" o10) o10;
  # 5. a prior blob that cannot reload (an unpinned use from before the closure
  #    rule) is refused with the reason, and --major mints past it
  w5 = tempDir "fpr-commit-stale";
  _ = inDir w5 ["mkdir","-p",".fpr/store"];
  _ = H.write "{w5}/.fpr/store/0000000000000001.fpr" (text "Z = use \"zzz-missing\".\nz x = x.\n");
  _ = H.write "{w5}/.fpr/versions.db" (text "d v1.0 0000000000000001\n");
  _ = H.write "{w5}/d.fpr" (text "z : Int -> Int .\nz x = x.\n");
  (c11, o11) = fpr root w5 env ["commit","d.fpr"];
  _ = expect "unreproducible prior refused" (c11 != 0 and Str.contains "cannot be re-checked" o11 and Str.contains "--major" o11) o11;
  (c12, o12) = fpr root w5 env ["commit","d.fpr","--major"];
  _ = expect "--major past an unreproducible prior" (c12 == 0 and Str.contains "committed d.v2.0" o12) o12;
  print "commit-pin: pin/--deps/--update, lint-flagged and unreproducible priors: PASS".
