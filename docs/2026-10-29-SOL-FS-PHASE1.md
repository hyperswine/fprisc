# Sol Phase 1: filesystem observations, traversal and scratch ownership

Date: 2026-10-29.
Kind: delivery record and API reference.
Scope: HostedBytecode / `fpr sol`; Phase 1 of the
[daily scripting plan](2026-10-27-SOL-DAILY-SCRIPTING-PLAN.md).
Source baseline: `2badda8`, including the existing uncommitted kind/walk/temp
implementation. The completion changes are in the working tree.
Status: implemented and locally verified on macOS arm64; Linux and hosted CI
remain unverified. Phase 2 binary I/O/copy/rename is separate work.

## Public surface

The earlier [filesystem error model](2026-10-28-SOL-FS-RESULT-MODEL.md) remains:
`FsError` carries operation, original query path, reason and message. New
operation tags are `OpLstat`, `OpStatKind`, `OpWalk`, `OpTempDir`, `OpTempFile`;
new reasons are `FsEncoding` and `FsLimit`. Reason tags are stable; OS message
wording is not.

| API | Result / policy |
| --- | --- |
| `Try.lstat path` | `Result FsKind FsError`; no-follow leaf kind |
| `Try.statKind path` | `Result FsKind FsError`; followed kind |
| `isLink path` | True for links, including dangling links; false for missing/non-links; errors on an unknowable observation |
| `Try.walk root depth entries follow` | `Result (List WalkEntry) FsError`; bounded sorted preorder |
| `Try.tempDir prefix` / `tempDir prefix` | Result / insisting spelling for an owned private directory |
| `Try.tempFile prefix` / `tempFile prefix` | Result / insisting spelling for an owned private file |

`FsKind` is `KFile | KDir | KLink | KOther`; FIFO/device/socket kinds are
`KOther`. `WalkEntry path kind depth` exposes all three fields.
`Try.stat` keeps its size/mtime pair, and plain `stat` keeps its
presence/size/mtime triple. A dangling leaf link is `Ok KLink` to lstat;
its missing referent is `FsMissing` to statKind. Intermediate components
follow normal POSIX resolution. A trailing separator on lstat/statKind keeps
POSIX directory-only interpretation.

## Observation dependencies

Content reads retain exact raw-byte snapshots. Metadata operations do not open
file contents. Followed presence/kind and no-follow presence/kind are distinct
promises, so lstat never follows a link merely to validate its own answer.
Missing lstat entries record no-follow absence too. `isDir` promises its boolean
predicate: a FIFO answering false is not accidentally promised to be a regular
file. Conflicting repeated observations force retry instead of overwriting the
first observation's dependency silently.

Metadata rechecks run under the corresponding path lock during sorted lock
acquisition, before descendant lock artifacts can change an observed directory's
size/mtime. Directory stat through an alias also records the canonical referent
and checks its fields at that referent's lock; retargeting the alias conflicts.
Content bytes and directory name sets still validate after all locks are held.
This prevents directory inventories from conflicting with their own locks.

Pending-view keys use stable absolute parent-resolved paths, retaining leaf
symlink semantics. Relative/absolute/parent aliases see the same queued writes.
Listings compose file additions/removals, directory removals and implicit parent
directories from mkdirp. Recreating a path updates the pending kind consistently.

These are promised-field checks, not inode identity or content equality claims.
Same-metadata replacement can pass, and writers ignoring Sol's locks can race
observation, recheck and replay. A walk is a collection of listing/kind
dependencies, not a globally atomic OS tree snapshot. Successful file-content
reads continue to provide exact-byte validation.

## Walker contract

- Root must be a directory. A root leaf link requires `follow=True`; False
  refuses it as `FsWrongKind`. Walk strips the root's trailing separator before
  applying this policy. Root itself is not emitted.
- Children have depth 1. The requested maximum depth defines the query scope;
  entries at that depth are emitted without descent. Use `follow=False` for
  ordinary inventories; following is an explicit opt-in.
- Children are sorted by decoded name and emitted in preorder. Returned paths
  are absolute; a supplied root alias is retained in emitted paths. Spaces,
  Unicode and newlines in names survive exactly.
- Entry budget counts emitted entries. Exactly reaching it succeeds if there
  are no further entries in scope. Overflow returns `FsLimit`, never a partial
  successful inventory. Invalid depth/budget also returns `FsLimit`.
- Following uses ancestor canonical identities to cut cycles. The link entry
  is emitted; only recursive descent is cut. Distinct sibling aliases can
  repeat a subtree, within the entry budget. A dangling link remains `KLink`;
  a symlink loop that cannot be resolved returns `FsLoop`.
