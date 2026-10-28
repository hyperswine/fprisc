# Sol metadata reads: promised-field validation without content snapshots

Date: 2026-10-28.
Kind: delivery record for the implementation slice proposed in the
[transaction dependency review](2026-10-28-SOL-TXN-DEPENDENCY-REVIEW.md).
Source baseline: `b57f42a` (the review); the change is on top of it, and the
review itself builds on `dc3b40b` ([directory-metadata slice](2026-10-28-SOL-FS-METADATA.md)).
Host: macOS arm64 (darwin 27.0.0), GHC 9.8.2, cabal 3.16.1.0.

## What changed

`compiler/Sol/Txn.hs`, one new dependency store and uniform routing of the
metadata queries through it, per the review's design:

- `txMetaReads :: Map FilePath MetaSnap` joins the transaction state.
  `MetaSnap` records a PROMISE: presence always; the directory/file answer
  when `isDir` branched on it; size and mtime when `stat` returned them.
- `diskMeta` is one `stat(2)` per observation — no open, symlinks followed
  (a dangling link resolves to nothing). This is the only disk contact a
  metadata query now makes. `exists`, `isDir` and `stat` record their
  promise (a second query of the same path widens it to the union of
  promised fields) and never touch the content read set.
- Commit validates under the same locks: `touched` gained the metadata
  keys, and a `staleM` fold re-observes each promised path and compares
  exactly the promised fields via `metaStale`. A presence flip always
  conflicts; kind and size/mtime drift conflict only where promised. The
  conflict list feeds the existing retry loop unchanged.
- `txChildOverlap` treats metadata paths like reads (a child committing
  into a promised path would break the promise on retry and re-run the
  child forever); `txForget` revokes metadata promises alongside content
  and view claims, so the realtime escapes do not conflict with
  themselves.

Deliberately unchanged: tier-1 answers (pending writes/mkdirs) still
record no dependency, content reads keep exact-byte validation
(`txReadBytes`, untouched), directory listings keep name-set validation,
and `txIsDir`'s tier-1 precedence (it consults `txDirView` only, not
`txView`) stays as-is because `rm`'s issue-time directory guard depends
on it. That pre-existing inconsistency — a pending file write over a
disk directory answers `isDir` from the disk — is open, noted in the
review.

## Measured behavior changes (baseline → now)

The four discriminators added to `tools/sol-fs-check.py` fail on `b57f42a`
and pass here (32 checks total, up from 22):

| Check | On `b57f42a` | Now |
| --- | --- | --- |
| `exists_unreadable` / `stat_unreadable` (chmod 000) | `SOL PANIC: permission denied` | answers present with metadata |
| `isdir_flip_conflict` (kind removed mid-run) | silent staleness: one attempt commits on the stale branch | conflicts, retry answers the new world |
| `exists_no_content_conflict` (foreign rewrite, presence unchanged) | whole-content conflict, two attempts | one attempt, no conflict — the documented loosening |
| `stat_sparse` (8 GiB sparse file) | 7.8-8.4 s (read the whole file) | well under the 3 s bound (~45 ms script total) |

The keep-honest pins (FIFO queries answer without a content dependency;
presence-flip and size-drift conflicts still fire; all 22 earlier checks)
passed on both binaries, verified before implementing. Sparse timing is
measured as `time.monotonic()` around the whole subprocess run, warm
cache, 3 s bound; the chmod-000 case doubles as the instrumented proof
that a metadata query never opens contents (any content read fails the
check with permission denied).

## Results

`make fpr`, then on the rebuilt binary:

| Check | Result |
| --- | --- |
| `tools/sol-fs-check.py` | 32 checks passed |
| `tools/sol-output-check.py` | 26 checks passed |
| `tools/sol-library-check.py` | 117 checks passed |
| `tools/sol-startup-check.py` | 52 checks passed (plus assembly/concurrent writers) |
| `tools/sol-text-process-check.py` | 34 checks passed |
| `tools/sol-examples-check.py` | 21 checks passed |
| `tools/sol-linearity-check.py` | 8 checks passed |
| `tools/sol-txn-check.sh` | OK |
| `tools/sol-safety-check.sh` | OK |
| `tools/sol-cache-txn-check.py` | Passed |
| `tools/sol-effects-check.py` | Both legs PASS |
| `tools/sol-scripts-check.sh` | OK |

The observation-dependency contract is promoted into SEMANTICS.md §9
(two clauses with `sol-fs-check` as the test slot); the plan's
metadata-validation checkbox is ticked with this record linked.

Hosted CI was not run; Base registration is unchanged (the suite was
already registered in `dc3b40b`).

## Remaining limits

- `stat` does not expose file kind or link policy, and there is no
  `lstat`: the dangling-vs-missing distinction is answered only by
  absence semantics. That surface stays open in the plan's metadata
  bullet.
- Within a promised field, mtime has filesystem-dependent resolution: a
  same-size rewrite inside the resolution window is undetectable by a
  `stat` promise (stated in SEMANTICS.md; never claimed as content
  equality).
- Scripts whose only observation of a path was `exists`/`stat`/`isDir`
  no longer conflict on foreign CONTENT rewrites of that path. This is
  the review's designed loosening; any suite or script relying on it
  must read the file instead.
- FIFO/device metadata promises include size and mtime as stat(2)
  reports them (size 0 for pipes); a writer touching the pipe's mtime
  conflicts a `stat` promise on it.
