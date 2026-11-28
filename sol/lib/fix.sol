# fix.sol — Q16.16 fixed-point arithmetic. Every function here is
# arithmetic-only Sol, i.e. JITtable: an element function that calls
# fix.fmul or fix.fsqrt pulls this whole library into its native closure.
#
# Conventions: 1.0 = 65536. Keep |x| < ~20000.0 so products stay inside
# i64 (the JIT is 64-bit; the interpreter is bignum — staying in range is
# what keeps the two bit-identical). fdiv/fsqrt guard zero denominators.

one = 65536.
half = 32768.

fromInt n = n * 65536.
toInt x = x / 65536.
toMilli x = (x * 1000) / 65536.

fmul a b = (a * b) / 65536.
fdiv a b = if b == 0 then 0 else (a * 65536) / b.
fabs x = if x < 0 then 0 - x else x.
fmin a b = if a < b then a else b.
fmax a b = if a > b then a else b.

# Newton-Raphson square root, 18 iterations: y' = (y + x/y) / 2
fsqrtGo x y k | k == 0 = y.
fsqrtGo x y k = fsqrtGo x ((y + fdiv x y) / 2) (k - 1).

fsqrt x | x <= 0 = 0.
fsqrt x = fsqrtGo x (if x > 65536 then x / 2 else 65536) 18.
