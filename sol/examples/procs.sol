# procs.sol -- shelling out, as an executable spec.  ProcessSpec keeps argv
# STRUCTURED (no shell, no quoting bugs); results are Result values, so a
# tool is just another railway step.  Three doors, one rule each:
#
#   Proc.query      immediate, read-only tools; Result, never panics
#   Proc.afterCommit  queued; runs INSIDE commit exactly once
#   Proc.runNow     realtime; REFUSED while any effect is queued
#   sh cmd          immediate (code, out)  -- reruns on every retry attempt
#   shq cmd         queued, Unit           -- once, at commit
#
#   ./fpr sol sol/examples/procs.sol

P = use "../lib/proc".
Git = use "../lib/git".

expect what got want = case got == want of
    True -> print "ok  {what}"
  | False -> error "FAIL {what}: got {got}, wanted {want}".

query argv = P.output (Proc.query (P.spec argv)).

# ---- argv is structured: spaces and globs survive verbatim ----
> expect "argv verbatim"
    (query ["/bin/sh", "-c", "printf '%s|%s' \"$1\" \"$2\"", "sh", "a b", "c*d"]) (Ok "a b|c*d").
> expect "env overlay"
    (P.output (Proc.query (P.withEnv "SOL_X" "42" (P.spec ["/bin/sh", "-c", "printf $SOL_X"])))) (Ok "42").
> expect "stdin"
    (P.output (Proc.query (P.withStdin "piped" (P.spec ["/bin/cat"])))) (Ok "piped").
> expect "cwd"
    (P.output (Proc.query (P.inDir "/tmp" (P.spec ["/bin/pwd"])))) (Ok "/tmp\n").

# ---- failure is a VALUE ----
> expect "missing binary is Err" (isOk (query ["/no/such/binary"])) False.
> expect "nonzero is Err"        (isOk (query ["/bin/sh", "-c", "exit 2"])) False.
> expect "timeout is Err"
    (isOk (P.output (Proc.query (P.withTimeout 10 (P.spec ["/bin/sleep", "2"]))))) False.
> expect "succeeded" (P.succeeded (Proc.query (P.spec ["/bin/true"])),
                      P.succeeded (Proc.query (P.spec ["/bin/false"]))) (True, False).

# ---- two tools compose on the rails ----
> expect "pipeline"
    (query ["/bin/sh", "-c", "printf 'b\na\nc\n'"]
       |>? (fn s -> query ["/usr/bin/sort"] |> (fn r -> Ok s))
       |>? (fn s -> P.output (Proc.query (P.withStdin s (P.spec ["/usr/bin/sort"]))))
       |>? (fn s -> Ok (Str.lines s))) (Ok ["a", "b", "c"]).

# ---- ordering is enforced by the runtime ----
# (an immediate `sh` for scratch cleanup: it reruns per retry attempt, which
#  is harmless here and exactly why mutations normally go through shq)
> (c, o) = sh "rm -f /tmp/sol-procs-order.txt";
  u = Proc.afterCommit (P.spec ["/bin/sh", "-c", "printf queued > /tmp/sol-procs-order.txt"]);
  expect "query sees pre-commit state"
    (readPathOr "absent" @/tmp/sol-procs-order.txt) "absent".
> u = Proc.afterCommit (P.spec ["/bin/true"]);
  expect "runNow refused while queued"
    (mapErr (fn e -> Str.contains "queued" e) (Proc.runNow (P.spec ["/bin/true"]))) (Err True).

# ---- the string doors ----
> expect "sh" (sh "printf hi; exit 0") (0, "hi").
> expect "sh nonzero" (sh "exit 4") (4, "").

# ---- Git wrapper: queries are Results, push discipline is enforced ----
> expect "Git.status on a non-repo is Err"
    (isOk (Git.status (Git.repo "/tmp/sol-procs-not-a-repo"))) False.
> r = Git.repo "/tmp/sol-procs-repo" |> Git.init;
  expect "push after a queued mutation is refused"
    (mapErr (fn e -> Str.contains "queued" e) (Git.push "origin" "main" r)) (Err True).
> print "procs: OK".
