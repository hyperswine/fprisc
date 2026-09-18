# algebra.sol -- the OPERATORS are the default, as an executable spec.
# Every value kind spells its natural operation with + - * / % ^: numbers,
# strings, lists, vectors, matrices, and your own types (a struct whose
# field names ARE the operators, found by the resolver from the operand
# types -- no registration, no helper names like dotProd or strConcat).
#
#   ./fpr sol sol/examples/algebra.sol

mx = use "../lib/matrix".  M = mx.M.

expect what got want = case got == want of
    True -> print "ok  {what}"
  | False -> error "FAIL {what}: got {got}, wanted {want}".

# ---- numbers: % is the truncated remainder, ^ is exact exponentiation ----
> expect "% ints"            (7 % 3, -7 % 3, 10 % 5) (1, -1, 0).
> expect "% inexact"         (7.5 % 2) 1.5.
> expect "^ exact"           (2 ^ 10, 3 ^ 3, 10 ^ 0, (-2) ^ 3) (1024, 27, 1, -8).
> expect "^ inexact base"    (2.5 ^ 2) 6.25.
> expect "precedence"        (2 + 7 % 4 * 2, 3 * 2 ^ 2, 2 ^ 3 ^ 2, 10 % 3 % 2) (8, 12, 512, 1).
> expect "% in a pipeline"   (List.range 1 10 |> List.filter (fn x -> x % 3 == 0)) [3, 6, 9].
> expect "^ in a map"        (List.map (fn x -> x ^ 2) [1, 2, 3]) [1, 4, 9].

# ---- strings and lists: + joins, - removes a matching suffix ----
> expect "string +"          ("rail" + "way" + "!") "railway!".
> expect "string -"          ("railway" - "way", "railway" - "rail") ("rail", "railway").
> expect "list +"            ([1, 2] + [3] + []) [1, 2, 3].
> expect "list -"            ([1, 2, 3] - [3], [1, 2, 3] - [9]) ([1, 2], [1, 2, 3]).
> expect "+ folds"           (List.fold (fn acc w -> acc + w + " ") "" ["a", "b"]) "a b ".

# ---- vectors: + - elementwise, * the dot product, k * v scales ----
> expect "vec +"             (Vec.toList (Vec.fromList [1, 2, 3] + Vec.fromList [4, 5, 6])) [5, 7, 9].
> expect "vec -"             (Vec.toList (Vec.fromList [1, 2, 3] - Vec.fromList [1, 1, 1])) [0, 1, 2].
> expect "vec * vec = dot"   (Vec.fromList [1, 2, 3] * Vec.fromList [4, 5, 6]) 32.
> expect "dot stays exact"   (Vec.fromList [1, 2] * Vec.fromList [3, 4]) 11.
> expect "dot inexact"       (Vec.fromList [1.5, 2] * Vec.fromList [2, 2]) 7.
> expect "k * vec"           (Vec.toList (2 * Vec.fromList [1.5, 2])) [3, 4].
> expect "vec expression"    (Vec.toList (2 * Vec.fromList [1, 2] + Vec.fromList [10, 10])) [12, 14].

# ---- matrices: + - elementwise, * matmul, m * v is matrix times vector ----
> c = M.fromRows [[1, 2], [3, 4]] * M.fromRows [[5, 6], [7, 8]];
  (rows, c2) = M.mapRows (fn r -> r) c; u = M.free c2;
  expect "mat * mat"         rows [[19, 22], [43, 50]].
> d = M.fromRows [[1, 2], [3, 4]] + M.fromRows [[10, 20], [30, 40]] - M.fromRows [[1, 1], [1, 1]];
  (rows, d2) = M.mapRows (fn r -> r) d; u = M.free d2;
  expect "mat + mat - mat"   rows [[10, 21], [32, 43]].
> expect "mat * vec"         (Vec.toList (M.fromRows [[1, 2], [3, 4]] * Vec.fromList [1, 1])) [3, 7].

# ---- your own type: the struct's field names are the operators ----
Money = Type (Money Int).
mAdd a b = Money x = a; Money y = b; Money (x + y).
mMod a b = Money x = a; Money y = b; Money (x % y).
MoneyOps = Struct { (+) = fn a b -> mAdd a b, (%) = fn a b -> mMod a b }.
cents m = Money x = m; x.
> expect "user + and %"      (cents (Money 250 + Money 175), cents (Money 425 % Money 100)) (425, 25).
> print "algebra: OK".