- Vanished, denied or wrong-kind entries fail the walk with `OpWalk` and the
  affected path. They are not silently omitted. Followed link kind/absence
  observations join the metadata read set too.
- Directory entries are read as raw bytes and checked for exact UTF-8 decoding
  before becoming Strings. Unsupported names return `FsEncoding`; they are
  never replaced with invented Unicode names. Directory streams close on all
  enumeration exits.

The result and visited traversal are bounded by the explicit entry/depth limits.
Each sorted directory listing is still materialized, as are transaction read
sets and the result list. This is not Phase 2's bounded-memory streaming API.

## Temporary storage contract

Allocation is immediate and owned by the current transaction attempt, including
allocations made by its actors. `mkdtemp`/`mkstemp` create unpredictable exclusive
names under the system temporary directory, with private modes 0700/0600
(subject to a stricter umask). Prefixes are 1-64 ASCII letters, digits, `_` or
`-`; paths, empty prefixes and oversized prefixes are refused as typed errors.
Allocation and ownership registration are masked against asynchronous
cancellation. Temporary file descriptors are closed before returning the path.

The attempt's finalizer removes scratch on success, pre-commit failure, retry
discard and Ctrl-C. Actors are stopped before cleanup; retry scratch is removed
before starting the next attempt. Cleanup errors are reported explicitly.

A durable redo or unresolved Git inverse may still need scratch. In that case,
cleanup retains it and prints the paths instead of breaking recovery. Hard kill
or machine failure can also strand scratch. Ownership is process-local: after
recovery, retained paths require explicit manual cleanup once they are no longer
needed. Do not use scratch as durable application output. Automatic crash-orphan
collection is a later lifecycle feature, not a promise of this API.

## Copy/rename policy for Phase 2

This section specifies the intended next contract; it does not add those APIs.

- Same-filesystem immediate rename is explicit; cross-device failure returns
  an error and never silently becomes copy/delete.
- Copy refuses an existing destination by default; replacement requires explicit
  opt-in. Stage in the destination filesystem before publication, and define
  staged payload/recovery ownership before calling it transactional.
- Refuse destination leaf symlinks, matching current writes. Source-link
  following must be explicit. Do not weaken leaf-link checks during recovery.
- Preserve existing destination executable/mode bits when replacing through
  the existing text-write API. New copy output starts private; any source-mode
  preservation option must be documented. Ownership, ACL and extended-attribute
  preservation need separate promises and tests.
- Keep current `mv` identified as a text read/write/delete helper. Introduce
  binary copy/rename through distinct contracts and migrate callers deliberately.

Existing executable-mode preservation and symlink-write refusal remain covered
by the effects suite.

## Verification

Build: `make fpr`, GHC 9.8.2, compiler build profile `-O1`, on macOS arm64.
Verified executable SHA-256:
`be2b9995e8ab57aaee111bf6ac01e9f54853ac69da600659b0bf3b29b4f83e26`.
The filesystem suite remains registered in Base through
`tests/check_registry.py`. No shared native frontend/backend code changed.

| Command | Result |
| --- | --- |
| `python3 tools/sol-fs-check.py` | 103 checks; raw invalid-name fixture unavailable on APFS |
| `python3 tools/sol-output-check.py` | 26 checks |
| `python3 tools/sol-library-check.py` | 117 checks, including expected unsupported cases |
| `python3 tools/sol-startup-check.py` | 52 checks plus assembly/concurrent-writer coverage |
| `python3 tools/sol-text-process-check.py` | 34 checks |
| `python3 tools/sol-examples-check.py` | 21 checks |
| `python3 tools/sol-linearity-check.py` | 8 checks |
| `python3 tools/sol-cache-txn-check.py` | Passed |
| `python3 tools/sol-effects-check.py` | Both filesystem/deferred and Git legs passed |
| `sh tools/sol-txn-check.sh` | Passed |
| `sh tools/sol-safety-check.sh` | Passed |
| `sh tools/sol-proc-git-check.sh` | Passed |
| `sh tools/sol-scripts-check.sh` | Passed with OS process-inventory access |
| `python3 tests/test_check_registry.py` | 8 tests |

The filesystem cases cover readonly contents and sparse files, kind/link
classification, promised-field drift, missing lstat, exact/invalid budgets,
root policy and cycle cuts, deterministic depths, pending/aliased paths,
directory-stat lock artifacts and alias retargeting, temp modes/prefixes,
retry/panic/cancellation cleanup and recovery retention.

APFS rejects the invalid-byte filename fixture at creation with EILSEQ; the
restricted session can instead reject it with EPERM. Both are reported as an
unexercised test, not a passing encoding test. Run the fixture on a Linux
filesystem before claiming cross-host raw-filename validation. Hosted CI,
the full Base run and physical-board execution were not performed.
