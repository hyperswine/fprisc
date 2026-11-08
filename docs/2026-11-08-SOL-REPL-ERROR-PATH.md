# Sol REPL error path: classify the trial failure, skip the fallback

Date: 2026-11-08.
Kind: delivery record. Implements the error-path fix proposed after
[REPL speed](2026-10-30-SOL-REPL-SPEED.md) and priced in the
[incremental-prelude](2026-10-29-SOL-INCREMENTAL-PRELUDE.md) record's
limits ("a command that fails to compile now costs a trial plus a full
compile"). Host: macOS arm64 (darwin 27.2.0), GHC 9.8.2.

## The change

`compiler/Sol/Main.hs` (`compilePreparedSession`) + a new
`tryBufferedDiagnostics` in `compiler/Sol/Diagnostic.hs`.

Before: ANY rejection of the sliced trial compile fell back to the full
compile (~5 + ~37 ms marginal), for two documented reasons — an
under-inclusive slice fails as unbound names or missing operator/member
targets the full compile may not; and diagnostics print fresh-variable
names that differ between the two compiles.

Now the trial's failure is caught WITH its buffered diagnostics (the old
`onException` path dropped them) and classified:

- **Escalate to the full compile** when the failure could be
  slice-induced: any held line containing `unbound`, `unknown
  constructor`, `unresolved`, `no operator`, `no instance`, `not
  matched`, an exhaustiveness complaint, or a typed-holes banner.
- **Escalate** for anything not a recognized error family (unknown
  banners, empty diagnostics): conservative by default.
- **Reprint the trial's own diagnostics and stop** only when the held
  text carries one of the whole-program error families compileScript
  raises (`=== TYPE ERRORS ===`, `=== SAFETY:`, `=== SIG/STRUCT:
  ERRORS ===`, `=== PRECONDITION: ERRORS ===`, `=== PATH LITERALS:
  ERRORS ===`, `=== LINEARITY: ERRORS ===`) AND no slice-sensitive
  marker appears. That failure is the user's code failing identically
  in both compiles; only the fresh-variable NAMES differ, and an
  interactive user has no baseline to compare them against.

`SOL_INCREMENTAL=0` still compiles whole and is untouched; `trace` mode
reports each decision (`trial diagnostics printed` vs `full prelude`).

## Measured (same binary, warm caches, piped sessions incl. startup)

| Case | Cost |
| --- | --- |
| Clean command | 47.9 ms |
| Type error (fast path: trial only) | 47.1 ms |
| Unbound name (escalated: trial + full = what ALL errors cost before) | 60.4 ms |

The error path now costs the same as a clean command — the fallback is
gone where it was pure overhead. PTY-marginal framing (the repl-speed
record's): the ~21.6 ms rejected-type-error median loses the full
compile's share.

## Differential honesty

`tools/sol-incremental-check.py` (369 cases) passes with a comparison
change: stderr is normalized on both sides by replacing letter+digits
tokens (`m30`, `u5`) with `<tv>`. Fresh-variable names are the only
expected difference on the fast path; user-code identifiers never differ
between modes, and program output is stdout, so the normalization can
only mask compiler-generated naming. The tally in this run: 31 cases
fast-pathed, 8 escalated as slice-sensitive, 3 typed-hole escalations.

## Battery

All green on the rebuilt binary: output 26, libraries 127, examples 21,
fs 103, repl 11, io 84, library-cache (347 differential), effects both
legs, science vertical, txn/safety/scripts shells.

## Limits

- The fast path's wording (tvar names) differs from what
  `SOL_INCREMENTAL=0` prints; documented here and handled by the
  suite's normalizer, not by silent equivalence claims.
- The classifier is marker-based on held diagnostic text; a new error
  family added to compileScript without a `===` banner escalates (safe,
  slow) until added to `trialErrorFamily`.
- The session-recompile cost (500 definitions ≈ 60 ms) is the separate
  user-inference-environment problem ("Approach A") and is unchanged.
