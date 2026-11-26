# The Sol half of the bit-operation parity (see bits.fpr).
vals = [0, 1, 2, 3, 255, 256, 65535, 0 - 1, 0 - 2, 0 - 256, 1234567891011, 0 - 987654321, 4611686018427387903, 0 - 4611686018427387903 - 1, 2305843009213693952].
ks = [0, 1, 7, 8, 31, 32, 62, 63].
row v = List.fold (fn a k -> print "{v} {k} {BITSHIFTL v k} {BITSHIFTR v k} {BITSET v k} {BITCLEAR v k} {BITTEST v k} {BITMASK k 3}") Unit ks.
pair a b = print "{band a b} {bor a b} {bxor a b}".
> _ = List.fold (fn a v -> row v) Unit vals; List.fold (fn a x -> List.fold (fn c y -> pair x y) Unit vals) Unit vals.
