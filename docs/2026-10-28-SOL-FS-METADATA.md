# Sol filesystem metadata and listing: directory panic and missing-vs-empty fixes

Date: 2026-10-28.
Kind: delivery record for the first implementation slice of Phase 1 in the
[daily-scripting plan](2026-10-27-SOL-DAILY-SCRIPTING-PLAN.md).
Source baseline: `ab50224`; the changes are on top of it.
Host: macOS arm64 (darwin 27.0.0), GHC 9.8.2, cabal 3.16.1.0.

## What changed

`compiler/Sol/Txn.hs`, three operations, behavior-preserving for every case
that already worked:

- `txExists` checked directory existence only after a content snapshot, and
  the snapshot opens the path as a file, so `exists` on any directory
  panicked with `inappropriate type (is a directory)`. Directory existence
  is now observed as metadata (`doesDirectoryExist`) before any snapshot is
  taken; regular files keep the existing snapshot-based read-dependency
  semantics unchanged.
- `txStat` had the same panic: the presence bit for a directory required a
  content snapshot. Directories now answer from disk metadata directly
  (`getFileSize`/`getModificationTime`, no content read); a pending mkdir
  over an absent path reports present with mtime = now, matching the
  pending-file convention. Directory sizes are filesystem-specific; only
  the presence bit is contractual (documented on the function).
- `txLs` mapped a missing directory to `[]`, indistinguishable from an
  empty one, and panicked on a non-directory path with a raw OS error. It
  now fails explicitly: a missing directory raises
  `ls: no such directory` (with an `exists` hint), a path this transaction
  removed with `rmdir` reports the same, and any other OS error (wrong
  kind, denied) raises the OS report as a Sol panic. The transaction's own
  pending mkdir/write/remove composition and commit-time `txDirReads`
  validation are unchanged: a pending mkdir may still compose over an
  absent disk listing, because then the view's entries are all the
  directory has.

The plain `ls`/`stat`/`exists` prelude spellings keep panicking on expected
absence by design (`readPath` precedent); typed `Ok/Err` filesystem results
and fallible entrypoints remain Phase 1 work under the planned
result/error model.

## Regression suite

New `tools/sol-fs-check.py`, registered in Base
(`tests/check_registry.py`) alongside the other Sol suites. 22 checks:
exists/isDir/stat over file, missing, directory, empty directory and
dangling symlink; ls over empty, populated, missing and wrong-kind paths;
pending-mkdir composition for ls/exists/stat; pending write/rm
composition; ls after this-transaction rmdir; pending mkdir over an
existing directory.

Written first and verified to fail against the baseline binary
(`exists_dir` panic reproduced), then to pass against the fixed compiler,
per the plan's contract-and-reproducer discipline.

## Results

`make fpr`, then on the rebuilt binary:

| Check | Result |
| --- | --- |
| `tools/sol-fs-check.py` (new) | 22 checks passed |
| `tools/sol-output-check.py` | 26 checks passed |
| `tools/sol-library-check.py` | 117 checks passed |
| `tools/sol-startup-check.py` | 52 checks plus assembly/concurrent-writer checks passed |
| `tools/sol-text-process-check.py` | 34 checks passed |
| `tools/sol-examples-check.py` | 21 checks passed |
| `tools/sol-txn-check.sh` | OK |
| `tools/sol-safety-check.sh` | OK |
| `tools/sol-effects-check.py` | Both legs PASS |
| `tools/sol-cache-txn-check.py` | Passed |
| `tools/sol-linearity-check.py` | 8 checks passed |
| `tools/sol-scripts-check.sh` | OK (the plan's 2026-10-27 permission failure did not reproduce on this host; the permission-denied fixture it requested is still open) |
| `tests/test_check_registry.py` | 8 tests OK after the registration |

`sol/examples/txn_iso.sol` (inside `sol-examples-check`) pins the
composition cases the fix must not break: a fresh pending directory lists
empty, pending writes appear, removals disappear.

Hosted CI was not run; the Base registration is local evidence only.

## Remaining limits (Phase 1 checkboxes stay open)

- `exists`/`stat` on a regular file still take a whole-content snapshot
  (the documented metadata-cost gap): the content joins the read set for
  exact-byte validation. Separating metadata validation from content
  validation is the transaction-dependency review the plan calls for
  before changing snapshot storage.
- `exists` on a FIFO would still open it (blocking); metadata on regular
  files is not yet open-free.
- Errors surface as panic text, not typed results; denied is not yet
  distinguishable from other OS errors without reading the message.
  Fallible entrypoints and the one result/error model are open.
- Recursive walking, non-UTF-8 filename policy, temp-file ownership,
  copy/rename APIs: untouched, per plan.
