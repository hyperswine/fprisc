# The transaction dependency model: metadata validation review

Date: 2026-10-28.
Kind: review and design record, requested by the
[daily-scripting plan](2026-10-27-SOL-DAILY-SCRIPTING-PLAN.md) before Phase 1
expands into recursive traversal or snapshot-storage changes.
Source baseline: `dc3b40b` (the [directory-metadata slice](2026-10-28-SOL-FS-METADATA.md)).
Scope: how `fpr sol` observations become commit-time dependencies, where the
metadata queries sit in that model, and the design for separating metadata
validation from exact-byte content validation.

## The model today

Every observation resolves through three tiers, and each tier has a
different dependency consequence:

| Tier | Answered by | Dependency recorded |
| --- | --- | --- |
| 1. in-txn view | `txView` (pending file writes/removals), `txDirView` (pending mkdir/rmdir) | none: the transaction owns the path |
| 2. read snapshot | `snapshot`: whole content read once, bytes + decode kept | content: `txReads`/`txReadBytes`; the path joins the commit lock set |
| 3. disk metadata | `doesDirectoryExist`, `getFileSize`, `getModificationTime` | none (except directory listings, below) |

Listings are their own dependency: `txLs` records the sorted name set in
`txDirReads` (directories only; after `dc3b40b` a missing directory fails
instead of recording `[]`).

Commit (`Txn.commit`) then works in a fixed order: collect `touched` =
content-read paths ∪ listed directories ∪ effect paths ∪ path logs; take
all those paths' `.sol-lock` directories in sorted order (PID-stamped,
with dead-owner reclaim and journal-based redo); validate under the locks —
every content read re-reads the whole file and compares exact bytes
(`staleC`), every listing re-lists and compares the filtered sorted names
(`staleD`); on any staleness return `Conflict`, which discards the
attempt's effects and re-runs the script (bounded retries, `Main.hs`
`runTxLoop`); otherwise journal the effect log (the commit point), replay
it via `writeAtomic` renames, clear the journal, unlock.

