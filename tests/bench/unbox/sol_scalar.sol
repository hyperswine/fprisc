# unbox bench baseline: the same Sol computation as a scalar loop, no list
go : unsafe Int -> Int -> Int .
go k acc | k <= 0 = acc.
go k acc = go (k - 1) (if (k * k) % 2 == 1 then acc + k * k else acc).
> print "sol_loop {go 1000000 0}".
