# unbox bench: a typical Sol script loop -- build, map, filter, fold a list
iota : (k : Int | measure k) -> List Int .
iota k | k <= 0 = [].
iota k = k :: iota (k - 1).
sq x = x * x.
odd x = x % 2 == 1.
plus a b = a + b.
> print "sol_loop {List.fold plus 0 (List.filter odd (List.map sq (iota 1000000)))}".
