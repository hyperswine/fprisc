# physics.sol — ballistics ensemble on the Numeric datatype.
#
# N projectiles with varying launch velocities, each integrated by
# semi-implicit Euler with QUADRATIC drag (a = -c|v|v), until impact.
# dt, g, cD and every state variable are F64; the integrator
# uses plain operators plus Num.sqrt — exactly the "conventional math
# on the default number type" this example always wanted to be.
#
# Verification: the drag-free integrator matches the closed form
# R = 2*vx*vy/g to O(dt), asserted below with a tolerance chk.
#
# JIT note: the ensemble map compiles natively — the recursive `fly`
# integrator, Numeric.sqrt intrinsic included, specializes over the int
# launch columns with f64 state (per-callsite typed variants). SOL_JIT=0
# agrees bit-for-bit.

dt = 0.01.     # s
g  = 9.81.     # m/s^2
cD = 0.002.    # drag coefficient (quadratic)

plus : F64 -> F64 -> F64 .
plus a b = a + b.

# integrate with drag; returns range (metres) at impact.
# unsafe on purpose: the loop ends when the projectile falls below y = 0,
# which is physics, not a decreasing integer, so no measure can state it.
# (The style accepts this for float-heavy numeric code.)
fly : unsafe F64 -> F64 -> F64 -> F64 -> F64 .
fly x y vx vy | y < 0.0 = x.
fly x y vx vy =
  v  = Num.sqrt (vx * vx + vy * vy);
  ax = 0.0 - cD * (v * vx);
  ay = 0.0 - g - cD * (v * vy);
  fly (x + vx * dt) (y + vy * dt) (vx + ax * dt) (vy + ay * dt).

# drag-free variant for the closed-form check; unsafe for the same reason
flyN : unsafe F64 -> F64 -> F64 -> F64 -> F64 .
flyN x y vx vy | y < 0.0 = x.
flyN x y vx vy = flyN (x + vx * dt) (y + vy * dt) vx (vy - g * dt).

rangeOf : unsafe _ -> F64 .
rangeOf p = fly 0.0 0.0 (F64.ofInt p.vx) (F64.ofInt p.vy).
rangeN : unsafe _ -> F64 .
rangeN p = flyN 0.0 0.0 (F64.ofInt p.vx) (F64.ofInt p.vy).

# launch grid: vx 12..31 m/s, vy 8..27 m/s interleaved (ints promote on use)
mkRow i = {vx = 12 + i - (i / 20) * 20, vy = 8 + (i * 7 - ((i * 7) / 20) * 20)}.

fill : (Vector _) -> List Int -> (Vector _) .
fill v xs = List.fold (fn acc i -> Vec.push (mkRow i) acc) v xs.

closedForm p = F64.ofInt (2 * p.vx * p.vy) / g.

fmax : F64 -> F64 -> F64 .
fmax a b = case a > b of True -> a | False -> b.
fabs : F64 -> F64 .
fabs v = if v < 0.0 then 0.0 - v else v.

chkClose name got want tol = case fabs (got - want) < tol of
  True -> print "ok {name} ({got} ~ {want})"
| False -> error "FAIL {name}: {got} vs {want}".

> n = 300;
  vec = fill (Vec.new Unit) (List.range 1 n);
  (p1, vec2) = Vec.get 0 vec;
  u = print "closed form R = {closedForm p1} m";
  u2 = print "integrated  R = {rangeN p1} m (drag-free, O(dt) error)";
  c1 = chkClose "drag-free vs closed form" (rangeN p1) (closedForm p1) 1.0;
  ranges = Vec.map rangeOf vec2;
  (total, r2) = Vec.fold plus 0.0 ranges;
  (best, r3) = Vec.fold fmax 0.0 r2;
  u3 = print "n = {n}: mean range {total / F64.ofInt n} m, best {best} m";
  Vec.free r3.
