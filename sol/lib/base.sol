# base.sol -- the base library: the few string/list helpers that have NO
# prelude builtin.  Everything that duplicated Str.* / List.* / and-or-not
# has been retired (2026-09-02-DESIGN_PATTERNS.md: no two names in scope may mean the
# same thing); reach for the builtin.

# "" -> 0, otherwise the exact integer (Try.parseInt for the rails)
pI s = case s == "" of True -> 0 | False -> Str.parse s.
max0 n = Numeric.max 0 n.
boolInt b = case b of True -> 1 | False -> 0.
nl = Str.fromCode 10.

# drop the element at 0-based position k (out of range: unchanged)
removeAt k xs = case xs of
  [] -> []
| x :: r -> (case k == 0 of True -> r | False -> x :: removeAt (k - 1) r).

# split at the first space: (head, rest)
splitFirst s = k = Str.find 32 s; case k < 0 of True -> (s, "") | False -> (Str.slice s 0 k, Str.slice s (k + 1) (Str.len s)).

# last path segment
baseName p =
  k = lastSlash p 0 (0 - 1);
  case k < 0 of True -> p | False -> Str.slice p (k + 1) (Str.len p).
lastSlash p i best | i >= Str.len p = best.
lastSlash p i best = case Str.at p i == 47 of True -> lastSlash p (i + 1) i | False -> lastSlash p (i + 1) best.

# each item paired with its 0-based position: [(0, x0), (1, x1), ..]
indexed xs = List.zip (List.range 0 (List.len xs - 1)) xs.

# the first element, or d when there is none
firstOr d [] = d.
firstOr d (x :: _) = x.

# print each line, in order; the result counts them
say lines = List.fold (fn n l -> u = print l; n + 1) 0 lines.
