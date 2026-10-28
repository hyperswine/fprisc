# Sol Phase 2: bytes, bounded streams and script I/O

Date: 2026-10-29.
Kind: delivery record, API reference and verification evidence.
Scope: HostedBytecode / `fpr sol`, Phase 2 of the
[daily scripting plan](2026-10-27-SOL-DAILY-SCRIPTING-PLAN.md).
Baseline: `27a4cdc`; implementation and evidence are in the working tree.
Status: locally implemented and verified on macOS arm64. Linux, native EXDEV
execution and hosted CI are not claimed. Requires the `unix` package >= 2.8.

## Bytes and UTF-8

`Bytes` is an immutable exact-octet value, separate from String and BStr.
Equality compares bytes. Rendering shows its byte count, not binary contents;
use explicit output APIs to emit data. Bytes and stream capabilities are opaque
runtime values; constructing their nominal type markers does not forge them.

| API | Contract |
| --- | --- |
| `Bytes.empty Unit` | Empty Bytes |
| `Bytes.fromList xs` | `Result Bytes String`; integers must be 0..255 |
| `Bytes.toList b`, `Bytes.len b` | Explicit octet list / byte count |
| `Bytes.at index b` | Checked zero-based access, Result Int String |
| `Bytes.slice offset count b` | Checked zero-based copied slice; no retained large backing slice |
| `Bytes.concat chunks` | Explicit materialization of concatenated Bytes |
| `Bytes.contains needle haystack` | Exact byte substring test |
| `Utf8.encode text` | Result Bytes String; rejects non-scalar surrogates |
| `Utf8.decode bytes` | Strict Result String String |
| `Utf8.decodeReplace bytes` | Explicit replacement decoding |
| `Utf8.decodeChunk carry chunk final` | Strict Result (String, Bytes) String |
| `Utf8.decodeChunkReplace carry chunk final` | Same shape, replacement policy |

For incremental decoding, start with empty carry, pass each returned carry to
the next call, and set final=True on the last chunk or a final empty flush.
Carry is at most three bytes. Incomplete sequences span boundaries; invalid
partial prefixes are rejected/replaced immediately. Strict finalization rejects
a truncated last sequence. List/concat conversions are intentionally materialized
operations; applying them to every chunk is the caller's choice, not an implicit
whole-file conversion in the streaming layer.

## Owned streaming

`ByteReader` and `ByteWriter` are linear, attempt-owned capabilities. The
runtime also checks identity, so a fabricated or foreign numeric marker cannot
access an existing stream. The host owns all open handles until explicit close
or attempt cleanup; standard descriptors themselves are borrowed, never closed.

| API | Shape / behavior |
| --- | --- |
| `Stream.openRead path cap` | Result ByteReader String; regular file, source leaf symlinks refused |
| `Stream.openWrite path cap` | Result ByteWriter String; exclusive new file, private 0600 mode subject to umask |
| `Stream.stdin cap` | Result ByteReader String; shared live stdin cursor |
| `Stream.stdout cap`, `Stream.stderr cap` | Result ByteWriter String; borrowed standard descriptor |
| `Stream.readChunk reader` | `(Result ByteRead String, successorReader)` |
| `Stream.readLine limit reader` | Same shape; byte line includes LF when present |
| `Stream.writeChunk bytes writer` | `(Result Unit String, successorWriter)` |
| `Stream.closeRead reader`, `Stream.closeWrite writer` | Consume the owner; Result Unit String |
| `Stream.foldChunks step initial reader` | `(Result state String, successorReader)` |
| `Stream.foldLines step initial limit reader` | Same shape, with complete byte lines |

`ByteRead` is `EndBytes | ChunkBytes Bytes`. EOF never masquerades as a blank
line. A final unterminated line retains its exact bytes. Chunk/line admission is
1..16,777,216 bytes; invalid limits are errors. A line limit includes its LF.
Write chunks exceeding their writer cap fail without silently truncating.

Each file descriptor is admitted using O_NOFOLLOW and checked as a regular file;
nonblocking open avoids hanging on a FIFO before the kind check. Pipe/terminal
input uses stdin. Directory and other special-file streams are refused.
Callbacks execute through the normal checked VM. Host iteration avoids retaining
one callback frame per input chunk, but a callback that accumulates all bytes
still deliberately retains all bytes. A single admitted line buffer also bounds
fragment overhead when a caller selects a one-byte read cap.

All streams are immediate observations/effects, not transaction snapshots.
Opening them does not populate the exact-byte read set. They refuse pending
transaction effects rather than reading/writing ahead of queued work; folds
recheck ordering between callbacks. Opening/using live streams is reported as
a realtime escape. Existing transaction snapshot reads remain unchanged.

