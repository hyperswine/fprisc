# The Sol half of tests/sol-checks/fmath-parity.sol (see parity.fpr).
b x = Num.bits x.
row i =
  x = F64.ofInt i * 0.0137;
  u = F64.ofInt i * 0.00049;
  # pow: integral exponents -30..30 (exact binary powering), a wide base,
  # y near 1e9 on a base near 1, and integral y beyond 2^40
  k = F64.ofInt (i % 61 - 30);
  print "{b (Num.sin x)} {b (Num.cos x)} {b (Num.tan x)} {b (Num.atan x)} {b (Num.atan2 x 0.7)} {b (Num.asin u)} {b (Num.acos u)} {b (Num.exp (x * 0.05))} {b (Num.log (x + 30.5))} {b (Num.log2 (x + 30.5))} {b (Num.pow (x + 30.5) 1.7)} {b (Num.sin (x * 1000.0))} {b (Num.pow (x * 0.1) k)} {b (Num.pow (Num.exp (x * 50.0)) (0.9 + u * 0.1))} {b (Num.pow (1.0 + x * 0.0000001) (F64.ofInt i * 1000003.0 + 0.5))} {b (Num.pow (x * 0.1) (F64.ofInt i * 10000000000.0))}".
> List.fold (fn acc i -> row i) Unit (List.range (0 - 1000) 1000).
