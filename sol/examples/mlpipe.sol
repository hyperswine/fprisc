# mlpipe.sol — the TRANSPARENT ML pipeline: standardize, fit, deploy —
# no tier annotations anywhere.  The engine places every stage itself:
#
#   Vec.range 1 n                native bulk fill (one unboxed column —
#                                the push-per-element loop this replaces
#                                was ~97% of the old wall time)
#   Vec.map (std mu sd) / (predict a b c)
#                                GPU f64 compute shader when a device
#                                (or llvmpipe) is up and n >= SOL_GPU_MIN
#                                — the captured statistics/model ride
#                                DOUBLE UNIFORMS, so the cached shader
#                                survives changing parameters; JIT
#                                otherwise
#   Vec.fold (gA a b c) ...      LLVM-JIT typed duals over the record's
#                                SoA columns ({z,y} = two f64 columns),
#                                captured weights as extras
#   Vec.map (mkPt mu sd) ...     the vecmapr MULTI-OUTPUT dual: a map
#                                that RETURNS a record compiles one
#                                typed dual per field and writes k
#                                native columns -- SoA construction
#                                without boxing or per-row apply
#
# Every tier is bit-identical: run with SOL_GPU=0 and/or SOL_JIT=0 and
# the learned coefficients do not move by one ulp.
#
# Model: y = a·z² + b·z + c + wiggle over STANDARDIZED z — the
# standardization is what makes plain gradient descent converge fast
# (E[z]=0, E[z²]=1: the classic conditioning move, here one fold + one
# captured map).

trueA = 2.5.
trueB = 0 - 1.2.
trueC = 0.7.

toZ i = i / 60000.0.
wiggle z = (z * 137.0 - Num.floor (z * 137.0)) / 10 - 0.05.

plus x y = x + y.
sqDev mu acc x = d = x - mu; acc + d * d.
std mu sd x = (x - mu) / sd.

mkPt : Int -> Int -> Int -> {z : Numeric, y : Numeric} .
mkPt mu sd i =
  z = (toZ i - mu) / sd;
  {z = z, y = trueA * z * z + trueB * z + trueC + wiggle z}.

# gradients of the squared error, weights captured (JIT extras)
resid a b c z y = a * z * z + b * z + c - y.
gA a b c acc p = acc + resid a b c p.z p.y * p.z * p.z.
gB a b c acc p = acc + resid a b c p.z p.y * p.z.
gC a b c acc p = acc + resid a b c p.z p.y.

epoch n lr a b c v =
  (s1, v1) = Vec.fold (gA a b c) 0 v;
  (s2, v2) = Vec.fold (gB a b c) 0 v1;
  (s3, v3) = Vec.fold (gC a b c) 0 v2;
  (a - lr * (s1 / n), b - lr * (s2 / n), c - lr * (s3 / n), v3).

train : (k : Int | measure k) -> Int -> Int -> Int -> Int -> Int -> Vector -> (Int, Int, Int, Vector) .
train k n lr a b c v | k <= 0 = (a, b, c, v).
train k n lr a b c v =
  (a2, b2, c2, v2) = epoch n lr a b c v;
  train (k - 1) n lr a2 b2 c2 v2.

predict a b c z = a * z * z + b * z + c.

chkClose name got want tol = case Numeric.abs (got - want) < tol of
  True -> print "ok {name} ({got} ~ {want})"
| False -> error "FAIL {name}: {got} vs {want}".

> n = 120000;
  # feature statistics: two JIT folds (the second with mu captured)
  raw = Vec.map toZ (Vec.range 1 n);
  (s0, raw1) = Vec.fold plus 0 raw;
  mu = s0 / n;
  (sq, raw2) = Vec.fold (sqDev mu) 0 raw1;
  sd = Num.sqrt (sq / n);
  u0 = Vec.free raw2;
  # build the standardized {z, y} rows (vecmapr: native SoA construction)
  pts = Vec.map (mkPt mu sd) (Vec.range 1 n);
  # fit: 120 epochs of three captured JIT folds each
  (a, b, c, pts2) = train 120 n 0.3 0 0 0 pts;
  u1 = print "learned a {a}  b {b}  c {c}";
  k1 = chkClose "a" a trueA (Numeric.div 1 10);
  k2 = chkClose "b" b trueB (Numeric.div 1 10);
  k3 = chkClose "c" c trueC (Numeric.div 1 10);
  # deploy: standardize a fresh grid and score it — the captured
  # statistics AND the learned model ride GPU uniforms
  grid = Vec.map (std mu sd) (Vec.map toZ (Vec.range 1 n));
  preds = Vec.map (predict a b c) grid;
  (psum, preds2) = Vec.fold plus 0 preds;
  u2 = print "mlpipe: pred-checksum {psum}";
  u3 = Vec.free pts2;
  Vec.free preds2 .
