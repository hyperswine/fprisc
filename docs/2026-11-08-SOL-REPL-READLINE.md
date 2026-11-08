# Sol REPL readline: editing, history, completion via haskeline

Date: 2026-11-08.
Kind: delivery record for the readline half of the REPL polish proposed
after [the error-path fix](2026-11-08-SOL-REPL-ERROR-PATH.md), completing
the REPL items from the [speed record](2026-10-30-SOL-REPL-SPEED.md)
except Approach A (still deferred). Host: macOS arm64 (darwin 27.2.0),
GHC 9.8.2, haskeline 0.8.2.1 (a GHC boot package — no new downloads).

## What changed

`fpr sol --repl` on a terminal now runs GHCi's line editor:

- **Line editing**: cursor movement, kill/yank, reverse history search
  (Ctrl-R) and history walking (Ctrl-P/Ctrl-N) — haskeline's full set.
- **Persistent history**: `<state dir>/repl-history` (the same
  `stateDirectory` convention as recovery journals: `SOL_STATE_DIR`,
  `XDG_STATE_HOME/sol`, or `~/.local/state/sol`), `autoAddHistory` on.
  History survives across processes and is pinned by the suite.
- **Ctrl-C at the prompt** cancels the pending multi-line command and
  re-prompts (the partial buffer is discarded); Ctrl-C DURING a running
  command still lands in the command's `UserInterrupt` handler and
  returns to the prompt — the two compose.
- **Tab completion** over everything in scope: the prelude's top-level
  names, the names this session defined (tracked as before for the
  no-redefinition rule), and every `use` alias in the accumulated
  program. Word breaks exclude `.`, so qualified names (`M.fromCsv`)
  complete.
- **The piped path is byte-identical**: when stdin is not a terminal the
  loop keeps the raw `hGetLine` reader — no prompts, no haskeline — so
  every piped suite and the PTY benchmark harness drive the REPL exactly
  as before.

Implementation: `compiler/Sol/Main.hs` (a `ReplLine` sum type unifying
the TTY and piped readers: `ReplInput`/`ReplEof`/`ReplCancel`/
`ReplCrash`), one `haskeline` line in `fp-risc.cabal`.

## Testing gotchas worth keeping

- **haskeline's full backend requires a CONTROLLING terminal.** A pty
  via `openpty` + `Popen` is not enough: haskeline (and GHCi, verified
  the same way) silently falls back to the dumb backend — prompts render,
  but Ctrl-P/Ctrl-C pass through as literal bytes and history never
  persists. Test harnesses must use `pty.fork()`, which makes the child
  a session leader with the pty as its controlling terminal.
- **Settings construction**: `defaultSettings { complete = ... }` with a
  constrained completion function leaves haskeline's `MonadIO m` unsolved
  even under a `Settings IO` annotation; `setComplete` over a
  record-updated `defaultSettings` resolves it. The top-level
  `replSettings` has the concrete signature.

## Suite

`tools/sol-repl-check.py` grows 11 → 15 checks: four PTY-driven checks
(prompt + history file written; Ctrl-P recall across processes; Ctrl-C
cancel-then-continue; Tab completing `tempD` → `tempDir`), alongside the
unchanged piped contract (3.1 ms per trivial session command, 10.7x the
process-per-command control). The full battery is green: output 26,
libraries 127, examples 21, fs 103, io 84, library-cache (347),
incremental (369, with the tvar-name normalization), effects both legs,
science vertical, txn/safety/scripts shells.

## Limits

- Completion is name-based: no type-directed completion, no module-member
  qualification help (`M.fr` completes only after the alias is in the
  accumulated program — the session source is the source of truth).
- History file size is unbounded for now; a cap is a one-line follow-up
  if a long-lived state dir ever matters.
- Windows haskeline behavior is unverified (the support matrix is
  macOS arm64 and Linux x86-64; PTY checks are POSIX).
