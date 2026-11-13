J = use "sol/lib/json".
allocationFields kind enabled count bytes = case count of
    J.JNull -> []
  | J.JNum n ->
    size = (case kind of "base-fields" -> J.JNum (if enabled then 49104 else 81840)
            | "base-storage" -> J.JNum (32 * n) | _ -> bytes);
    [("expected_allocations",count)] + (if size == J.JNull then [] else [("expected_allocated_bytes",size)])
  | _ -> error "invalid allocation count".
commonFields kind label normal isolated enabled =
  [("kind",kind),("binary",label),("normal_inline",normal),("isolated",isolated),
   ("enabled",enabled),("timeout",J.JNum 60)].
nestedCheck (name,output) =
  trap = (case name of "division" -> J.JStr "division by zero" | "overflow" -> J.JStr "Int overflow"
    | "underflow" -> J.JStr "Int overflow" | _ -> J.JNull);
  J.JArr [J.JStr name,J.JArr [J.JStr name],output,trap].
rows common checks = List.concat (List.map (fn h -> List.map (row common h) checks) [1,4]).
expand spec = case spec of
  J.JArr [kind,label,normal,J.JBool enabled,count,bytes,J.JArr checks] ->
    extra = allocationFields (unwrap (J.text kind)) enabled count bytes;
    rows (commonFields kind label normal (J.JBool (count != J.JNull)) (J.JBool enabled) + extra) checks
  | J.JArr [J.JStr "lifetime",label,normal,isolated,enabled] ->
    common = commonFields (J.JStr "lifetime") label normal isolated enabled;
    List.map (fn h -> J.JObj (common + [("args",J.JArr []),("harts",J.JNum h)])) [1,4]
  | J.JArr [J.JStr "nested-return",label,normal,isolated,enabled,J.JObj answers] ->
    rows (commonFields (J.JStr "nested-return") label normal isolated enabled) (List.map nestedCheck answers)
  | _ -> error "invalid language fixture description".
row common h check = case check of
  J.JArr [name,argv,output,trap] -> J.JObj (common + [("case",name),("args",argv),("expected_stdout",output),
    ("trap",trap),("expected_exit",J.JNum (if trap == J.JNull or trap == J.JStr "" then 0 else 1)),("harts",J.JNum h)])
  | _ -> error "invalid language fixture check".
