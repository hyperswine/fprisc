# Sol effects: the commit contract, its gaps, and `Deferred a`

Date: 2026-09-30. Kind: review of the commit path, plus a decision record and
plan. Scope: the HostedBytecode profile (`fpr sol`) at source revision
`03ec489` (Sol runtime code unchanged since `cb71302`). Evidence: a source
reading of `compiler/Sol/Txn.hs`, `compiler/Sol/Main.hs`, `compiler/Sol/VM.hs`
and `sol/lib/git.sol`; nothing was built or executed for this page, so every
finding below still needs its test before it counts as confirmed.

Status: **decided** -- `Deferred a` is the abstraction for effects outside the
file transaction. **Not implemented.** The four commit-path gaps are
unfixed at this revision.

Builds on [2026-08-25-TRANSACTION.md](2026-08-25-TRANSACTION.md) (the script
is the transaction) and
[2026-09-29-Sol-Improvements-Needed.md](2026-09-29-Sol-Improvements-Needed.md).

## 1. The contract

This is the sentence the runtime has to make true:

> A Sol run exits 0 **if and only if** every effect it queued reached its goal
> state. Otherwise it exits non-zero, and either nothing was written, or the
> redo journal holds exactly what remains and the next contender finishes it.

Spelled out:

- Reads snapshot exact bytes; writes, removes and mkdirs go to an in-memory
  view and an ordered effect log. Nothing touches the disk during the run.
- Commit: lock every touched path in sorted order, re-validate every read
  (bytes and directory listings), write the fsynced journal (the commit
  point), replay the log, clear the journal, unlock.
- A conflict re-runs the whole script. A panic before the commit point
  writes nothing. A crash after it is redone.

What the tree already gets right: all of the above, for the success path and
the crash path. `mkdir` lock directories with an owner file, rather than
`flock`, are the right choice and stay: the design needs a dead owner's locks
to keep fencing writers until someone finishes its journal, and `flock`
releases on death.

## 2. Where the tree breaks the contract

Ordered by severity. Each has the test that should confirm it first, in the
style of the existing `SOL_CRASH_AT` legs.

### G1. A replay failure releases the locks over a torn state

`commit` runs inside `withLocks`, whose `finally` releases every lock. If
`writeAtomic` throws halfway through `replayEffs` (disk full, permission
denied), the exception propagates, the locks are released, and the journal is
left behind -- but only the *same script* recovers it (`recoverJournal` at
startup of that script). Until then other scripts can see some files new and
some old.

**Fix:** on an exception after the journal is written, do not release. Leave
the lock directories owned by the (about to die) pid; the existing
dead-owner reclaim in `tryReclaim` already finishes the journal for whoever
contends next. Release only on the success path and on pre-journal failures.

**Test:** make the second of two target files unwritable, run a script that
writes both, then run a *different* script that reads both. It must either
wait and then see both new, or fail; never see one of each.

### G2. A failed remove exits 0

In `replayEffs`, an `ERemove` or `ERmdir` whose target still exists logs
"effect FAILED (not counted)" but does not set the failure flag, so `Main`
reports success.

**Fix:** set the same flag a failed deferred command sets, and exit non-zero.

**Test:** `rm` a path that is a non-empty directory; expect a non-zero exit.

### G3. The journal belongs to the script, not the run

`journalFile = dropExtension path ++ ".soljournal"`. Two concurrent runs of
the same script (cron plus a manual run) with disjoint write sets never
contend on a lock, but they share one journal file: one overwrites or clears
the other's, and a crash in either then loses its recovery.

**Fix:** one journal per run (`<script>.soljournal/<pid>-<nonce>`). At
startup, recover every journal in that directory whose owner pid is dead;
leave live owners' journals alone.

**Test:** two runs of one script writing different files, with
`SOL_CRASH_AT` on the first; the second finishes normally and the first's
effects are redone on the next start.

### G4. Output has one channel for two jobs

`print` writes `/dev/out` straight to stdout (`writeIoH` in `VM.hs`). That is
right for what most prints are -- telling the person running the script what
it is doing -- but it is the only output there is, so a line that *records*
what the script did gets the same treatment: printed once per retried
attempt, and printed even when the run later panics and commits nothing.

**Decision (2026-09-30):** two operations, split by what the line means.

- **`print` is a direct effect.** Throwaway, user-facing progress on stdout
  or stderr. It happens when it is called, repeats on retry, and survives an
  abort. It is documented as such, and it is not counted among the realtime
  escapes -- being immediate is its purpose, not a loss of atomicity.
- **`log` is transactional.** A semantically meaningful record of an action
  the script took. Log entries join the effect log: discarded on retry and
  on panic, emitted only after a successful commit, and exactly once per
  committed run. A log line therefore means the thing it describes happened.
  Where entries go (stdout after commit, an append to a log path under the
  same lock as the files, or both) is a parameter; appending to a path makes
  the log an audit trail that commits atomically with the changes it
  describes.

The runtime's own retry diagnostic already goes to stderr, so repeated
`print` output stays explainable.

**Test:** `SOL_FORCE_RETRY=2` on a script that prints once and logs once:
three printed lines, one logged line. A script that logs and then panics:
zero logged lines.

### Smaller points

- `writeAtomic` creates a new file and renames it over the target, so the
  target's mode (an executable loses `+x`) and a symlink at the path are
  lost. Copy the mode across; decide explicitly whether a symlink is written
  through or replaced.
- The journal stores the full contents of every written file, so each commit
  writes its data twice. That is correct; it is the first thing to measure
  if bulk commits get slow.
