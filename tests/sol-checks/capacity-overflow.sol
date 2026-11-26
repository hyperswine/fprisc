# Impossible collection capacities fail visibly (docs/2026-11-10-FAILURE-MODES.md):
# a clean "capacity out of range" panic on stderr and exit 1, never a size
# product that wraps to a tiny allocation (MutMap.withCapacity 2^60 used to
# reach 2^61 slots, whose 2^61 * 8 bytes wrapped to 0, and was OOM-killed).
H = use "helpers".
mm n = "MutMap = use \"std/mutmap\".\nmain =\n  m = MutMap.withCapacity {n} (MutMap.ints Unit);\n  _ = print \"reserved\";\n  m2 = MutMap.insert 1 2 m;\n  (v, m3) = MutMap.get 1 m2;\n  _ = MutMap.free m3;\n  print v.\n".
vr n = "main =\n  v = Vec.range 0 {n};\n  _ = print \"made\";\n  (k, v2) = Vec.len v;\n  _ = Vec.free v2;\n  print k.\n".
impossible = [("mm-2^60", mm "1152921504606846976", "MutMap: capacity out of range"),
         ("mm-2^61", mm "2305843009213693952", "MutMap: capacity out of range"),
         ("mm-2^62-1", mm "4611686018427387903", "MutMap: capacity out of range"),
         ("vec-range-2^61", vr "2305843009213693952", "Vec: capacity out of range")].
probe root work env c = case c of (name, text, want) ->
  src = "{work}/{name}.fpr"; exe = "{work}/{name}";
  _ = H.write src (unwrap (Utf8.encode text));
  ProcessResult bc bo be = H.call ["{root}/fpr","build",src,"-o",exe] env 300000;
  _ = (if bc == 0 then Unit else error "build {name}: {bo}{be}");
  ProcessResult c1 o1 e1 = H.call [exe] env 60000;
  ok = c1 == 1 and o1 == "" and Str.contains "[ERR] {want}" e1 and Str.contains "FPRISC PANIC" e1;
  if ok then _ = print "PASS {name}"; [] else _ = print "FAIL {name}: exit {c1}, stdout={o1}, stderr={e1}"; [name].
small root work env = src = "{work}/small.fpr"; exe = "{work}/small";
  _ = H.write src (unwrap (Utf8.encode (mm "1000")));
  ProcessResult bc bo be = H.call ["{root}/fpr","build",src,"-o",exe] env 300000;
  _ = (if bc == 0 then Unit else error "build small: {bo}{be}");
  ProcessResult c0 o0 e0 = H.call [exe] env 60000;
  if c0 == 0 and o0 == "reserved\nSome 2\n" then print "PASS small capacity" else error "small capacity: exit {c0}, stdout={o0}, stderr={e0}".
>! root = H.root Unit; work = tempDir "fpr-capacity-overflow";
  env = [("FPR_HOME",root),("FPR_PATH",root),("XDG_CACHE_HOME","{work}/cache"),("FPR_DIAG_STDOUT","")];
  _ = small root work env;
  failed = List.concat (List.map (probe root work env) impossible);
  if failed == [] then print "capacity_overflow: impossible capacities panic cleanly: PASS" else error "capacity overflow: {failed}".
