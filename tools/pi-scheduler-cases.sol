J = use "sol/lib/json".
scenario shape variant name probe (harts,route) (count,load) rep =
  J.JObj [("kind",J.JStr "scheduler"),("binary",J.JStr name),("args",J.JArr [J.JStr route,J.JStr load]),
    ("harts",J.JNum harts),("shape",J.JStr shape),("variant",J.JStr variant),("probe",J.JBool probe),
    ("competitors",J.JNum count),("route",J.JStr route),("repetition",J.JNum rep),("timeout",J.JNum 60)].
matrix shape variant mode repetitions =
  probe = mode == "probe"; name = "{shape}-{variant}-{mode}";
  reps = List.range 0 (if probe then 0 else repetitions - 1);
  loads = [(0,"zero"),(1,"one"),(8,"eight")];
  routes = [(1,"local"),(4,"local"),(4,"remote")];
  List.concat (List.map (fn route -> List.concat (List.map (fn load -> List.map (scenario shape variant name probe route load) reps) loads)) routes).
watchdog shape harts = J.JObj [("kind",J.JStr "watchdog"),("binary",J.JStr "{shape}-default-plain"),
  ("args",J.JArr [J.JStr "stall"]),("harts",J.JNum harts),("timeout",J.JNum 3)].
# The compiler and case matrix consume the same plain/probe pair, in that order.
sourceText template rounds shape code work result =
  copy = shape == "copy";
  pong = if copy then "case receive self of (who,n,payload) -> _ = send who (n + 1,payload); pong self."
         else "case receive self of (who,n,payload) -> _ = send who (n + 1); pong self.";
  fields = [("\{imports}",if copy then "List = use \"std/list\"." else ""),
    ("\{payload}",if copy then "List.range 1 4096" else "0"),("\{pong}",pong),
    ("\{receive}",if copy then "case receiveFrom me p of (r,returned) -> (r,returned)" else "(receiveFrom me p,0)"),
    ("\{check}",if copy then "List.length returned == 4096 and List.sum returned == 8390656" else "True"),
    ("\{rounds}",rounds),("\{result}",result),("\{work}",work),("\{code}",code)];
  List.fold (fn text pair -> (marker,value) = pair; Str.replace marker value text) template fields.
fixturePair template rounds repetitions fixture = case fixture of
    J.JArr [J.JStr shape,J.JStr variant,J.JArr [J.JStr code,J.JStr work,result],switches,hal] ->
      source = J.JStr (sourceText template (J.render rounds) shape code work (J.render result));
      enabled = (if variant == "default" then "enabled" else "disabled");
      checks = J.JArr [J.JStr "scheduler",J.JStr shape,J.JStr enabled];
      List.map (fn mode ->
        job = J.JArr [J.JStr "{shape}-{variant}-{mode}",source,switches,J.JStr mode,hal,checks];
        spec = J.JArr [J.JStr "scheduler",J.JStr shape,J.JStr variant,J.JStr mode,repetitions];
        (job,spec)) ["plain","probe"]
  | _ -> error "invalid scheduler fixture".
