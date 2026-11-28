# base.sol -- the base library: the few string/list helpers that have NO
# prelude builtin.  Everything that duplicated Str.* / List.* / and-or-not
# has been retired (2026-09-02-DESIGN_PATTERNS.md: no two names in scope may mean the
# same thing); reach for the builtin.

# "" -> 0, otherwise the exact integer (Try.parseInt for the rails)
pI s = if s == "" then 0 else Str.parse s.
max0 n = Numeric.max 0 n.
boolInt b = if b then 1 else 0.
nl = Str.fromCode 10.

# drop the element at 0-based position k (out of range: unchanged)
removeAt : Int -> (xs : List a | measure xs) -> List a .
removeAt k xs = case xs of
  [] -> []
| x :: r -> if k == 0 then r else x :: removeAt (k - 1) r.

# split at the first space: (head, rest)
splitFirst s =
  k = Str.find 32 s;
  if k < 0 then (s, "") else (Str.slice s 0 k, Str.slice s (k + 1) (Str.len s)).

# last path segment
baseName p =
  k = lastSlash p 0 (Str.len p) (0 - 1);
  if k < 0 then p else Str.slice p (k + 1) (Str.len p).
lastSlash : String -> Int -> (rem : Int | measure rem) -> Int -> Int .
lastSlash p i rem best =
  if rem <= 0 then best
  else if Str.at p i == 47 then lastSlash p (i + 1) (rem - 1) i
  else lastSlash p (i + 1) (rem - 1) best.

# each item paired with its 0-based position: [(0, x0), (1, x1), ..]
indexed xs = List.zip (List.range 0 (List.len xs - 1)) xs.

# the first element, or d when there is none
firstOr d [] = d.
firstOr d (x :: _) = x.

# print each line, in order; the result counts them
say lines = List.fold (fn n l -> u = print l; n + 1) 0 lines.

# immediate streaming writes: bypass the file transaction so scripts that
# write files and then run external processes do not trip the queued-write check
writeBytesNow path bytes =
  writer = unwrap (Stream.openWrite path (Bytes.len bytes));
  (result, next) = Stream.writeChunk bytes writer;
  _ = unwrap result;
  Stream.closeWrite next.
writeTextNow path text = writeBytesNow path (unwrap (Utf8.encode text)).