Explicit close, success, panic, abort, retry discard and Ctrl-C run the resource
cleanup paths. Actors are stopped before attempt cleanup. Close does not close
stdin/stdout/stderr. Stdin read-ahead is shared with IO.readLine so switching
between these new entrypoints does not discard buffered input. After a read
error, close the returned reader; resuming a partially consumed failed record is
not a supported recovery mechanism.

## Script host I/O, environment and status

| API | Contract |
| --- | --- |
| `IO.stdout bytes`, `IO.stderr bytes` | Exact output, no added newline; Result Unit String |
| `IO.stdoutText text`, `IO.stderrText text` | Strict UTF-8 exact output; same Result |
| `IO.readLine limit` | Result TextRead String; `EndText | LineText String` |
| `IO.cwd Unit` | Result String String; invocation cwd |
| `Env.get name` | Result EnvValue String; `EnvMissing | EnvText String` |
| `Env.set name value`, `Env.unset name` | Result Unit String; attempt-scoped overrides |
| `Script.exit code` | Stop foreground evaluation, commit, then return requested status |
| `Script.abort code` | Stop foreground evaluation and discard buffered work |

IO.readLine uses strict UTF-8 and removes one terminal LF; CR is retained.
Blank input lines yield LineText empty-string, EOF yields EndText. Exact output
is immediate like print and can repeat on retry; print keeps its existing newline.
Result errors must be handled or unwrapped by the script.

Relative data paths and cwd use the invocation directory. Imports still resolve
relative to the importing source/module. No process-global chdir API was added.
Environment setters affect children launched in the same attempt, including
deferred children at commit. They restore the original values before retry and
at attempt exit. Names/values containing NUL and invalid names are refused.
The environment is process-wide and shared by actors; no per-actor isolation or
environment snapshot validation is promised. Env setters use the immediate
ordering fence; get/cwd are live queries.

Script.exit accepts 0..255 and stops later top-level statements. Any commit,
deferred-effect or cleanup failure that raises an error takes precedence over
the requested successful status; tracked failed effects still return 1. An
explicit nonzero requested status follows a successful commit. Script.abort
accepts 1..255, does not commit, and closes attempt-owned resources. These status
requests are foreground-script operations; an actor exception is governed by
the existing actor failure/lifetime contract.

## Binary file operations and migration

All three Fs APIs return Result with the structured FsError. New operations are
OpCopy, OpCopyPublish, OpRename; new reasons are FsExists and FsCrossDevice.
Update exhaustive reason matches when adopting the expanded enum. Streams keep
String errors for resource/admission/I/O failures.

| API | Behavior |
| --- | --- |
| `Fs.copyNow source target cap` | Bounded direct copy to a new exclusive destination; returns bytes written |
| `Fs.copyPublishNow source target cap replace` | Bounded sibling staging, then complete-file publication |
| `Fs.renameNow source target replace` | Atomic same-filesystem file/directory rename |

Direct copy exposes its in-progress file. On failure/cancellation it removes its
created destination if that inode is still there; an observed foreign replacement
is preserved and reported. The identity-check/unlink window still exists for
non-cooperating writers. Copy publication instead uses a private 0600 randomly
named sibling, independent of destination name length; failure/cancellation
before publication removes the stage and preserves an existing destination.

For copy publication, replace=False uses atomic no-clobber link publication;
replace=True accepts an existing regular non-symlink destination, preserves its
0777 permission/executable bits, and replaces it only after the complete copy
is flushed/closed. New output is private. Owner, ACL and xattr preservation are
not promised. Source leaf links are refused. Source data is read live, so a
concurrent source rewrite is not magically a stable snapshot.

Rename uses the native exclusive rename operation when replace=False, never an
existence-check race or link/unlink approximation. macOS uses renamex_np with
RENAME_EXCL; Linux uses renameat2 with RENAME_NOREPLACE where available. Unsupported
hosts/kernels return an error. replace=True uses ordinary atomic rename and
POSIX file/directory compatibility and empty-directory rules. Leaf source and
destination symlinks are refused; source inode attributes move with the rename.
EXDEV is FsCrossDevice, never an implicit copy/delete fallback.

Copy/rename are explicit immediate effects and refuse queued transactional work.
They do not enter the redo journal, promise exactly-once execution, or provide
power-loss durability. Publication means atomic visibility of complete bytes;
an interrupt at the publication boundary can leave a complete published result.
Hard crashes can leave an identifiable sibling stage. General transactional
binary staging would need durable payload/replay/orphan ownership and remains
unimplemented. Existing retry semantics can repeat immediate work; Phase 3's
non-replaying execution policy is still separate work. Mixing snapshot observations
with immediate mutations can conflict; split runs where their ordering differs.

`moveText source target` names the existing buffered text read/write/delete
behavior. `mv` remains a deprecated compatibility alias with that same behavior;
it has not silently become an immediate binary rename. Existing shipped examples
had no calls to that move helper to migrate (matrix-local variables named mv are
unrelated). New runnable workflows are
[copy-binary.sol](../sol/scripts/copy-binary.sol) and
[filter-stream.sol](../sol/scripts/text/filter-stream.sol):

