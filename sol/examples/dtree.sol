# dtree.sol — decision tree (depth 2) on an axis-aligned concept:
# y = +1 iff (x1 > 0.25 AND x2 > -0.5), 5% label noise — a nested-rectangle
# rule that greedy induction recovers exactly (root split on x1, then x2).
# Honest ML footnote: we first tried XOR (y = sign(x1*x2)); every root
# split has ~zero first-order gain there, so greedy scan picks on noise and
# depth 2 collapses to ~52% — the classic greedy-tree pathology, faithfully
# reproduced. Trees need lookahead (or luck) for XOR; that is the
# algorithm, not the runtime.
#
# Numeric refactor: features, thresholds, and labels are plain Numerics
# (labels stay the exact ints +1/-1); the packed base-1024 counting fold
# is untouched int arithmetic — only the `xv < th` comparison touches the
# inexact tier, and promotion handles it in place.

rnd = use "../lib/rand".
Rand = rnd.Rand.

Tree = Type (Leaf x | Node a b c d). # Node feat thresh left right

quarter = Numeric.div 1 4.
minusHalf = 0 - Numeric.div 1 2.

mkRow s =
  sa = Rand.next s;
  x1 = Rand.gauss4 sa;
  sb = Rand.next4 sa;
  x2 = Rand.gauss4 sb;
  sc = Rand.next4 sb;
  flip = Rand.uniform sc 20; # 5% label noise
  ytrue = case x1 > quarter of
    False -> 0 - 1
  | True -> (case x2 > minusHalf of True -> 1 | False -> 0 - 1);
  {x1 = x1, x2 = x2, y = case flip == 0 of True -> 0 - ytrue | False -> ytrue}.

# k rows from seed s, pushed in the order k, k-1, .. 1
fill v s k = List.range 1 k |> List.rev |> List.fold (fn acc j -> Vec.push (mkRow (Rand.next (s + j * 100003))) acc) v.

# the packed counting fold: (feat, th) captured; four counts in one i64
cnt feat th acc p =
  xv = case feat == 1 of True -> p.x1 | False -> p.x2;
  pos = case p.y > 0 of True -> 1 | False -> 0;
  case xv < th of
    True -> acc + (case pos == 1 of True -> 1073741824 | False -> 1048576)
  | False -> acc + (case pos == 1 of True -> 1024 | False -> 1).

posCnt acc p = acc + (case p.y > 0 of True -> 1 | False -> 0).

# misclassification score of a split: each side predicts its majority
scoreOf c =
  lp = c / 1073741824; ln = (c / 1048576) % 1024;
  rp = (c / 1024) % 1024; rn = c % 1024;
  Numeric.min lp ln + Numeric.min rp rn.

# scan candidates, threading the linear vec through the fold; the first
# strictly best split wins. Returns (feat, th, score, v)
scan cands v = List.fold scanStep (0, 0, 999999, v) cands.

scanStep (bf, bt, bs, v) (feat, th) =
  (packed, v2) = Vec.fold (cnt feat th) 0 v;
  s = scoreOf packed;
  case s < bs of
    True -> (feat, th, s, v2)
  | False -> (bf, bt, bs, v2).

grid = List.range (0 - 6) 6 |> List.map (fn k -> k * quarter). # -1.5 .. 1.5 step 0.25

allCands = (grid |> List.map (fn t -> (1, t))) + (grid |> List.map (fn t -> (2, t))).

pick 1 p = p.x1.
pick _ p = p.x2.

# split the rows at (feat, th); each side comes out in reverse order
part feat th xs = List.fold (side feat th) ([], []) xs.
side feat th (ls, rs) p | pick feat p < th = (p :: ls, rs).
side feat th (ls, rs) p = (ls, p :: rs).

buildVec xs v = List.fold (fn acc p -> Vec.push p acc) v xs.

majorityLeaf n np = Leaf (case np * 2 >= n of True -> 1 | False -> 0 - 1).

# recursive build: packed-count scan for the split, interpreted partition
build : unsafe Int -> (Vector _) -> Tree .
build depth v =
  (n, v0) = Vec.len v;
  (np, v1) = Vec.fold posCnt 0 v0;
  case depth == 0 of
    True -> finishLeaf n np v1
  | False -> tryNode depth n np v1.

finishLeaf n np v = u = Vec.free v; majorityLeaf n np.

tryNode : unsafe Int -> Int -> Int -> (Vector _) -> Tree .
tryNode depth n np v =
  case np == 0 of
    True -> finishLeaf n np v
  | False -> (case np == n of
      True -> finishLeaf n np v
    | False -> splitNode depth n v).

splitNode : unsafe Int -> Int -> (Vector _) -> Tree .
splitNode depth n v =
  (bf, bt, bs, v2) = scan allCands v;
  xs = Vec.toList v2;
  (ls, rs) = part bf bt xs;
  l = build (depth - 1) (buildVec ls (Vec.new Unit));
  r = build (depth - 1) (buildVec rs (Vec.new Unit));
  Node bf bt l r.

predict : unsafe Tree -> _ -> i46 .
predict (Leaf c) _ = c.
predict (Node f th l _) p | pick f p < th = predict l p.
predict (Node _ _ _ r) p = predict r p.

# how many rows the tree classifies correctly
correct : unsafe Tree -> List _ -> Int .
correct t xs = xs |> List.filter (fn p -> predict t p * p.y > 0) |> List.len.

chkAtLeast name got want = case got >= want of
  True -> print "ok {name} ({got} >= {want})"
| False -> error "FAIL {name}: {got} < {want}".

showT : unsafe Tree -> String .
showT t = case t of
  Leaf c -> "Leaf({c})"
| Node f th l r -> "Node(x{f} < {th}: {showT l} | {showT r})".

> n = 400;
  train_v = fill (Vec.new Unit) 13371337 n;
  tree = build 2 train_v;
  u0 = print "tree: {showT tree}";
  test_v = fill (Vec.new Unit) 55667788 200;
  xs = Vec.toList test_v;
  acc = correct tree xs;
  u1 = print "test accuracy: {acc * 100 / 200}% (5% label noise ceiling ~95%)";
  chkAtLeast "test accuracy %" (acc * 100 / 200) 85.
