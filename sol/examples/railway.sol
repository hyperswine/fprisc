# railway.sol -- railway-oriented programming is the DEFAULT, as an
# executable spec.  Every fallible step returns Ok x | Err msg; |>? threads
# Ok values and stops at the first Err; the prelude combinators are the
# only vocabulary needed.  Each line below is an assertion: the script
# panics (and therefore commits NOTHING) if any property is violated.
#
#   ./fpr sol sol/examples/railway.sol

P = use "../lib/proc".

expect what got want = case got == want of
    True -> print "ok  {what}"
  | False -> error "FAIL {what}: got {got}, wanted {want}".

positive n = case n > 0 of True -> Ok n | False -> Err "not positive: {n}".
half n = case n % 2 of 0 -> Ok (n / 2) | m -> Err "odd: {n}".

# ---- the pipe threads Ok, stops at the first Err, never runs later steps ----
> expect "pipe threads Ok"      (Try.parseInt "84" |>? positive |>? half) (Ok 42).
> expect "first Err wins"       (Try.parseInt "-3" |>? positive |>? half) (Err "not positive: -3").
> expect "parse Err propagates" (Try.parseInt "nope" |>? positive) (Try.parseInt "nope").
# a later step that WOULD panic is never reached once the rail is Err
> expect "Err skips later steps"
    (isOk (Try.parseInt "nope" |>? (fn n -> Ok (parseInt "boom")))) False.

# ---- the combinators ----
> expect "mapOk"     (mapOk (fn n -> n * 10) (Try.parseInt "4")) (Ok 40).
> expect "mapOk Err" (mapOk (fn n -> n * 10) (Try.parseInt "x")) (Try.parseInt "x").
> expect "andThen"   (andThen half (Try.parseInt "84")) (Ok 42).
> expect "mapErr"    (mapErr (fn e -> "wrapped") (half 3)) (Err "wrapped").
> expect "context"   (context "config" (half 3)) (Err "config: odd: 3").
> expect "orElse"    (orElse (Ok 0) (half 3)) (Ok 0).
> expect "orElse Ok" (orElse (Ok 0) (half 4)) (Ok 2).
> expect "okOr"      (okOr 7 (half 3)) 7.
> expect "unwrap"    (unwrap (half 4)) 2.
> expect "isOk"      (isOk (half 4), isOk (half 3)) (True, False).
> expect "collect"   (collect [half 2, half 4, half 6]) (Ok [1, 2, 3]).
> expect "collect first Err" (collect [half 2, half 3, half 5]) (Err "odd: 3").

# ---- absence is a VALUE, not a panic ----
> expect "Try.readPath absent" (isOk (Try.readPath @/tmp/sol-railway-never.txt)) False.
> expect "readPathOr"          (readPathOr "dflt" @/tmp/sol-railway-never.txt) "dflt".

# ---- processes are railway steps too ----
> expect "Proc.query ok"
    (P.output (Proc.query (P.spec ["/bin/sh", "-c", "printf fine"]))) (Ok "fine").
> expect "Proc.query nonzero is Err"
    (mapErr (fn e -> Str.contains "oops" e)
      (P.output (Proc.query (P.spec ["/bin/sh", "-c", "echo oops >&2; exit 3"])))) (Err True).

# ---- a whole file pipeline on the rails ----
sumFile p =
  Try.readPath p
    |>? (fn s -> collect (List.map Try.parseInt (Str.lines s)))
    |>? (fn ns -> Ok (List.sum ns)).
> u1 = writePath @/tmp/sol-railway-good.txt "10\n20\n30\n";
  u2 = writePath @/tmp/sol-railway-bad.txt "10\ntwenty\n30\n";
  expect "own writes are visible in-txn" (sumFile @/tmp/sol-railway-good.txt) (Ok 60).
> expect "bad line derails" (isOk (context "config" (sumFile @/tmp/sol-railway-bad.txt))) False.
> u1 = rm @/tmp/sol-railway-good.txt; u2 = rm @/tmp/sol-railway-bad.txt;
  print "railway: OK".
