# jit.sol — the JIT tier. map/filter/foldl over int lists JIT-compile via
# LLVM ORC when the list clears the threshold (64); below it, or when the
# element function isn't arithmetic-only Core, the interpreter runs the loop.

# this basically just builds a list from 1..n
iota : unsafe Int -> List Int .
iota k | k == 0 = [].
iota k = k :: iota (k - 1).

square x = x * x.
plus a b = a + b.
big x = x > 100000.

# If the number is even, divide it by 2. If the number is odd, multiply it by 3 and add 1.
# note how (n / 2) * 2 == n is used to check for evenness, since the / operator is integer division.
# so for example, 5 / 2 = 2, and 2 * 2 = 4, which is not equal to 5, so 5 is odd.

# helper recursion inside the element fn: JITted alongside (fuel reified)
collatzLen : unsafe Int -> Int .
collatzLen n | n == 1 = 0.
collatzLen n | (n / 2) * 2 == n = 1 + collatzLen (n / 2).
collatzLen n = 1 + collatzLen (3 * n + 1).

# below threshold: interpreted (no [jit] line)
> List.fold plus 0 (List.map square (iota 10)).

# over threshold: compiled (watch the [jit] lines, each fn compiles once)
> xs = iota 2000;
  List.fold plus 0 (List.map square xs).
> xs = iota 2000;
  List.fold plus 0 (List.filter big (List.map square xs)).
# this is a bit of a stress test
> List.fold plus 0 (List.map collatzLen (iota 5000)).

# NOT jittable (string result): same call shape, interpreter takes it
shout x | x > 1995 = "big {x}".
shout x = "small".
> (List.map shout (iota 2000)) ! 1.
