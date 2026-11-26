# Sol: each statement is a transaction, and `>!` marks an immediate one (26 November)

Kind: owner decision (26 Nov 2026) and its delivery record. Branch
`sol-progressive` (on `v1-defects`). It implements item 3 of the
[Sol review](2026-11-26-SOL-SCRIPTING-REVIEW.md) (§5.4, "step-by-step commit
mode"). It supersedes the whole-script transaction of
[Sol transactions](2026-08-25-TRANSACTION.md); that page stays as the record of
the earlier model.

## The decision

The owner's words: make each `>` its own transaction, refactor all the scripts
that way, and allow fast immediate statements beside the safe, deferred-effect
ones, in their own `>` blocks. Effects written outside any statement are refused
at compile time.

## The model

| | `> e.` transactional statement | `>! e.` immediate statement |
|---|---|---|
| Unit of commit | the statement: one snapshot, one journal, one commit | the statement: its ordinary effects commit when it ends |
| Realtime operations | **refused at compile time** | allowed, run at once, not announced |
| Conflict at commit | re-runs **this statement** only | fails the run (never retried) |
| A panic | discards this statement's effects; earlier statements stay committed; later ones do not run | the same, but realtime effects already done stay done |

Rules that follow:

1. **Statements run in file order**, and each sees what earlier statements
   committed (`sol/examples/txn_iso.sol` shows both kinds of visibility).
2. **`Script.exit`** commits its statement and ends the run; later statements do
   not start.
3. **Statements share definitions, not values.** A binding inside a statement is
   local to it. Data passes between statements through top-level definitions,
   which are pure, or through the files a statement committed.
4. **What counts as a realtime operation:**
   - the five `*Now` wrappers: `readNow`, `writeNow`, `appendNow`, `shNow`,
     `readLineNow`;
   - immediate streams: `Stream.openRead`/`openWrite` and their chunk and line
     operations, `Stream.stdin`, `IO.readLine`, `Sha256.stream`;
   - `Http.request`/`download`;
   - `Proc.runNow`/`streamNow`/`inheritNow`/`pipeline`/`start`;
   - `Fs.copyNow`/`copyPublishNow`/`renameNow`;
   - `Env.set`/`unset`;
   - `NativeGit.push`/`commitNow`.

   The list is `immediateOperations` in `sol-vm/Sol/Main.hs`. It names every
   primitive the runtime routes through its escape accounting (`markEscape`,
   `guardImmediate`, `direct`, `fileImmediate` in `Sol.Hal`).
5. **The check is reachability.** From each transactional statement, the compiler
   follows top-level references, including through spliced libraries. Reaching a
   realtime operation refuses the script before any statement runs:

   ```text
   statement 2 (`>`) is a transaction but reaches immediate operation(s)
   writeNow: write it `>!` (immediate, never retried), or use the transactional twins
   ```

6. **Nothing runs outside a statement.** Top-level definitions run only when a
   statement names them, and a nullary definition is evaluated where it is
   referenced, so "effects outside a statement" cannot execute. A script with no
   statements runs a zero-argument `main` as its one transactional statement,
   which is checked like any other. A script that has statements runs exactly
   those. It used to run a zero-argument `main` after them as well, and now names
   `main` in a statement if it wants that.
7. **`print` is allowed in a transactional statement.** It is output, not a world
   effect, but output already printed still refuses a retry, as before. Use `log`
   for lines that should appear only after a commit.

## What changed in the implementation

- **Parser** (`Frontend/Parser.hs`, shared with native): `>! e.` parses as the
  ordinary `TEval`, whose block starts with the local `$immediate`. `$` cannot
  occur in a source name, so the marker cannot clash, and the native frontend
  ignores it.
- **Statement numbering** (`numberEvals`): it strips the marker and names the
  statement `topnow__N` instead of `top__N`. The flag travels in the name, so the
  cached compile result needs no new field.
- **The check** (`transactionalEscapes`): it runs after numbering and before
  bytecode. It replaces the old "REALTIME ESCAPES: N uses ... NOT atomic" report,
  since a transactional statement can no longer contain an escape and an
  immediate one declares its escapes.
- **The run loop** (`runTxLoop`): one `runTxAttempts` per statement, each with its
  own escape counter.
  - An immediate statement's counter is quiet: no first-use notices and no
    "NOT atomic overall" line.
  - An immediate statement gets one attempt.
  - The exit flag is now `Maybe Int`, so `Script.exit 0` also stops the
    remaining statements.
- **Safety check:** a statement that only names `main` is left out of the safety
  graph. As a clause of `main` it read as `main = main`, which is recursion.
- **Ordering message:** the refusal for "runs NOW while effects are queued" now
  says to move the queued effects into an earlier statement, instead of "a
  separate script run".
- **The REPL** is unchanged: each command was already its own transaction. A REPL
  command now follows the same `>` / `>!` rule.

## Scripts refactored

- **What the scan covered:** every `.sol` file tracked in fprisc, compiled with
  `sol --asm`.
- **What it found:** 93 scripts had a transactional statement that reaches a
  realtime operation. Almost all are orchestration: builds, packaging, release
  tools, benchmarks, and the Sol checks themselves through
  `tests/sol-checks/helpers.sol`.
- **The change:**
  - Exactly the refused statements became `>!`. Statements that stay
    transactional keep `>` (in `sol/examples/realtime.sol`, `procs.sol` and
    `txn_iso.sol`).
  - Six scripts that relied on an automatic zero-argument `main` gained
    `>! main.`.
  - `sol/examples/example.sol` gained `> main.`.
- **Restated for the new model:**
  - `sol/examples/txn_iso.sol`, whose old fourth step asserted that a later
    statement still saw the disk untouched by earlier ones;
  - `tests/txnabort.sol`.
- **Result:** after the change, no tracked script is refused.

New check: `tests/sol-checks/statements.sol` (push tier) pins rules 1, 2 and 5,
the main-as-statement case, per-statement retry under `SOL_FORCE_RETRY`, quiet
`>!`, abort keeping earlier statements, and the isolation example.

## Not done

- **qos and coscad scripts are not migrated.** They pin Sol 0.13.x
  (`./sweep` runs `sol +0.13.1`; coscad uses `~/.fpr/0.13.1`). 0.13 cannot parse
  `>!`, so they change in the same commit that moves their pin to a release
  containing this work.
- **The `sol` skill documentation** still describes the whole-script transaction.
- **Values between statements.** Splitting a long script into several committed
  steps today means passing data through files. A `> name = e.` binding that later
  statements can read would let orchestration scripts commit step by step without
  that. It is a separate decision.
- **Most orchestration is immediate.** The review's success criterion, that the
  runners end without the "NOT atomic overall" line, is met: their escapes are now
  declared by `>!`. Making their individual steps transactional (queue processes
  with `Proc.afterCommit` and read the results in the next statement) waits on
  values between statements.
