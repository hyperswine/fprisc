# Compiler controls for each ordinary, isolated and optimization-control run.
J = use "sol/lib/json".
flag name = (name,J.JStr "1").
mode normal isolated enabled =
  inlineFlags = if normal then [] else [flag "FPR_NO_INLINE"];
  isolation = if isolated then List.map flag ["FPR_NO_LOOP_REGIONS","FPR_NO_CALL_REGIONS","FPR_COST_PROBE","FPR_COST_REPORT"] else [];
  controls option = J.JObj (inlineFlags + (if enabled then [] else [flag option]) + isolation);
  J.JArr [J.JBool normal,J.JBool isolated,J.JBool enabled,controls "FPR_NO_PAIR_RETURNS",controls "FPR_NO_TYPE_SPEC"].
> choices = [False,True];
  rows = List.concat (List.map (fn normal -> List.concat (List.map (fn isolated ->
    List.map (mode normal isolated) choices) choices)) choices);
  print (J.render (J.JArr rows)).
