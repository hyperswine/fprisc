# Print storage workers and carrier adapters for the Pi receipt after checking the probe.
symbolName line = case List.rev (Str.words line) of name :: _ -> name | [] -> "".
storage name = Str.startsWith "fpr_fn__x24worker_x2estorage_x2e" name or Str.startsWith "fpr_fn__x24carrier_x2e" name.
inspect tool exe mode =
  ProcessResult status out err = unwrap (Proc.runNow (ProcessSpec [tool,exe] "" [] "" 0));
  names = (if status == 0 then List.map symbolName (Str.lines out) else error "{tool} failed for {exe}: {err}");
  present = List.any (fn name -> name == "fpr_sched_probe" or name == "_fpr_sched_probe") names;
  if present != (mode == "probe") then error "{exe}: scheduler probe symbol disagrees with {mode} build"
  else List.filter storage names.

verifyWorkers exe family shape enabled names =
  rootAdapter = Str.contains "_x24at_x2eroot";
  adapters = List.filter rootAdapter names;
  imported = (if family == "scheduler" then List.len (List.filter (Str.contains "_x2epack_x40") adapters) == (if enabled then 1 else 0)
              else (adapters != []) == enabled);
  workers = (case shape of
      "base-fields" -> if family == "scheduler" then ["aggregate_x2emake"] else ["aggregate_x2emake","read_x2escore"]
    | "base-storage" -> if family == "scheduler" then ["list_x2ebuildCells"] else ["list_x2ebuild","read_x2etotal"]
    | _ -> []);
  symbols = (if shape == "base-carrier" then ["fpr_fn__x24carrier_x2e6_x2eMeters_x2efill"]
             else List.map (fn w -> "fpr_fn__x24worker_x2estorage_x2e{w}") workers);
  valid = (if shape == "imported-carrier" then imported else List.all (fn w -> (List.has w names) == enabled) symbols);
  if valid then Unit else error "{exe}: unexpected {shape} symbols for {family} (enabled={enabled}): {names}".
