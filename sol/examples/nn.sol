# nn.sol — a feed-forward neural net with BACKPROPAGATION, on the
# Matrix-on-Vec structure (lib/matrix.sol): 2 -> H -> 1, ReLU hidden,
# full-batch gradient descent, learning y = x1 * x2 — a target a
# LINEAR model cannot fit at all (best linear MSE = var(y)), so the
# fit is the proof that the hidden layer and the gradients work.
#
# What this exercises, tier by honest tier:
#   * batch activations   Z1 = Xaug * W1', A1 = relu cells — the
#     elementwise relu is ONE Vec.map over the n*H cells column (the
#     typed JIT dual); the loss is one Vec.fold (JIT)
#   * matmul              NATIVE (Vec.mmul, VM.hs): an unboxed f64
#     triple loop over the cells columns, bit-identical to the list
#     algebra it replaced; matvec keeps the list path
#   * linearity           every Matrix threads through mMul/mMap/
#     mAllRows and is freed exactly once — the checker enforces the
#     whole training loop's resource discipline at compile time
#   * biases              folded into the weights (augmented inputs:
#     a constant-1 column), the classic trick — no separate bias
#     plumbing anywhere
#
# Nested Vec (a Vec pushed INTO a Vec) is probed at the end: it works
# operationally — the inner vector rides a boxed column — but the
# generic get/push signatures mean the checker cannot see the inner
# handle's linearity, so the FLAT row-major Matrix stays the
# recommended 2D encoding (and is why this file uses it).

rnd = use "../lib/rand".
Rand = rnd.Rand.
mx = use "../lib/matrix".
M = mx.M.

# ---- small list algebra (rows are lists at the matmul boundary) ------------

# Review: Most of these are just Vec.map / Vec.fold
# Should just be extracted out to e.g. std.list

zip2W : (a1 -> b1 -> c1) -> (xs : List a1 | measure xs) -> List b1 -> List c1 .
zip2W f xs ys | xs == [] = [].
zip2W f xs ys = x :: xr = xs; y :: yr = ys; f x y :: zip2W f xr yr.

lSum : (xs : List d1 | measure xs) -> d1 .
lSum xs | xs == [] = 0.
lSum xs = x :: r = xs; x + lSum r.

lScale k xs = map (fn x -> k * x) xs.

lSub : List a2 -> List a2 -> List a2 .
lSub xs ys = zip2W (fn a b -> a - b) xs ys.

lAdd : List b2 -> List b2 -> List b2 .
lAdd xs ys = zip2W (fn a b -> a + b) xs ys.

lZeros : (n : Int | measure n) -> List Int .
lZeros n | n <= 0 = [].
lZeros n = Numeric.inexact 0 :: lZeros (n - 1).

# ---- the net ---------------------------------------------------------------

# Review: initRow and initRows are just Vec.fromList / Vec.push

relu x = case x > 0 of True -> x | False -> Numeric.inexact 0.
sq x = x * x.

# deterministic small init in (-0.7, 0.7)
initRow : Int -> (k : Int | measure k) -> List Int .
initRow s k | k <= 0 = [].
initRow s k = Rand.unit s * 0.7 :: initRow (Rand.next s) (k - 1).

initRows : Int -> (r : Int | measure r) -> Int -> List _ .
initRows s r c | r <= 0 = [].
initRows s r c = initRow s c :: initRows (Rand.next4 (s + 7919)) (r - 1) c.

# training data: n samples, x1/x2 in [-1,1), y = x1*x2 (augmented col of 1s)
mkData : Int -> (n : Int | measure n) -> (List _, List Int) .
mkData s n | n <= 0 = ([], []).
mkData s n =
  s1 = Rand.next s; s2 = Rand.next4 s1;
  x1 = Rand.unit s1; x2 = Rand.unit s2;
  (rows, ys) = mkData (Rand.next4 s2) (n - 1);
  ([x1, x2, Numeric.inexact 1] :: rows, x1 * x2 :: ys).

# augment hidden activations with the constant-1 column
augRows rss = map (fn r -> r + [Numeric.inexact 1]) rss.

# ---- forward + backward, one full-batch epoch ------------------------------
#
#   Xaug (n x 3) threads through every epoch.  Parameters live as
#   row-lists (w1rows: H rows of 3, w2: H+1) -- the small side of every
#   product -- and each epoch builds the transient 3xH weight MATRIX
#   for the batch matmul (mTranspose consumes its source by design, so
#   a reusable parameter matrix would fight the linear discipline; the
#   list transpose of an Hx3 is trivially cheap next to the n-sized
#   work).  Returns updated parameters, the epoch's MSE, and Xaug.

lTail xs = x :: r = xs; r.
lT : (c : Int | measure c) -> List _ -> List _ .
lT c rss | c <= 0 = [].
lT c rss = map (fn xs -> xs ! 1) rss :: lT (c - 1) (map (fn xs -> lTail xs) rss).

