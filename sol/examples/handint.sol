# handint.sol — handJIT over an INT column: guards desugar to the same
# CIf-over-comparison the hand emitter compiles; int / is quot (idiv),
# matching the interpreter's arith exactly.
step x | x > 500 = x * 3 - 7 .
step x = x / 2 + 1 .
plus a b = a + b .
fill : unsafe Vector -> Int -> Int -> Vector .
fill v i lim | i > lim = v.
fill v i lim = fill (Vec.push (i * 13) v) (i + 1) lim.

> xs = fill (Vec.new Unit) 1 90000;
  ys = Vec.map step xs;
  (s, ys2) = Vec.fold plus 0 ys;
  u = print "handint: checksum = {s}";
  Vec.free ys2 .
