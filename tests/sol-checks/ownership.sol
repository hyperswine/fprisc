# Linear ownership audit (port of the retired tools/audit_linear_ownership.py;
# docs/2026-11-09-CALLABLE-OWNERSHIP.md). Every invalid ownership probe, built on a
# harmless nominal Token, must be refused by both the native frontend
# (fprc --check-only) and Sol. keep_escape is the one explicit escape and is
# only reported. A probe that either frontend accepts fails the check.
H = use "helpers".
base = "profile base.\nToken 1 = Type (Token Int).\nconsume : Token -> Int.\nconsume owner = Token n = owner; u = print \"consume \{n\}\"; n.\n".
probes = [
  ("direct_control", "main = t = Token 7; print (consume t, consume t)."),
  ("lambda_control", "main = t = Token 7; f = fn u -> consume t; print (f 0, f 1)."),
  ("tuple_control", "main = t = Token 7; pair = (t, 0); (owned, n) = pair; print (consume owned, consume owned)."),
  ("direct_pap_control", "at : Token -> Int -> Int.\nat t n = consume t + n.\nmain = t = Token 7; f = at t; print (f 0, f 1)."),
  ("generic_duplicate", "duplicate : a -> (a, a).\nduplicate x = (x, x).\nmain = t = Token 7; (a, b) = duplicate t; print (consume a, consume b)."),
  ("generic_identity", "identity : a -> a.\nidentity x = x.\nmain = t = Token 7; moved = identity t; print (consume moved, consume moved)."),
  ("box_pattern", "Box a = Type (Box a).\nuseBox : Box Token -> (Int, Int).\nuseBox box = case box of Box x -> (consume x, consume x).\nmain = print (useBox (Box (Token 7)))."),
  ("box_wildcard", "Box a = Type (Box a).\nforget : Box Token -> Unit.\nforget box = case box of Box _ -> Unit.\nmain = u = forget (Box (Token 7)); print \"owner lost\"."),
  ("record_literal", "main = record = \{owner = Token 7, tag = 0\}; print (consume record.owner, consume record.owner)."),
  ("record_projection", "unpack : \{owner : Token, tag : Int\} -> (Int, Int).\nunpack record = owner = record.owner; (consume owner, consume owner).\nmain = print (unpack \{owner = Token 7, tag = 0\})."),
  ("record_update", "main = t = Token 7; old = \{owner = t, tag = 0\}; fresh = \{old | tag = 1\}; print (consume old.owner, consume fresh.owner)."),
  ("higher_order_twice", "twice : (Int -> Int) -> (Int, Int).\ntwice f = (f 0, f 1).\nmain = t = Token 7; f = fn n -> consume t + n; print (twice f)."),
  ("closure_return", "make : Token -> (Int -> Int).\nmake t = fn n -> consume t + n.\nmain = f = make (Token 7); print (f 0, f 1)."),
  ("closure_identity", "identity : a -> a.\nidentity x = x.\nmain = t = Token 7; f = fn n -> consume t + n; g = identity f; print (g 0, g 1)."),
  ("aliased_pap", "at : Token -> Int -> Int.\nat t n = consume t + n.\nalias = at.\nmain = t = Token 7; f = alias t; print (f 0, f 1)."),
  ("dynamic_pap", "at : Token -> Int -> Int.\nat t n = consume t + n.\nmain = t = Token 7; f = (case True of True -> at | False -> at) t; print (f 0, f 1)."),
  ("case_join", "main = t = Token 7; f = (case False of True -> u = consume t; fn n -> n | False -> fn n -> consume t + n); print (f 0, f 1)."),
  ("guard_binding", "guardedToken u | t <- Token 7 = (consume t, consume t).\nguardedToken _ = (0, 0).\nmain = print (guardedToken 0)."),
  ("keep_escape", "main = t = Token 7; moved = keep t; print (consume moved, consume moved)."),
  ("result_pattern", "takeResult : Result Token String -> (Int, Int).\ntakeResult result = case result of Ok owner -> (consume owner, consume owner) | Err _ -> (0, 0).\nmain = print (takeResult (Ok (Token 7)))."),
  ("list_pattern", "takeTokens : List Token -> (Int, Int).\ntakeTokens tokens = case tokens of Nil -> (0, 0) | owner :: rest -> (consume owner, consume owner).\nmain = print (takeTokens [Token 7])."),
  ("record_pattern", "takeRecord : \{owner : Token, tag : Int\} -> (Int, Int).\ntakeRecord record = \{owner\} = record; (consume owner, consume owner).\nmain = print (takeRecord \{owner = Token 7, tag = 0\})."),
  ("inferred_return", "makeUnannotated u = Token 7.\nmain = t = makeUnannotated 0; print (consume t, consume t)."),
  ("inferred_parameter", "handleUnannotated t = (consume t, consume t).\nmain = print (handleUnannotated (Token 7)).")].
# "ok" = accepted (exit 0), "refused" = rejected with a LINEARITY diagnostic,
# anything else (crash, parse error, missing tool) = "broken", which also fails.
verdict argv env = ProcessResult code out err = H.call argv env 120000;
  if code == 0 then "ACCEPTED" else if Str.contains "LINEARITY" (out + err) then "refused" else "broken (exit {code}): {err}".
probe root work env (name, body) =
  path = "{work}/{name}.fpr";
  _ = H.write path (unwrap (Utf8.encode (base + body + "\n")));
  native = verdict ["{root}/fprc","--system=posix","--check-only",path,"/dev/null"] env;
  sol = verdict ["{root}/fpr","sol",path] env;
  _ = print "{name}: native={native}, Sol={sol}";
  if name == "keep_escape" or (native == "refused" and sol == "refused") then [] else [name].
> work = tempDir "fpr-ownership-audit"; root = H.root Unit;
  env = [("FPR_HOME",root),("SOL_GPU","0"),("SOL_JIT","0"),("SOL_CACHE_DIR","{work}/sol-cache")];
  findings = List.concat (List.map (probe root work env) probes);
  n = List.len findings;
  _ = print "{n} invalid ownership probes accepted (or not refused for linearity) by at least one frontend; keep is recorded separately as an explicit escape";
  if findings == [] then Unit else error "ownership audit: accepted {findings}".
