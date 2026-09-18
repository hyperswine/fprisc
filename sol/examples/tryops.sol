# tryops.sol — the Ok/Err DEFAULT PATTERN, executable spec.
#
# Fallible work returns `Ok x | Err msg` and chains with |>?: the pipe
# short-circuits on the first Err and threads Ok values through. The
# HAL's fallible primitives are the Try.* family; the panicking
# spellings are prelude sugar over them:
#
#   parseInt s   = unwrap (Try.parseInt s)     # panic on Err
#   readPath p   = unwrap (Try.readPath p)     # ABSENCE IS NOT "": panic
#   readPathOr d = okOr d (Try.readPath p)     # absence -> default
#
# So the honest tier is always underneath, and how much you care about
# the failure is spelled at the call site: unwrap / okOr / a case.

# a fallible step of our own: same shape as any Try.* primitive
half n = case n % 2 of
  0 -> Ok (n / 2)
| m -> Err "cannot halve odd {n}".

# chains short-circuit on the first Err
> r1 = Try.parseInt "84" |>? half |>? half;
  print "84 halved twice: {r1}".
> r2 = Try.parseInt "84" |>? half |>? half |>? half;
  print "once more:       {r2}".
> r3 = Try.parseInt "eighty-four" |>? half;
  print "bad input:       {r3}".

# the prelude's combinators: stay on the rails, recover, report, gather
> up = mapOk (fn n -> n * 10) (Try.parseInt "4");
  print "mapOk:           {up}".
> step = andThen half (Try.parseInt "84");
  print "andThen:         {step}".
> back = orElse (Ok 0) (Try.parseInt "not-a-number");
  print "orElse:          {back}".
> said = context "reading config" (Try.readPath @/tmp/sol-tryops-never.txt);
  print "context:         {said}".
> every = collect [Try.parseInt "1", Try.parseInt "2", Try.parseInt "3"];
  print "collect all Ok:  {every}".
> stopped = collect [Try.parseInt "1", Try.parseInt "two", Try.parseInt "3"];
  print "collect first Err: {stopped}".

# collapse a Result when you know what the failure should mean
> d = okOr 0 (Try.parseInt "not-a-number");
  print "okOr default:    {d}".
> m = mapOk (fn n -> n * 100) (Try.parseInt "7");
  print "mapOk:           {m}".

# files: absence is an expected case here, so say so at the call site
> c = readPathOr "0" @/tmp/sol-tryops-count.txt;
  n2 = parseInt c + 1;
  u = writePath @/tmp/sol-tryops-count.txt "{n2}";
  print "run count now:   {n2}".

# and the honest spelling when you want to branch yourself
> f = case Try.readPath @/tmp/sol-tryops-never.txt of
        Ok s -> "exists: {s}"
      | Err e -> "as expected: {e}";
  print f.
