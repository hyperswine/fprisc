# Wire frames and group commit for the stores

Kind: design and measurements. 2026-10-14.

## Why

Measured on main before the change, fifty actors writing to one `std/kvlog`
at once got about 50,000 puts a second -- 18-21 us a put, the same on one hart
or four. Almost all of it was the append: `fileAppend` opens, writes and closes
the file every time (18 us alone), inside the one actor that owns the log. The
round trip to that actor was 1-3 us. `post` did not help: the store's 64-message
mailbox fills and posters wait at the append rate. The same 10,000 lines
written as 200 appends of 50 cost 1 us a line.

With the disk write that cheap, the JSON codec was next: a typical record
(a cart with three items) took 6 us to encode and 9 us to decode, and opening
a log is all decoding.

## What changed

**`std/wire`** (new). One binary format for what a compiler-minted codec
speaks (`Wire`) and for `Json.Value`, which needs two tags `Wire` lacks
(`Json.toWire` maps null to "" and a real to its text; the format keeps both).
A value is a tag byte, varints and length-prefixed bytes. The dial:

| Level | What is inline | Records |
|---|---|---|
| `Fast` | names and strings | each stands alone |
| `Compact` | strings; a record field or constructor name is defined once per stream and then numbered | depend on earlier ones in the stream |
| `Small` | nothing repeated: every string is numbered too | the same |

A stream is a header (`FPRW`, a version, the level) and frames: a varint
length, the payload, an Adler-32 of the payload. Reading keeps the valid
prefix and reports how many bytes after it it could not read. `pickle` /
`unpickle` are one value with a header; `encoder`, `decoder` and `continuing`
are for logs that append (`continuing` numbers a new record the way the file
read so far did). The format never depends on the runtime's heap layout, so a
later runtime reads what an earlier one wrote -- the reason a memory image was
not the format.

**`std/logfile`** (new). An append-only file kept open by its one writer,
shared by both stores. A kept descriptor keeps writing to the file it opened
after the path is removed or replaced, and everything written then would be
lost at restart, so `ready` checks before each write that the path is still a
regular file of exactly the size this writer left. It answers `Same`, `Fresh`
(an empty or missing file, now open), `Other` (a different non-empty file, now
open) or `Failed` with a sink that never holds a closed descriptor. Also
`replace` (written beside and renamed over), `truncate` and `wholeLines`.

**`std/kvlog`**.
- *Group commit:* the actor takes every request already waiting (up to
  `batch` = 1024, a bound on how long one writer waits behind others, not on
  what is accepted), and a run of puts is one write. A put is answered after
  its batch is written; a get, keys, size or compact first writes the puts
  before it.
- *Formats:* `open` keeps a file's format and starts new files as JSON lines,
  so existing logs and programs are unchanged. `openWith fmt` starts a new log
  in `fmt` and makes `compact` rewrite into it, which is how a log changes
  format. `dump` reads either as JSON lines; `history`, `at` and `records` read
  both.
- *Damage:* a torn tail is reported and cut off at open, before anything is
  appended after it. The JSON format had the same hazard: an append after a
  torn line was glued to it and lost. A binary log whose write fails stops
  taking writes until reopened (the file may end in a partial frame); every
  answered record survives. A binary log refuses a non-empty file swapped in
  under it that it did not write, because its numbering would mean nothing
  there.

**`std/store`**. Shard files stay open through `std/logfile`; `openWith fmt`
gives shards the same formats (a JSON store migrates shard by shard as each
compacts); a torn shard tail is cut at reopen. A failed append still stops the
program, as before.

## Measurements (macOS arm64, this Mac)

| | before | after |
|---|---|---|
| kvlog, 50 writers x 200 puts | 18-21 us a put | 2-3 us (JSON lines or Compact; 1 or 4 harts) |
| kvlog, one writer | 23 us a put | 6-7 us |
| kvlog, reopen 10,000 records | 32-35 ms (JSON) | 18 ms (Fast, Compact or Small) |
| store, one writer | 23 us a put | 9 us (JSON or Compact) |

Log sizes for the same 10,000 records: JSON 816 KB, Fast 567 KB (69%),
Compact 379 KB (46%), Small 274 KB (34%). The 100-record test in
`tests/std/kvwire.fpr`: 11,930 / 8,656 / 5,958 / 4,830 bytes.

Encoding a typical record takes 2-4 us in Wire against 6 us in JSON, and decoding
it 1-2 us against 9 us. Reopening improves 2x rather than 4-9x because replay
also rebuilds the map and checks every checksum.

## Limits

- **The store's writes are still serial.** Its front waits on the shard for
  every put, so a shard never has two writes queued and group commit cannot
  batch there. Writes should be routed as reads already are (the front says
  which shard; the writer asks it), and then each shard can group-commit.
- **No fsync.** A put is answered when the OS has the bytes. Group commit is
  what would make an fsync per batch affordable; the primitive does not exist.
- **Two `Format` types.** `KvLog.Format` and `Store.Format` have the same four
  constructors, declared in each module.
- The batch bound and the binary-write latch are new behaviour of `std/kvlog`;
  the JSON-lines path keeps its old answer to a failed write (it continues).

## Tests

`tests/std/kvwire.fpr`: every level round-trips through a reopen (null,
reals, negatives), `history` and `dump`, a JSON log migrated by compaction, a
torn tail cut at open, a foreign file refused. `tests/std/storewire.fpr`: the
store contract in Compact, a reopen keeping each shard's format, a JSON store
migrating, a torn shard tail. `tests/std/compact.fpr`, `tests/std/store.fpr`
and `tests/check_persistence.py` are unchanged and pass.

## Store writes routed to their shard (2026-10-14, later)

The first limit above is gone. The front no longer forwards a write and waits
for the shard; it ROUTES. A writer asks it which shard holds the key
(`FRouteW`, which starts a shard that does not exist yet), sends the put or
removal to that shard itself, and reports the shard's answer back
(`FCounted idx n ver`). The answer carries the shard's **write version**, one
more for every put or removal; the front keeps the highest version per shard,
so two writers' reports arriving out of order cannot roll a count back. The
writer waits for the report's answer before `put` returns, which keeps the
documented promise that a read following one's own write sees it (the plan is
built from the front's counts). A removal routes with `FRouteRm`, which never
starts a shard.

Shards now take every request already waiting (up to `batch` = 1024) and
append a run of puts and removals as one write, answering each writer with the
count and version after its own write; a read in the run first sees the writes
queued before it. Compaction runs after the batch.

Measured (50 writers x 200 puts, 10,000 keys over 40 shards; this Mac):

| | previous main (586cc1d) | routed |
|---|---|---|
| 1 hart | 10 us a put | 11 us |
| 4 harts | 10 us a put | 4 us |
| one writer | 7 us | 8 us |

Every run ends with exactly 10,000 keys and every writer reading its own last
write. Writes now scale with harts; a lone writer pays about 1 us for the
extra round trips (route, shard, report instead of one round trip to the
front, which made two of its own). A failed shard append still stops the
program.
