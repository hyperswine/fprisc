# linreg.sol — linear regression by full-batch gradient descent. Data:
# y = 1.75*x1 - 0.5*x2 + 0.25 + noise. Features and weights are F64 (born
# from Rand.unit and float literals); every product and comparison below
# is a plain operator on F64. No fixed-point library, no manual scaling.
#
# JIT note: the record's F64 fields live in unboxed f64 SoA columns, and
# the typed tier compiles each fold natively with the weights captured.
# Run with SOL_JIT=0 to cross-check — outputs are bit-identical.

rnd = use "../lib/rand".
Rand = rnd.Rand.

# The first part just generates the data, y = 1.75*x1 - 0.5*x2 + 0.25 + noise, with x1,x2 uniform in [0,1)

trueW1 = 1.75.
trueW2 = 0.0 - 0.5.
trueB  = 0.25.

mkRow s =
  s1 = Rand.next s; s2 = Rand.next s1; s3 = Rand.next s2;
  x1 = Rand.unit s1; x2 = Rand.unit s2;
  noise = Rand.gauss4 s3 / 20.0;
  {x1 = x1, x2 = x2, y = trueW1 * x1 + trueW2 * x2 + trueB + noise}.

fill : (Vector _) -> Int -> (k : Int | measure k) -> (Vector _) .
fill v s k | k <= 0 = v.
fill v s k = fill (Vec.push (mkRow (Rand.next (s + k * 100003))) v) s (k - 1).

# this is the residual of a single sample, given the current weights and bias
resid : F64 -> F64 -> F64 -> F64 -> F64 -> F64 -> F64 .
resid w1 w2 b x1 x2 y = w1 * x1 + w2 * x2 + b - y.

gW1 w1 w2 b acc p = acc + resid w1 w2 b p.x1 p.x2 p.y * p.x1.
gW2 w1 w2 b acc p = acc + resid w1 w2 b p.x1 p.x2 p.y * p.x2.
gB  w1 w2 b acc p = acc + resid w1 w2 b p.x1 p.x2 p.y.
sqErr w1 w2 b acc p = r = resid w1 w2 b p.x1 p.x2 p.y; acc + r * r.

# one epoch: three gradient folds, weights step by lr * grad / n
epoch n lr w1 w2 b v =
  (s1, v1) = Vec.fold (gW1 w1 w2 b) 0.0 v;
  (s2, v2) = Vec.fold (gW2 w1 w2 b) 0.0 v1;
  (s3, v3) = Vec.fold (gB w1 w2 b) 0.0 v2;
  m = F64.ofInt n;
  (w1 - lr * (s1 / m), w2 - lr * (s2 / m), b - lr * (s3 / m), v3).

train : (k : Int | measure k) -> Int -> F64 -> F64 -> F64 -> F64 -> (Vector _) -> (F64, F64, F64, (Vector _)) .
train k n lr w1 w2 b v | k <= 0 = (w1, w2, b, v).
train k n lr w1 w2 b v =
  (w1a, w2a, ba, v2) = epoch n lr w1 w2 b v;
  train (k - 1) n lr w1a w2a ba v2.

fabs : F64 -> F64 .
fabs v = if v < 0.0 then 0.0 - v else v.
chkClose name got want tol = case fabs (got - want) < tol of
  True -> print "ok {name} ({got} ~ {want})"
| False -> error "FAIL {name}: {got} vs {want}".

> n = 300;
  lr = 0.8;
  train_v = fill (Vec.new Unit) 20260716 n;
  (w1, w2, b, v2) = train 80 n lr 0.0 0.0 0.0 train_v;
  u1 = print "learned  w1 {w1}  w2 {w2}  b {b}";
  u2 = print "true     w1 {trueW1}  w2 {trueW2}  b {trueB}";
  c1 = chkClose "w1" w1 trueW1 0.1;
  c2 = chkClose "w2" w2 trueW2 0.1;
  c3 = chkClose "b"  b  trueB  0.1;
  test_v = fill (Vec.new Unit) 777991 100;
  (sse, t2) = Vec.fold (sqErr w1 w2 b) 0.0 test_v;
  u3 = print "test MSE {sse / 100.0}";
  u4 = Vec.free t2;
  Vec.free v2.
