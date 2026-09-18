# Sol transactions: the SCRIPT is the transaction

The unit of atomicity in the HostedBytecode profile is the **whole
script run**, not the individual `>` eval.  This was always what the
runtime did; this document makes it what the design *says*.

## The model

    fpr sol script.sol
    ├── snapshot        one read view of the world, taken at entry
    ├── > eval 1        ─┐
    ├── > eval 2         │  sequential PHASES of one transaction:
    ├── ...              │  same snapshot, same write journal
    ├── > eval N        ─┘
    └── commit          ONE atomic commit of the whole journal — or
                        nothing at all

Consequences, each of which is checked in the sweep:

1. **Abort is total.**  A panic in phase N unwrites phases 1..N-1.
   There is no partial state: either the whole script's effects land
   or none do.  (tests/txnabort.sol: phase one writes a file, phase
   two divides by zero, the file must not exist afterwards.)

2. **Retry is whole-script.**  A commit-time conflict (another
   transaction touched the read set) re-executes the ENTIRE script
   against a fresh snapshot — not the conflicting eval.  Phases may
   observe each other's in-transaction writes, so re-running a suffix
   would be unsound; re-running everything is both correct and simple.
   (`SOL_FORCE_RETRY=n` demonstrates: the script's phases all run
   n+1 times, the commit lands once.)

3. **`>` is sequencing, not scoping.**  Multiple evals exist for
   reading order and for interleaving with top-level definitions.
   They share one journal; splitting a script into more evals never
   changes what commits.

4. **Escapes are named.**  `realtime` blocks step outside the
   transaction (their effects are immediate and unjournaled); the
   runtime prints a notice when a run used one, because the word
   "atomically" in the commit line is only true of the journaled set.

## External processes

Structured processes carry raw argv, cwd, environment overrides, stdin,
and a timeout.  They do not pass through a shell, and stdout and stderr
remain separate.  Their execution spelling states the retry contract:

* `Proc.query spec` runs while evaluating the script.  It is for read-only
   queries and runs again if the whole transaction retries.
* `Proc.afterCommit spec` enters the redo journal.  Validation happens
   before it runs, so an ordinary conflict never executes it.  A nonzero
   exit stops later queued processes, the run exits unsuccessfully, and
   already-validated file effects still reach their goal states.
* `Proc.runNow spec` is an explicit realtime escape.  It runs immediately,
   survives rollback, and runs again on retry.  The runtime names this loss
   of atomicity.

Immediacy is also an ORDERING claim, and that is the trap the runtime now
closes.  Queued effects -- file writes, `shq`, `Proc.afterCommit` -- happen
at commit, so a realtime escape necessarily runs *before* all of them.  A
script that queued a Git commit and then pushed in the same run published
the pre-commit head and reported success.  So `Proc.runNow` refuses while
any effect is pending, returning an `Err` that names what is still queued,
and `shNow` -- which answers an exit code and cannot refuse -- prints the
same inversion to stderr.  Either queue the operation as well, or split the
work into two script runs.

Deferred processes have **at-least-once crash recovery**, not exactly-once
delivery.  The journal records a durable done marker after a process
returns.  A hard crash between the external effect and that marker can
therefore re-run the process during recovery.  Wrappers should use
idempotent operations, compare-and-swap guards such as Git
`--force-with-lease`, or application-level idempotency keys where this
window matters.  No API should describe a deferred external process as
rollback-safe.

## Why one commit and not one per eval

Per-eval commits would make `>` a semantic boundary: moving a binding
across evals could change crash behavior, and a script could be left
half-applied — exactly the "half-done mess" the fileops example
exists to rule out.  With script-level atomicity, `>` placement is a
readability choice, the crash contract is binary, and the retry story
has one rule instead of a rule per boundary.

## The commit line

    [sol] committed 2 file(s) atomically (whole-script transaction)
    [sol] committed 0 file(s) + 3 deferred command(s) atomically (whole-script transaction)

names the unit explicitly so a log reader knows the count covers the
entire run, and names every effect class that landed: a script that
only queued `shq` / `Proc.afterCommit` work still did something at
commit, so it still gets a receipt.  A failed deferred command turns
the line into `committed N file(s); NOT atomic: ...` and the exit code
nonzero.

The executable specs for these properties live in
`sol/examples/{txn_iso,railway,procs,strings}.sol` (one run each) and
`tools/sol-txn-check.sh` (panic rollback, retry-once, race
serialization, fenced commands -- the ones that need a harness).
