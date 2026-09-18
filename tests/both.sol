# both.sol — ONE file, ONE grammar, TWO profiles.
#   AOT:            ./fprc --sol --profile=bare-metal ... tests/both.sol
#   HostedBytecode: sol/sol tests/both.sol
# Everything here is the surface intersection: clauses, guards, fn
# lambdas, blocks, interpolation, and `>` top-level eval.

double x = x * 2.

classify x | x == 0 = "zero".
classify x | x > 0 = "pos".
classify _ = "neg".

sumTo : unsafe Int -> Int .
sumTo n = go 1 n 0.
go : unsafe Int -> Int -> Int -> Int .
go i n acc = case i > n of
  True -> acc
  | False -> go (i + 1) n (acc + i).

> s = sumTo 10; print "both: sumTo(10)={s} double={double 21} k={classify (0 - 5)}".
