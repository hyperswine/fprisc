J = use "sol/lib/json".
S = use "pi-scheduler-cases".
L = use "pi-language-cases".
expand spec = case spec of
    J.JArr [J.JStr "scheduler",J.JStr shape,J.JStr variant,J.JStr mode,J.JNum n] -> S.matrix shape variant mode n
  | J.JArr [J.JStr "watchdog",J.JStr shape] -> List.map (S.watchdog shape) [1,4]
  | _ -> L.expand spec.
