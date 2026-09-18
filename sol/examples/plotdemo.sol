# plotdemo.sol — the SVG/SMIL plotting backend (lib/plot.sol), fed by
# real simulations: every chart below is ONE self-contained text file a
# browser renders, written through the ordinary transactional writePath.
#
#   ../../fpr sol plotdemo.sol
#   -> plot-spring.svg   damped spring: x and v over time (2 series+legend)
#   -> plot-descent.svg  gradient descent on a paraboloid: the loss curve
#   -> plot-traj.svg     ...and the (a,b) trajectory as hoverable markers
#   -> plot-wave.svg     ANIMATED: a pulse travelling through a polyline
#                        (SMIL morph, no runtime, loops forever)
#   -> plot-orbit.svg    ANIMATED: two satellites + faint trails
#
# No trig anywhere: the wave is a rational bump, the orbit and spring
# come out of Euler-Cromer integrators — pure arithmetic, the same
# fragment every other tier of the engine speaks.

pl = use "../lib/plot".
P = pl.P.

# ---- damped spring: x'' = -4x - 0.3v ---------------------------------------

spring : (k : Int | measure k) -> Int -> Int -> Int -> (List _, List _) .
spring k t x v | k <= 0 = ([], []).
spring k t x v =
  v2 = v + (0 - 4) * x * 0.05 - 0.3 * v * 0.05;
  x2 = x + v2 * 0.05;
  (pxs, pvs) = spring (k - 1) (t + 0.05) x2 v2;
  ((t, x) :: pxs, (t, v) :: pvs).

# ---- gradient descent on f(a,b) = (a-2)^2 + 3(b+1)^2 ----------------------

gd : (k : Int | measure k) -> Int -> Int -> Int -> (List _, List _) .
gd k i a b | k <= 0 = ([], []).
gd k i a b =
  loss = (a - 2) * (a - 2) + 3 * (b + 1) * (b + 1);
  a2 = a - 0.15 * 2 * (a - 2);
  b2 = b - 0.15 * 6 * (b + 1);
  (ls, tr) = gd (k - 1) (i + 1) a2 b2;
  ((Numeric.inexact i, loss) :: ls, (a, b) :: tr).

# ---- two-body orbits: a = -r / |r|^3 (mu = 1), Euler-Cromer ---------------

orbit : (k : Int | measure k) -> Int -> Int -> Int -> Int -> Int -> List _ .
orbit k every x y vx vy | k <= 0 = [].
orbit k every x y vx vy =
  r2 = x * x + y * y;
  r3 = r2 * Num.sqrt r2;
  vx2 = vx - x / r3 * 0.02;
  vy2 = vy - y / r3 * 0.02;
  x2 = x + vx2 * 0.02;
  y2 = y + vy2 * 0.02;
  rest = orbit (k - 1) every x2 y2 vx2 vy2;
  case (k % every) == 0 of
    True -> (x, y) :: rest
  | False -> rest.

# ---- travelling pulse: y = 1/(1 + 8(x - c)^2), c sweeps 0..4 --------------

waveRow : Int -> (i : Int | measure (40 - i)) -> List _ .
waveRow c i | i > 40 = [].
waveRow c i =
  x = i / 10.0;
  d = x - c;
  (x, 1 / (1 + 8 * d * d)) :: waveRow c (i + 1).
waveFrames : (f : Int | measure (24 - f)) -> List _ .
waveFrames f | f > 24 = [].
waveFrames f = waveRow (f / 6.0) 1 :: waveFrames (f + 1).

> (sx, sv) = spring 160 0.0 1.5 0.0;
  u1 = writePath @plot-spring.svg (P.series "damped spring: x and v over t" [("x", sx), ("v", sv)]);
  (ls, tr) = gd 40 0 (0 - 3.0) 2.5;
  u2 = writePath @plot-descent.svg (P.line "gradient descent: loss per step" ls);
  u3 = writePath @plot-traj.svg (P.scatter "descent trajectory in (a, b)" tr);
  u4 = writePath @plot-wave.svg (P.anim "travelling pulse (SMIL morph)" 4 (waveFrames 1));
  t1 = orbit 900 15 1.0 0.0 0.0 1.1;
  t2 = orbit 900 15 1.6 0.0 0.0 0.82;
  u5 = writePath @plot-orbit.svg (P.animDots "two-body orbits" 6 [t1, t2]);
  print "plotdemo: wrote 5 svg (2 animated)".
