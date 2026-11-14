# std work/alloc contracts stay in sync with the costs the compiler derives
# (port of the retired tests/reliability/std_contracts.py). Every std module that
# declares `| work f <= ...` or `| alloc f <= ...` is imported into one generated
# program built with `fpr build --cost` (compiler/Cost.hs). A declared bound that
# is not PROVEN fails, naming the function, declared and derived values.
# Declarations looser than a constant derived bound are counted as slack.
# (The Python --fix rewrite mode is not ported.)
H = use "helpers".
upperWord w = w != "" and List.all (fn c -> c >= 65 and c <= 90) (Str.codes w).
firstUpper : (ws : List String | measure ws) -> String.
firstUpper ws = case ws of [] -> "" | w :: rest -> if upperWord w then w else firstUpper rest.
digits s = s != "" and List.all (fn c -> c >= 48 and c <= 57) (Str.codes s).
# "  name@hash: declared work <= D   derived E   STATUS ..." -> [(name, kind, D, E, STATUS)]
bound line = t = Str.trim line; at = Str.find 64 t;
  kinds = List.filter (fn k -> Str.contains ": declared {k} <= " t) ["work","alloc"];
  case kinds of
    [kind] -> lead = ": declared {kind} <= "; i = Str.indexOf lead t; rest = Str.slice t (i + Str.len lead) (Str.len t);
      j = Str.indexOf " derived " rest;
      if at < 0 or j < 0 or Str.contains " " (Str.slice t 0 at) then [] else
        declared = Str.trim (Str.slice rest 0 j); tail = Str.slice rest (j + 9) (Str.len rest);
        status = firstUpper (Str.words tail);
        k = Str.indexOf " {status}" tail;
        derived = if status == "" or k < 0 then Str.trim tail else Str.trim (Str.slice tail 0 k);
        [(Str.slice t 0 at, kind, declared, derived, status)]
  | _ -> [].
dedup : (rows : List (String, String, String, String, String) | measure rows) -> List (String, String) -> List (String, String, String, String, String).
dedup rows seen = case rows of
  [] -> []
| (name, kind, d, e, s) :: rest -> if List.has (name, kind) seen then dedup rest seen else (name, kind, d, e, s) :: dedup rest ((name, kind) :: seen).
stem p = Str.slice p 4 (Str.len p - 4).
importLine (i, p) = "M{i} = use \"std/{stem p}\".\n".
topLevel p = p != "" and not (Str.contains "/" (Str.slice p 4 (Str.len p))).
drifted (n, k, d, e, s) = s != "PROVEN".
loose (n, k, d, e, s) = s == "PROVEN" and digits d and digits e and parseInt d > parseInt e.
describe (n, k, d, e, s) = print "DRIFT {k} {n}: declared <= {d}, derived {e} ({s})".
> work = tempDir "fpr-contracts"; root = H.root Unit;
  ProcessResult gcode listing gerr = H.call ["grep","-l","-E","\\|[[:space:]]*(work|alloc) ","-r","--include=*.fpr","std"] [] 30000;
  mods = List.filter topLevel (Str.lines listing);
  _ = (if mods == [] then error "std contracts: no std module declares a bound ({gerr})" else Unit);
  imports = List.map importLine (List.zip (List.range 0 (List.len mods)) mods);
  src = "{work}/contracts.fpr";
  _ = H.write src (unwrap (Utf8.encode (Str.join "" imports + "main = print 0.\n")));
  env = [("FPR_HOME",root),("FPR_PATH",root),("XDG_CACHE_HOME","{work}/cache")];
  ProcessResult code out err = H.call ["{root}/fpr","build","--cost",src,"-o","{work}/contracts"] env 900000;
  report = out + err;
  seen = dedup (List.concat (List.map bound (Str.lines report))) [];
  _ = (if seen == [] then _ = print report; error "std contracts: no declared bounds found in the --cost report" else Unit);
  bad = List.filter drifted seen;
  slack = List.len (List.filter loose seen);
  _ = List.map describe bad;
  nb = List.len seen; nm = List.len mods; nd = List.len bad;
  _ = print "std contracts: {nb} declared bounds in {nm} modules, {nd} drifted, {slack} with slack";
  if bad != [] then error "std contracts drifted"
  else if code != 0 then _ = print report; error "std contracts: build failed (exit {code}) without a contract drift"
  else Unit.
