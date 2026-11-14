# Optimization-configuration differential (port of the retired
# tests/reliability/config_differential.py): each program is built under every
# configuration below and must print exactly its .expected output, so all
# configurations agree. A representative subset on every run; with
# FPR_CHECK_FULL=1 (nightly) every no-argument tests/std program.
# Configurations share nothing but the compiler; each gets its own cache.
# CONFIG_JOBS sets the parallelism (default: number of CPUs, at least 2).
H = use "helpers".
configs = [
  ("default", []), ("no_interval", [("FPR_NO_INTERVAL","1")]), ("no_inline", [("FPR_NO_INLINE","1")]),
  ("no_spec", [("FPR_NO_SPEC","1")]), ("no_reuse", [("FPR_NO_REUSE","1")]),
  ("no_workers", [("FPR_NO_SCALAR_WORKERS","1"),("FPR_NO_FIELD_WORKERS","1")]),
  ("no_vec", [("FPR_NO_VEC_FUSE","1"),("FPR_NO_VEC_FAST","1"),("FPR_NO_VEC_SIMD","1")]),
  ("no_str", [("FPR_NO_STR_FAST","1")]), ("no_regions", [("FPR_NO_LOOP_REGIONS","1"),("FPR_NO_CALL_REGIONS","1")]),
  ("harts4", [("FPR_HARTS","4")])].
# Programs that need arguments, files or environment from the old check_std harness.
needsHarness = ["store","storewire","storeconc","durable","posix","apps"].
subset = ["list","string","map","json","foundation","codec","ifelse","pagination","sort"].
expectedStem p = if Str.endsWith ".expected" p then [Str.slice p 0 (Str.len p - 9)] else [].
programs root = if not (H.full Unit) then subset else
  stems = List.concat (List.map expectedStem (ls "{root}/tests/std"));
  List.filter (fn s -> not (List.has s needsHarness) and B.exists "-f" "{root}/tests/std/{s}.fpr") stems.
B = use "../../sol/lib/build".
baseEnv root work cfg = [("FPR_HOME",root),("FPR_PATH",root),("XDG_CACHE_HOME","{work}/cache-{cfg}")].
buildJob root work progs (cfg, extra) = List.map (fn name ->
  ("{name}|{cfg}", ["{root}/fpr","build","{root}/tests/std/{name}.fpr","-o","{work}/{name}.{cfg}"], root, List.append (baseEnv root work cfg) extra, 1200000)) progs.
configEnv : String -> (cs : List (String, List (String, String)) | measure cs) -> List (String, String).
configEnv cfg cs = case cs of [] -> [] | (name, extra) :: rest -> if name == cfg then extra else configEnv cfg rest.
label3 l = case Str.split 124 l of [name, cfg] -> (name, cfg) | _ -> (l, "?").
runJob root work built = List.map (fn l ->
  (name, cfg) = label3 l;
  _ = unwrap (Proc.runNow (ProcessSpec ["mkdir","-p","{work}/wd-{name}-{cfg}"] "" [] "" 10000));
  extra = configEnv cfg configs;
  (l, ["{work}/{name}.{cfg}"], "{work}/wd-{name}-{cfg}", List.append (baseEnv root work cfg) extra, 600000)) built.
tail n s = if Str.len s > n then Str.slice s (Str.len s - n) (Str.len s) else s.
buildFailure (l, code, out, err) = if code == 0 then [] else ["MISMATCH {l} BUILD FAILED (exit {code})\n{tail 1500 out}{tail 1500 err}"].
runFailure root (l, code, out, err) = (name, cfg) = label3 l;
  want = readPath "{root}/tests/std/{name}.expected";
  if code == 0 and out == want then [] else ["MISMATCH {l}: exit {code}; output differs\n{tail 800 out}{tail 800 err}"].
okBuild (l, code, out, err) = code == 0.
labelOf (l, code, out, err) = l.
main : unsafe Unit -> Unit.
main u = root = H.root Unit; work = tempDir "fpr-configs";
  progs = programs root;
  jobs = H.cpus Unit; slots = parseInt (H.envOr "CONFIG_JOBS" "{if jobs < 2 then 2 else jobs}");
  builds = H.parallel slots (List.concat (List.map (buildJob root work progs) configs));
  runs = H.parallel slots (runJob root work (List.map labelOf (List.filter okBuild builds)));
  bad = List.append (List.concat (List.map buildFailure builds)) (List.concat (List.map (runFailure root) runs));
  _ = List.map print bad;
  np = List.len progs; nc = List.len configs; nb = List.len bad;
  _ = print "config differential: {np} programs x {nc} configurations, {nb} mismatches";
  if bad == [] then Unit else error "config differential failed".
> main Unit.