Two places deliberately DROP dependencies: the realtime escapes
(`rtWrite`/`rtAppend` call `txForget`, revoking this transaction's claim on
the path, because the escape already changed the disk behind the
transaction's back), and tier-1 answers (a path the transaction wrote or
mkdir'd is validated by being IN the effect log, not by re-reading it).
A child `run`'s committed paths are refused outright if they overlap this
transaction's reads/view/dirs (`txChildOverlap`) — otherwise every retry
re-runs the child and re-conflicts forever.

## Where the metadata queries sit, and the three holes

`exists`, `stat`, `isDir` route through `txExists`/`txStat`/`txIsDir`.
Tier 1 first (pending writes answer, correctly, with no new dependency).
On a tier-1 miss the current behavior has three defects:

| Query | On a disk file | On a disk directory | Dependency recorded |
| --- | --- | --- | --- |
| `exists` | whole-content snapshot | direct `doesDirectoryExist` (post-`dc3b40b`) | content (files) / none (dirs) |
| `stat` | whole-content snapshot + size/mtime | direct size/mtime (post-`dc3b40b`) | content (files) / none (dirs) |
| `isDir` | — | pure `doesDirectoryExist` | **none at all** |

1. **Cost and false failure.** Probing metadata of a file reads all of it:
   `exists` on a 2 GiB file costs 2 GiB of I/O and cache memory
   (`txReadBytes` retains the bytes for validation), and on a stat-able
   file whose contents cannot be read it PANICS with permission denied —
   measured on `dc3b40b`. The plan's Phase 1 gate explicitly requires
   metadata to work on such a file. On a FIFO, GHC's nonblocking open
   makes `exists` answer `True` immediately but records an empty-content
   snapshot: a phantom "" dependency that would conflict if the pipe ever
   carries data. (This corrects the
   [fs-metadata record](2026-10-28-SOL-FS-METADATA.md), which guessed the
   FIFO open would block; it does not.)
2. **Silent staleness.** `isDir` validates nothing. A script that branches
   on `isDir p` and then acts has no dependency on `p`: a foreign writer
   replacing the directory with a file (or vice versa) between observation
   and commit does not conflict, and the script commits on a branch decided
   by a world that no longer exists. `sol/scripts/text/shell.sol`'s
   `showEntry` does exactly this, benignly only because `stat` re-observes
   behind it.
3. **Inconsistent strictness.** The same conceptual question ("does this
   path exist") records a whole-content dependency for files and nothing
   for directories, so the validation strength depends on the path's kind
   rather than on what the script promised.

## What the plan requires

Phase 1: "`exists` checks existence without opening the file; stat/lstat
expose file kind and link policy" and "Specify metadata validation
separately from exact-byte content validation. Record/recheck the metadata
fields actually promised, under the existing lock protocol; do not claim
content equality from size/mtime. Content reads retain exact-byte
validation. Document concurrent non-Sol writers and TOCTOU limits."

## Proposed design: a metadata read set with promised fields

Add a fourth dependency store, `txMetaReads :: Map FilePath MetaSnap`,
populated ONLY by tier-3 observations (tier 1 keeps answering with no
record; tier 2 is unchanged — actual reads keep exact-byte validation):

```haskell
data MetaSnap = MetaSnap { msPresent :: Bool        -- every promise includes presence
                         , msSize    :: Maybe Integer -- promised by stat only
                         , msMtime   :: Maybe Integer -- promised by stat only
                         }
```

- `exists p` observes via a non-opening metadata read (`getFileStatus`,
  which follows symlinks — the current `stat`/`exists` semantics), records
  `MetaSnap present Nothing Nothing`, answers presence.
- `stat p` observes the same way and records the size/mtime it returned;
  its answer is exactly today's `(present, size, mtime-seconds)`.
- `isDir p` routes through the same observation and records presence (the
  kind is derivable from `isDir`'s caller combining `exists`/`isDir`; a
  dedicated kind field can follow with the `lstat` surface, which stays
  future work together with link-policy spellings).
- Commit gains a `staleM` fold alongside `staleC`/`staleD`: re-observe
  under the commit locks and compare ONLY the promised fields — presence
  always, size/mtime when `stat` promised them. Presence flips conflict;
  same-presence size/mtime drift conflicts only where promised.
- `touched` gains `txMetaReads` keys, so the recheck happens under the
  existing lock protocol — same locks, same sorted acquisition, same
  reclaim/redo machinery, no new lock kinds.
- `txChildOverlap` treats meta-read paths like reads: a child committing
  into a path whose presence this transaction promised would break the
  promise on retry and re-run the child forever.
- Directory metadata (`dc3b40b`'s direct stat) folds into the same store,
  making validation strength uniform across kinds: today a directory
  `exists` is unvalidated, under the design it is presence-validated.

### Behavior changes to state openly

- Scripts whose ONLY observation of a path is `exists`/`stat`/`isDir` stop
  conflicting when a foreign writer rewrites that path's CONTENT without
  changing its promised metadata. Today such scripts conflict on every
  foreign write (via the phantom whole-content dependency); the plan
  explicitly wants metadata queries to promise metadata, not content. Any
  script needing the content dependency has one by reading the file.
- Metadata on unreadable files, FIFOs and other non-regular files starts
  working (no open, no panic, no phantom "" snapshot).
- Conflict strength for `stat` becomes field-wise: a same-size,
  same-mtime content rewrite passes `stat`-only validation (filesystem
  metadata lies within its granularity; this is the documented
  size/mtime limit, never presented as content equality).

### Honest TOCTOU limits (to be stated in the semantics reference)

- Metadata is validated at commit under the locks, but non-Sol writers
  ignore the locks; between the recheck and each effect's replay the
  content-read path has exactly the same window today.
- mtime resolution is filesystem-dependent; same-size rewrites inside the
  resolution window are undetectable by metadata promises.
- Existence promises cannot distinguish a path that was removed and
  recreated with identical metadata between observe and recheck.

## Compatibility evidence

No registered check or example relies on an exists/stat/isDir-only content
conflict: `grep` over `tools/sol-*check*` and `sol/examples` shows `exists`
used for pending-view assertions (`txn_iso.sol` line 25 — tier 1, unaffected)
and Python-side `Path.exists()` probes; every conflict scenario in the
suites couples a real read or write. The pre-change suite run
([fs-metadata record](2026-10-28-SOL-FS-METADATA.md)) stays green under the
design's invariants; the slice below adds its own.

## Proposed first implementation slice

Regression cases first, then the store, then uniform routing:

- [ ] `sol-fs-check`: metadata on a chmod-000 file answers present (this
  doubles as the instrumented proof that metadata never opens contents —
  any content read fails the check), a FIFO answers without a content
  dependency, and a large sparse file's `stat` does not scale with content
  size.
- [ ] `sol-fs-check` or `sol-txn-check`: a presence-flip conflict — the
  script promises a missing path, a foreign actor creates it mid-run
  (SOL_FORCE_RETRY machinery or the concurrent-writer harness), and the
  run conflicts once then commits on retry.
- [ ] Implement `txMetaReads` with promised-field recheck, route
  `exists`/`stat`/`isDir` through it, fold directory metadata in, extend
  `touched` and `txChildOverlap`.
- [ ] Keep `txForget` revoking meta reads too (the realtime escapes must
  drop presence promises on paths they just wrote).
- [ ] Promote the query/dependency table above into the semantics
  reference; tick the plan's "Separate metadata observations from content
  snapshots" and "Specify metadata validation separately" checkboxes with
  this record linked.

Non-goals for the slice, unchanged from the plan: `lstat`/link-policy
spellings, recursive walking, snapshot-storage redesign, typed
`Ok/Err` filesystem results.
