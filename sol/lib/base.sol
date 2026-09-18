# base.sol -- the base library: the few string/list helpers that have NO
# prelude builtin.  Everything that duplicated Str.* / List.* / and-or-not
# has been retired (DESIGN_PATTERNS.md: no two names in scope may mean the
# same thing); reach for the builtin.

# "" -> 0, otherwise the exact integer (Try.parseInt for the rails)
pI s = case s == "" of True -> 0 | False -> Str.parse s.
max0 n = Numeric.max 0 n.
boolInt b = case b of True -> 1 | False -> 0.
nl = Str.fromCode 10.

removeAt k xs | xs == [] = [].
removeAt k xs = case xs of
  x :: r -> (case k == 1 of True -> r | False -> x :: removeAt (k - 1) r).

# split at the first space: (head, rest)
splitFirst s = k = Str.findFrom 32 s 1; case k of 0 -> (s, "") | _ -> (Str.slice s 1 (k - 1), Str.slice s (k + 1) (Str.len s)).

# last path segment
baseName p =
  k = lastSlash p 1 0;
  case k == 0 of True -> p | False -> Str.slice p (k + 1) (Str.len p).
lastSlash p i best | i > Str.len p = best.
lastSlash p i best = case Str.at p i == 47 of True -> lastSlash p (i + 1) i | False -> lastSlash p (i + 1) best.