- A write with no prior read is not validated: the last committed writer
  wins. That is serializable under the locks and needs no change, but belongs
  in the reference.

## 3. Decision: `Deferred a`

### The observation

An effect has to run *during* the script only when the script needs its
**result**. Dependence on the effect's **side effect** does not count: the
effect log already keeps order. Five kinds of dependency, and what each
needs:

| kind | example | needs |
|---|---|---|
| 1. through world state, in order | `git add`, then `git commit` | the ordered log (exists) |
| 2. on an earlier step succeeding | do not push if the commit failed | stop-on-failure (exists) |
| 3. one effect's result feeding another effect | tag the new commit's sha | `Deferred a` (this page) |
| 4. external state deciding what to do | skip if `git status` is clean | a direct query (exists) |
| 5. a result the script's own logic or files need | write an API's returned id into a config file that commits with everything else | immediate execution and an inverse (future) |

Kinds 1 to 4 cover nearly every script this profile is for: git, deploys,
API calls, maintenance. So deferral is the default, and immediate execution
is the exception that has to be named.

### The type

`Deferred a` is the result of an effect that will run at commit. The script
can pass it to other deferred effects but cannot inspect it; the type is
what enforces "runs later".

```text
Proc.later    : ProcessSpec -> Deferred ProcessResult.
Deferred.out  : Deferred ProcessResult -> Deferred String.     -- stdout
Deferred.trim : Deferred String -> Deferred String.
Deferred.line : Int -> Deferred String -> Deferred String.
Deferred.field : String -> Int -> Deferred String -> Deferred String.

Arg = Type (Lit String | From (Deferred String)).
ProcessSpec gains argv : List Arg.
```

`Proc.afterCommit` becomes `Proc.later` with the result dropped, and stays
as a spelling for compatibility.

### The constraint: the plan must be data

The journal must hold the whole remaining plan, so that a crash after the
commit point can be redone without the script. Closures cannot be journaled.
Therefore, in v1:

- **No `map` with an arbitrary function and no bind.** A `Deferred` is a
  reference to an earlier step's output plus a projection from a small,
  closed vocabulary (`out`, `trim`, `line`, `field`, later a JSON path).
  Every projection is a constructor, so the plan serializes like everything
  else in the journal.
- **No branching at commit time.** Deciding *whether* to run something is
  kind 4: a direct query at script time.
- Growing the projection vocabulary is cheap. Admitting general functions
  would need the journal to reference compiled code by content hash, which
  can wait until it is actually wanted.

### Queries are direct

`Proc.query` stays a **direct** effect: it runs when called, during the
script, and its result is an ordinary value the script can branch on. It is
not deferred and not re-validated at commit. That is what makes kind 4 cheap:
"skip if `git status` is clean" is an ordinary `case` on a query result.

The cost is stated rather than hidden: a decision based on a query is not
protected against the external state changing between the query and the
commit. For files, the read set gives that protection; for queries it does
not. If a script ever needs it, the extension is an opt-in checked query
(`Proc.queryChecked`) whose spec and output join the read set and are re-run
and compared under the locks. It is not part of v1, and a nondeterministic
command must never use it, since its output would conflict on every attempt.

### Journal and exit status

- Journal format `SOLJ2`: the effect log with `Arg` references intact.
  `.done` records, for each completed step, its index **and its captured
  result**, so recovery can resolve `From` references for the steps it
  still has to run. Deferred processes remain **at-least-once**, as now.
- Exit status follows section 1 without exceptions: any failed step (file,
  remove, or process) means a non-zero exit, with a report naming what ran,
  what failed and what was skipped.

### What this changes for `sol/lib/git.sol`

Today `git.sol` has to say "commit in one run, push in the next", because
`push` is realtime and would publish the pre-commit head. With deferred
effects in order, push is just the last step of the plan:

```text
> Git.repo "." |> Git.add Git.all |> Git.commit "message" |> Git.push "origin" "main".
```

and a tag can name the commit it follows:

```text
> r = Git.repo "." |> Git.commit "release";
  sha = Git.headLater r;
  Git.tagAt "v1.2" sha r.
```

Push stays the one step that cannot be undone, so it must be the last one;
section 4 makes that a rule.

## 4. Later: immediate effects with inverses (kind 5)

Kept as direction, not part of this decision. When a script needs an
effect's result in its own logic, the effect runs immediately and registers
an inverse, and a failure runs the inverses in reverse order (a saga). The
rules, recorded now so the v1 API does not close them off:

- An inverse restores **state captured by the forward step** (for commit:
  `git update-ref HEAD <old> <new>`, a compare-and-swap), never a relative
  operation like `reset HEAD~1`.
- The undo token is **data**, journaled before the forward step runs, for
  the same reason the plan is data.
- A script is `compensable* ; pivot? ; retriable*`. An effect with no
  inverse is a pivot; there is at most one, and nothing compensable may
  follow it. An effect declaring nothing is treated as a pivot and warned
  about, as realtime escapes are today.
- Compensation is not isolation: other processes can see the intermediate
  state. Deferral stays the default because of that.

## 5. Order of work

1. G2, and G4's `log` with `print` documented as direct (small, local, each one test).
2. G1 and G3 (the lock and journal lifecycle; extend the crash-window legs).
3. `Deferred a` with the v1 projections and `SOLJ2`; port `git.sol` so push
   and tags run in the same script as the commit.
4. Revisit kind 5 only when a real script needs it.

Items 1 and 2 are conformance fixes to the existing contract and do not wait
on the rest.
