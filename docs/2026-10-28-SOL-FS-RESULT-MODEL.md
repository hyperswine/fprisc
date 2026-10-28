# Sol fallible filesystem tier: FsError and Try.ls / Try.stat / Try.exists

Date: 2026-10-28.
Kind: delivery record for Phase 1's result/error-model bullet in the
[daily-scripting plan](2026-10-27-SOL-DAILY-SCRIPTING-PLAN.md).
Source baseline: `6411bfa` ([metadata reads](2026-10-28-SOL-META-READS.md)).
Host: macOS arm64 (darwin 27.0.0), GHC 9.8.2, cabal 3.16.1.0.

## The model

One structured error, three fallible entrypoints, classified panics for
the insisting spellings:

```sol
FsOp     = Type (OpLs | OpStat | OpExists).
FsReason = Type (FsMissing | FsDenied | FsWrongKind | FsLoop | FsOther).
FsError  = Type (FsError FsOp String FsReason String).  -- op, path, reason, os message

Try.ls     : String -> Result (List String) FsError
Try.stat   : String -> Result (Int, Int)      FsError  -- Ok is the size/mtime pair
Try.exists : String -> Result Bool            FsError  -- absence is Ok False
```

- `exists` answers plain absence as `Ok False`; only an observation the
  OS cannot make is an `Err` (denied parent, symlink loop, a path
  component that is not a directory).
- `Try.stat` carries absence as `Err` — the presence bit lives in the
  Ok/Err split, so `Ok` is just the promised fields. A `Try.stat`
  observation of a missing path still records the presence promise, so
  a foreign creation mid-run conflicts exactly like `exists`-missing.
- `unwrap` does not apply (its `error` wants a String); scripts
  pattern-match `Err (FsError op path why msg)` — nested constructor
  patterns are the railway's spelling — or use `isOk`/`andThen`, which
  are polymorphic in the error type.
- `Try.readPath` keeps `Err String` (compatibility: `readPathOr` and
  `unwrap` type on it). Promoting it to `FsError` is a migration, not a
  fix; it stays open.

## Implementation

- `compiler/Sol/Txn.hs`: `FsErr`/`FsWhy` and `classifyIO`, which reads
  `ioe_errno` first (ELOOP, EISDIR, ENOTDIR only exist there) with an
  `IOErrorType` fallback. `txLsE`/`txExistsE`/`txStatE` are the Either
  variants; the panicking `txLs`/`txExists`/`txStat`/`txIsDir` render
  `fsPanic` — missing keeps its guard-hint (and the rmdir note), other
  reasons name the path, the OS report, and the `Try.*` spelling.
- `compiler/Sol/VM.hs`: three HAL handlers constructing the `FsError`
  value by constructor id (`vErrV` for an Err carrying structured data).
- `compiler/Sol/Preamble.hs`: the three type declarations and HAL
  arities. `compiler/Sol/Infer.hs`: the three `solBuiltins` schemes
  (`Result x FsError`).

Dependencies are unchanged from the metadata slice: the `Try.*` tier
records the same listings and metadata promises as the plain spellings
(same `tx*E` internals); answered observations validate, error answers
record nothing except `Try.stat`-missing's presence promise.

## Behavior changes, measured

Against `6411bfa` (checked first, all failing as designed):

| Check | On `6411bfa` | Now |
| --- | --- | --- |
| `Try.*` (all) | `unbound name: Try.ls` — the tier did not exist | typed results; reasons render and pattern-match |
| `try_ls_denied` / `try_exists_denied` | (could not run) | `OpLs … FsDenied` / `OpExists … FsDenied` |
| `try_stat_loop` | (could not run) | `OpStat … FsLoop` (symlink loop a↔b) |
| `exists_denied_panic` / `isdir_denied_panic` | raw `SOL PANIC: path: … permission denied` | classified `SOL PANIC: exists: … — use Try.exists ***` |
| `stat_loop_panic` | raw panic text | classified `SOL PANIC: stat: …` |
| `ls`/`stat` missing (plain) | unchanged messages — kept byte-for-byte | unchanged |

`plain stat` of a missing path still answers `(False, 0, 0)` (documented
plain contract); `plain exists` still answers `False`. Both now classify
denied/loop instead of surfacing a raw OS error.

## Results

`tools/sol-fs-check.py` grows to 46 checks (was 32), all passing, plus:

| Check | Result |
| --- | --- |
| `tools/sol-output-check.py` | 26 checks passed |
| `tools/sol-library-check.py` | 117 checks passed |
| `tools/sol-startup-check.py` | 52 checks passed (plus assembly/concurrent writers) |
| `tools/sol-text-process-check.py` | 34 checks passed |
| `tools/sol-examples-check.py` | 21 checks passed |
| `tools/sol-linearity-check.py` | 8 checks passed |
| `tools/sol-cache-txn-check.py` | Passed |
| `tools/sol-txn-check.sh` | OK |
| `tools/sol-safety-check.sh` | OK |
| `tools/sol-scripts-check.sh` | OK |
| `tools/sol-effects-check.py` | Both legs PASS |

SEMANTICS.md §9 gains the fallible-tier clause; the plan's error-model
checkbox is ticked with the observation-surface scope note. Hosted CI
was not run.

## Remaining limits

- Mutations (`mkdirp`/`rm`/`rmdir`/`writePath`) have no `Try.*`
  spellings: they queue commit-time effects by design, and their
  issue-time refusals (rm of a directory, symlink writes) stay panics
  until the Phase 2 copy/rename APIs settle their contracts.
- `Try.readPath` is still `Err String`.
- No `Try.isdir` (isDir's wrong-branch risk is covered by the recorded
  kind promise; a fallible spelling follows with the stat/lstat surface).
- Non-UTF-8 filenames surface as OS-message text only; the recursive
  walker bullet owns that policy.
- `FsOther` messages embed `show e`; stable cross-platform message text
  is not promised — only the reason tag is contractual.
