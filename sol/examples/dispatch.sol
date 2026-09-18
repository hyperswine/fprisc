# dispatch.sol — the Vec dispatch lattice: interp -> JIT -> GPU.
# Gates per tier: availability, purity (GLSL-translatable = the safe
# arithmetic fragment), exactness (f64 column only — on a KNum column
# `/` is IEEE double division in ALL THREE tiers), n >= SOL_GPU_MIN.
# The checksum must be IDENTICAL whichever tier fires.
poly x = x * x / 7 + x - 3 .
plus a b = a + b .
fill : Vector -> (i : Int | measure (lim - i)) -> (lim : Int) -> Vector .
fill v i lim | i > lim = v.
fill v i lim = fill (Vec.push (Num.sqrt (i * i)) v) (i + 1) lim.

> xs = fill (Vec.new Unit) 1 120000;
  ys = Vec.map poly xs;
  (s, ys2) = Vec.fold plus 0 ys;
  u = print "dispatch: checksum = {s}";
  Vec.free ys2 .
