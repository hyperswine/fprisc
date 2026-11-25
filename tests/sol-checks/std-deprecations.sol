# Deprecated std module aliases added after the v0.15.0 stdlib consolidation:
# old imports compile with a warning that names the replacement, renamed
# exports resolve, std/set is refused with a specific message, moved-out
# modules stay in sync with their examples/ sources, and a bytes shim
# compiles to the same assembly as a direct std/binary import (zero-cost).
H = use "helpers".
env root work = [("FPR_HOME",root),("FPR_PATH",root),("XDG_CACHE_HOME","{work}/cache")].
fx root name = "{root}/tests/reliability/std-deprecations/{name}.fpr".
compile root work env name =
  src = fx root name; out = "{work}/{name}.s";
  ProcessResult code stdout stderr = H.call ["{root}/fpr","compile",src,out] env 180000;
  (code, stdout + stderr, out).
hasWarning text old new = Str.contains ("warning: \"{old}\" is deprecated; use \"{new}\" instead (removed in v0.17.0)") text.
# Assembly comparison ignores debug file names and comment / path noise.
asmKey line = not (Str.startsWith ".file" line) and not (Str.startsWith ".loc" line)
  and not (Str.startsWith "#" line) and not (Str.contains "std-deprecations" line)
  and not (Str.contains "bytes-old" line) and not (Str.contains "bytes-new" line).
asmBody path = List.filter asmKey (Str.lines (readPath path)).
copies = [
  ("std/appearance.fpr", "examples/lib/appearance.fpr"),
  ("std/gitrevision.fpr", "examples/lib/gitrevision.fpr"),
  ("std/mjpeg.fpr", "examples/lib/mjpeg.fpr"),
  ("std/money.fpr", "examples/lib/money.fpr"),
  ("std/pagination.fpr", "examples/lib/pagination.fpr"),
  ("std/printeralertcodes.fpr", "examples/printer-dashboard/printeralertcodes.fpr"),
  ("std/printeralerts.fpr", "examples/printer-dashboard/printeralerts.fpr"),
  ("std/printertelemetry.fpr", "examples/printer-dashboard/printertelemetry.fpr"),
  ("std/sessionauth.fpr", "examples/printer-dashboard/sessionauth.fpr"),
  ("std/checkdemo.fpr", "examples/checkdemo.fpr")].
# The std copy is a three-line preamble plus the canonical examples file.
bodyAfterPreamble path = ls = Str.lines (readPath path);
  case ls of
    a :: b :: c :: rest -> if Str.startsWith "deprecated " c or (Str.startsWith "deprecated " b)
      then (if Str.startsWith "deprecated " c then Str.join "\n" rest else Str.join "\n" (c :: rest))
      else Str.join "\n" ls
  | _ -> readPath path.
copyOk root pair = (dest, src) = pair; got = Str.trim (bodyAfterPreamble "{root}/{dest}"); want = Str.trim (readPath "{root}/{src}");
  if got == want then [] else ["copy-drift:{dest}"].
expectOk root work env name old new =
  (code, text, _) = compile root work env name;
  if code != 0 then _ = print "FAIL {name}: compile exit {code}\n{text}"; ["{name}:compile"]
  else if not (hasWarning text old new) then _ = print "FAIL {name}: missing deprecation warning\n{text}"; ["{name}:warning"]
  else _ = print "PASS {name}"; [].
> root = H.root Unit; work = tempDir "fpr-std-deprecations"; e = env root work;
  failed = [];
  # --- old imports compile and warn ---
  failed = List.append failed (expectOk root work e "bytes-old" "std/bytes" "std/binary");
  failed = List.append failed (expectOk root work e "viewcache-old" "std/viewcache" "std/view");
  failed = List.append failed (expectOk root work e "osnet-old" "std/osnet" "std/os");
  failed = List.append failed (expectOk root work e "browser-old" "std/browserautocomplete" "std/browser");
  failed = List.append failed (expectOk root work e "appearance-old" "std/appearance" "examples/lib/appearance");
  failed = List.append failed (expectOk root work e "pagination-old" "std/pagination" "examples/lib/pagination");
  # --- std/set is refused, not aliased ---
  (setCode, setText, _) = compile root work e "set-old";
  failed = List.append failed (if setCode != 0 and Str.contains "\"std/set\" was removed in v0.15.0" setText
    then _ = print "PASS set-old"; []
    else _ = print "FAIL set-old: expected a retirement error, exit {setCode}\n{setText}"; ["set-old"]);
  # --- zero-cost: std/bytes and std/binary produce the same assembly ---
  (cNew, tNew, sNew) = compile root work e "bytes-new";
  failed = List.append failed (if cNew == 0 then [] else _ = print "FAIL bytes-new: compile exit {cNew}\n{tNew}"; ["bytes-new:compile"]);
  (cOld, _, sOld) = compile root work e "bytes-old";
  failed = List.append failed (if cNew == 0 and cOld == 0 and asmBody sOld == asmBody sNew
    then _ = print "PASS bytes zero-cost"; []
    else if cNew == 0 and cOld == 0
      then _ = print "FAIL bytes zero-cost: assembly differs"; ["bytes-zero-cost"]
      else []);
  # --- compatibility copies match examples/ ---
  drifts = List.concat (List.map (copyOk root) copies);
  failed = List.append failed (if drifts == [] then _ = print "PASS compatibility copies in sync"; [] else _ = print "FAIL {drifts}"; drifts);
  _ = print "std-deprecations: {List.len failed} failures";
  H.settle "std-deprecations" root failed.
