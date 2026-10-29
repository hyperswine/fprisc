# Sol REPL: one command, one transaction

Date: 2026-10-29.
Kind: design record with a prototype status section.
Scope: `fpr sol --repl` — an interactive session for the hosted-bytecode
profile. Follows the completed
[daily-scripting roadmap](2026-10-27-SOL-DAILY-SCRIPTING-PLAN.md), which
scoped a persistent REPL out of that milestone.

## The question

A REPL session wants incremental definitions and instant feedback. Sol
scripts are one-transaction-per-process (~27-31 ms warm on macOS arm64 —
responsive in absolute terms, ~10x bash), with state persisting only
through files. Two ways forward:

1. Pay the structural price: make each command a fresh process-shaped
   unit (keep the transaction model per command).
2. Find another mechanism giving the same isolation/guarantees without
   the per-command cost.

## The design: command-per-transaction, environment persists

One long-lived process; each command runs in its OWN transaction; the
accumulated program is the environment.

The load-bearing fact is checked purity and linearity: a Sol definition
cannot smuggle effects or retained resources. Definitions are code, not
state — the transaction machinery never needed to protect them. So the
REPL keeps exactly what is safe to keep (the program text and its
compiled form) and re-scopes exactly what must be scoped (effects,
handles, actors, observations) to one command.

- **Persistence by accumulation.** A session is a growing source text.
  Each command appends its definitions; the whole program is recompiled
  per command (in-memory; the module disk cache is bypassed), and only
  the command's own `>` evals execute. Earlier evals are never re-run,
  so their effects happen exactly once — at their own command's commit.
  A definition from command 3 is callable from command 17 because it is
  still in the program, not because anything was carried over.
- **Script-grade guarantees per command.** Fresh `TxState`, fresh actor
  runtime, fresh tabling; observations snapshot now; effects queue; the
  command's commit locks, validates (exact bytes, listings, metadata
  promises), journals, replays and unlocks exactly as a one-shot
  script's would. Between commands the session holds no locks and owns
  no handles, so it cannot interfere with concurrent `sol` processes.
- **Guarded retry is the only retry.** A command that used a realtime
  escape is never auto-replayed (the Phase 3 guarded rule, applied to
  the unit that actually ran). A conflicting commit reports the stale
  paths and the command's effects are discarded; the definitions stay
  (they are pure) and the user re-enters the effect. No
  whole-session-replay unsoundness is possible because the session is
  never the unit of re-execution.
- **Cross-command atomicity is explicit, not default.** Two prompts are
  not one atomic unit — matching every REPL's semantics. A multi-step
  atomic unit belongs in one command (blocks), a child transaction
  (`run`), or a script.
- **Resource lifetime is command-scoped.** Linear handles and streams
  bound inside a command die with it; owned actors are joined at the
  command boundary (the runner already enforces this per attempt).
  Session-visible persistent state goes through the persistent-data
  file and the filesystem — both transactional.
- **Failures contain their command.** A parse or type error rejects the
  line and leaves the session source untouched. A panic aborts only the
  current command's transaction. SIGINT aborts the running command and
  returns to the prompt. EOF exits (after the last command's commit).

## Rejected alternatives

- **One session-long transaction.** Validation compares against
  snapshots taken when each read happened; an hour-old transaction
  conflicts wholesale, and replay would re-run everything with
  re-printing and possibly-unrepeatable escapes. The codebase already
  states this: `interactive_script.sol` — "an interactive session
  cannot be replayed as one whole-script transaction".
- **A separate isolation mechanism** (overlay filesystem, copy-on-write
  sandbox, mount namespace). `txView`/`txDirView` plus the redo journal
  already ARE a logical overlay with atomic publication; a second
  mechanism would duplicate it with worse portability (FUSE privileges,
  APFS semantics) and a second crash story. Same guarantees, more
  moving parts.

## Costs, stated

- Recompiling the accumulated program per command is O(session length)
  per keystroke — quadratic over a session. Measured below; acceptable
  for a prototype, an incremental-compile tier is the known future work.
- Module imports are re-expanded per command (session memoized in the
  resolver's seen-set).
- Diagnostics are diffed so stale notes (e.g. the realtime-escape
  banner for earlier commands) are reported once, not per command.
- Plain line input: no readline editing/history in the prototype.
- The persistent-data file and recovery journal are session-scoped; a
  hard crash mid-command leaves the journal for `sol recover` as with
  scripts.

## Prototype status

Implemented: `fpr sol --repl` (stdin line-driven; prompt on a TTY, none
when piped, so suites can drive it). Regression suite
`tools/sol-repl-check.py`, registered in Base: definition persistence,
per-command commit visibility, panic/type-error isolation, multi-line
continuation, EOF exit status. Per-command auto-retry is deliberately
absent (guarded-only, per the design).

Measured on macOS arm64 (this checkout, `SOL_GPU=0`), 50 trivial
commands: ~31-36 ms per session command versus ~30 ms
process-per-command — parity, not yet a win. `SOL_TIMINGS` says why, and
it is not the transaction: per command, whole-program typecheck is
~30 ms (the prelude is re-inferred every command; a one-shot script
skips this via its binary cache hit), bytecode ~7.5 ms, and
`transaction-commit` ~0.1 ms. The command-per-transaction thesis is
vindicated — the commit is essentially free — and the remaining cost is
the compiler: incremental compilation (or a cached inference
environment) is the single unlock, worth ~30 ms on every command. Until
then a session commands feel responsive (well under the ~50 ms
threshold) but no faster than spawning.

Future work, in order: incremental compilation (the quadratic cost),
readline-style editing and history, session save/`use` of the
accumulated program, Ctrl-C safety hardening under PTY.