```sh
./fpr sol sol/scripts/copy-binary.sol SOURCE TARGET
./fpr sol sol/scripts/copy-binary.sol --replace SOURCE TARGET
./fpr sol sol/scripts/text/filter-stream.sol NEEDLE PATH 1048576
./fpr sol sol/scripts/text/filter-stream.sol NEEDLE -
```

## Verification and memory gate

Build: make fpr, GHC 9.8.2, -O1, macOS arm64. Implementation lives in
compiler/Sol/ScriptIO.hs with VM value/ownership/dispatch and entrypoint wiring;
the small exclusive-rename mechanism is in compiler/cbits/fsx.c. No shared native
frontend/backend algorithms changed. The I/O suite is registered in Base.

Verified executable SHA-256:
`b26121365269e6dc89f5233c294d3e644fd72cc77d072fafc6a7cd7866c8e9fc`.

| Command | Result |
| --- | --- |
| `python3 tools/sol-io-check.py` | 84 checks, default JIT mode |
| `FPR_TEST_JIT=0 python3 tools/sol-io-check.py` | Same 84 checks, interpreter mode |
| `python3 tools/sol-fs-check.py` | 103 checks; APFS invalid-byte fixture unexercised |
| `python3 tools/sol-output-check.py` | 26 checks |
| `python3 tools/sol-library-check.py` | 117 checks, including expected unsupported cases |
| `python3 tools/sol-startup-check.py` | 52 checks plus assembly/concurrent writers |
| `python3 tools/sol-text-process-check.py` | 34 checks |
| `python3 tools/sol-examples-check.py` | 21 checks |
| `python3 tools/sol-linearity-check.py` | 8 checks |
| `python3 tools/sol-cache-txn-check.py` | Passed |
| `python3 tools/sol-effects-check.py` | Both legs passed |
| `sh tools/sol-txn-check.sh` | Passed |
| `sh tools/sol-safety-check.sh` | Passed |
| `sh tools/sol-proc-git-check.sh` | Passed |
| `sh tools/sol-scripts-check.sh` | Passed with OS process-inventory access |
| `python3 tests/test_check_registry.py` | 8 tests |

The I/O checks cover all octets/NUL, UTF-8 chunk boundaries and malformed/scalar
cases, exact channels, line/EOF/limit behavior, linear/fabricated handles, a linear
writer threaded through a fold, source-link/destination/overwrite/mode handling,
long names, directory rename, queue fences, environment retry restoration,
commit/abort/status precedence, and cancelled publication/direct-copy ownership.
The retry cleanup case opens 30 readers per attempt under a 96-descriptor limit,
requests exit before their syntactic closes, and forces four retries: 150 opens
in one process succeed only if attempt cleanup actually releases descriptors.

Run the memory gate separately from ordinary unit tests:

```sh
python3 tools/sol-io-benchmark.py --runs 2 \
  --output docs/evidence/2026-10-29-sol-phase2/stream-memory.json
```

The [saved report](evidence/2026-10-29-sol-phase2/stream-memory.json) contains raw
per-process peak RSS/wall times, input/script sources, source hashes, executable
identity and settings. It compares 100 MiB and 1 GiB copy/filter workloads with
64 KiB chunk/line limits, one warmup and two measured fresh processes per case,
interpreter execution, a warm compile cache and output sent to /dev/null.
Copy contents are independently checked with streamed SHA-256 outside the
measured process; filter selected-byte counts are checked by the script.

The gate subtracts an idle-runner baseline and allows at most 32 MiB additional
growth between input sizes. It does not claim a 32 MiB total footprint or an
isolated VM throughput result: the compiler has its ordinary 64 MiB nursery.
Both gates pass; use the report for exact final numbers and binary identity.

| Workload | 100 MiB peak RSS | 1 GiB peak RSS | Growth |
| --- | ---: | ---: | ---: |
| Copy/publication | 157.2 MiB | 163.7 MiB | 6.5 MiB |
| Line filter | 163.7 MiB | 164.7 MiB | 1.0 MiB |

No suitable second filesystem was available for the EXDEV fixture on this Mac;
the suite reports that case unexercised. The Linux exclusive-rename branch and
Linux runtime behavior still need execution there. Hosted CI, the full Base run
and physical boards were not run. Hard-crash orphan collection, transactional
binary publication and general external-effect replay prevention are not claimed.


## Later Phase 5 verification (2026-10-29)

The [installation and release record](2026-10-29-SOL-INSTALLATION.md) supersedes
this delivery snapshot's open Linux/installation gate. Its complete daily-workflow
matrix passes on macOS arm64 and an emulated Linux x86-64 Debian trixie guest,
with exact source/executable identities and explicit remaining exclusions.
The older measurements above retain their original executable identity and scope.
