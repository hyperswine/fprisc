# ONE grammar: native base execution and the hosted sketch of that program.
# The explicit declaration overrides the .sol filename's default profile.
#   AOT: make bare-metal-run PROG=tests/both.sol
#   VM:  ./fpr sol tests/both.sol
profile base.

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

main = s = sumTo 10; print "both: sumTo(10)={s} double={double 21} k={classify (0 - 5)}".
