# The Sol half of tests/sol-checks/fmath-parity.sol (see parity.fpr).
b x = Num.bits x.
row i =
  x = i * 0.0137;
  u = i * 0.00049;
  print "{b (Num.sin x)} {b (Num.cos x)} {b (Num.tan x)} {b (Num.atan x)} {b (Num.atan2 x 0.7)} {b (Num.asin u)} {b (Num.acos u)} {b (Num.exp (x * 0.05))} {b (Num.log (x + 30.5))} {b (Num.log2 (x + 30.5))} {b (Num.pow (x + 30.5) 1.7)} {b (Num.sin (x * 1000.0))}".
> List.fold (fn acc i -> row i) Unit (List.range (0 - 1000) 1000).
