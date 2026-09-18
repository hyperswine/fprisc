# stddemo.sol — the HostedBytecode profile consuming the SAME std tier
# (fp-risc/std): sol uses std; std does not need sol.
std = use "../../std/std".

nums = [3, 1, 4, 1, 5, 9, 2, 6].
t = std.total std.Num nums.
doubled = std.mapKeep std.ListS std.ListS (fn x -> x * 2) (fn x -> x > 4) nums.
avg = std.average nums.

> print "std via sol: total={t} avg={avg} doubled={doubled}".