epoch : Int -> Int -> _ -> List _ -> List Int -> List _ -> List Int -> _ .
epoch n lr xaug xrows ys w1rows w2 =
  # forward: Z1 = Xaug (n x 3) * W1' (3 x H)
  w1t = M.fromRows (lT 3 w1rows);
  (z1, xaug2, w1t2) = M.mul xaug w1t;
  u0 = M.free w1t2;
  a1 = M.map relu z1;                      # JIT: one column pass, n*H cells
  (a1rows, a1b) = mAllRowsOf a1;
  u1 = M.free a1b;
  a1aug = augRows a1rows;
  yhats = map (fn r -> lDot r w2) a1aug;
  errs = zip2W (fn p y -> p - y) yhats ys;
  mse = lSum (map sq errs) / n;
  # backward
  ds = lScale (2.0 / n) errs;                # dL/dyhat per sample
  dw2 = accumRows a1aug ds (lZeros (List.len w2));
  w2h = dropLast w2;                       # hidden part of w2 (no bias)
  (z1rows, z1c) = mAllRowsOf z1;
  u2 = M.free z1c;
  dz1rows = zip2W (fn zr d -> zip2W (fn z wj -> reluGate z (wj * d)) zr w2h) z1rows ds;
  dw1rows = accumOuter dz1rows xrows (lZeros3 (List.len w2h));
  # update
  w1n = zip2W (fn wr dr -> lSub wr (lScale lr dr)) w1rows dw1rows;
  w2n = lSub w2 (lScale lr dw2);
  (w1n, w2n, mse, xaug2).

lDot : (xs : List e1 | measure xs) -> List e1 -> e1 .
lDot xs ys | xs == [] = 0.
lDot xs ys = x :: xr = xs; y :: yr = ys; x * y + lDot xr yr.

reluGate z g = case z > 0 of True -> g | False -> Numeric.inexact 0.

dropLast : (xs : List f1 | measure xs) -> List f1 .
dropLast xs | (x :: r) <- xs, r == [] = [].
dropLast xs = x :: r = xs; x :: dropLast r.

# acc += d_i * row_i, over all samples (the dW2 accumulation)
accumRows : (rows : List _ | measure rows) -> List g1 -> List g1 -> List g1 .
accumRows rows ds acc | rows == [] = acc.
accumRows rows ds acc =
  r :: rr = rows; d :: dr = ds;
  accumRows rr dr (lAdd acc (lScale d r)).

# acc_j += dz1row_i[j] * xrow_i, over all samples (the dW1 accumulation)
lZeros3 : (h : Int | measure h) -> List _ .
lZeros3 h | h <= 0 = [].
lZeros3 h = lZeros 3 :: lZeros3 (h - 1).

accumOuter : (dzs : List _ | measure dzs) -> List _ -> List _ -> List _ .
accumOuter dzs xs acc | dzs == [] = acc.
accumOuter dzs xs acc =
  dz :: dzr = dzs; x :: xr = xs;
  accumOuter dzr xr (zip2W (fn ar d -> lAdd ar (lScale d x)) acc dz).

mAllRowsOf m = M.mapRows (fn r -> r) m.

# ---- the training loop -----------------------------------------------------

train : (k : Int | measure k) -> Int -> Int -> _ -> List _ -> List Int -> List _ -> List Int -> Int -> _ .
train k n lr xaug xrows ys w1 w2 last | k <= 0 = (w1, w2, last, xaug).
train k n lr xaug xrows ys w1 w2 last =
  (w1n, w2n, mse, xaug2) = epoch n lr xaug xrows ys w1 w2;
  train (k - 1) n lr xaug2 xrows ys w1n w2n mse.

predict : List _ -> List Int -> Int -> Int -> Int .
predict w1rows w2 x1 x2 =
  z1s = map (fn wr -> lDot wr [x1, x2, Numeric.inexact 1]) w1rows;
  lDot ((map (fn z -> relu z) z1s) + [Numeric.inexact 1]) w2.

chk name got want tol = case Numeric.abs (got - want) < tol of
  True -> print "ok {name} ({got} ~ {want})"
| False -> error "FAIL {name}: {got} vs {want}".

# ---- nested Vec: works, boxed, and the checker cannot see inside -----------
nestedProbe u =
  inner = Vec.fromList [1, 2, 3];
  outer = Vec.push inner (Vec.new Unit);   # inner CONSUMED into a boxed cell
  (back, outer2) = Vec.get 1 outer;        # ...and retrieved: same store
  (s, back2) = Vec.fold (fn a x -> a + x) 0 back;
  u1 = Vec.free back2;
  u2 = Vec.free outer2;
  s.

> n = 128;
  h = 6;
  (xrows, ys) = mkData 20260827 n;
  xaug = M.fromRows xrows;
  # the input rows are LOOP-INVARIANT: extract them once for backprop
  # instead of re-walking the matrix every epoch
  w1 = initRows 977 h 3;
  w2 = (initRow 5077 h) + [Numeric.inexact 0];
  (w1t, w2t, mse, xaug2) = train 220 n 0.3 xaug xrows ys w1 w2 999;
  u0 = print "nn: final MSE {mse}  (linear-best ~ var(y) ~ 0.11)";
  k0 = chk "mse<0.02" mse 0 (Numeric.div 1 50);
  p1 = predict w1t w2t 0.8 0.8;
  p2 = predict w1t w2t (0 - 0.8) 0.8;
  k1 = chk "f(0.8,0.8)~0.64" p1 0.64 (Numeric.div 1 5);
  k2 = chk "f(-0.8,0.8)~-0.64" p2 (0 - 0.64) (Numeric.div 1 5);
  u2 = M.free xaug2;
  u3 = print "nn: nested-Vec probe sum = {nestedProbe Unit} (boxed column, works; flat Matrix stays the fast 2D encoding)";
  print "nn: OK".
