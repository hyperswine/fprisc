# tabling.sol — auto-tabling at dynamic dispatch, gated per
# TablingModel.hs: compile-time eligibility (pure arithmetic Core,
# self-recursion allowed) -> optimistic table on first entry (so
# recursion memoizes its own subcalls) -> post-hoc brake (fast AND
# shallow first call = table dropped) -> LRU-capped probe path.
fib : unsafe Int -> Int .
fib n | n < 2 = n.
fib n = fib (n - 1) + fib (n - 2).
cheap x = x + 1.

> a = fib 27;
  b = cheap 5;
  c = fib 27;
  print "tabling: fib 27 = {a} / again = {c} / cheap = {b}" .
