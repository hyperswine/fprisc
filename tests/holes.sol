# typed holes: ?name refuses to compile (with the inferred type);
# ?? compiles to a runtime trap -- the pipeline before it RUNS.
MyType = Type (MyCons Int ??).
fold2 op = List.fold op 0.
step x = u = print "hole demo: prefix ran, sum = {x}"; x.
> [0,1,2,3,4,5,7,10] |> fold2 (fn a b -> a + b) |> step |> ?? .
