# Persistence failure handling

`KvLog.tryPut key value db` returns `Result Unit String`. The store changes its
in-memory map only after the append succeeds. Error replies are copied before
the actor message is released. `KvLog.put` keeps its existing Unit-returning
interface, but now raises a named error on failure. Consequently, Live cannot
continue updating, dispatching commands or broadcasting success after a failed
journal or field append. This is fail-fast behavior, not graceful recovery.

`Live.restore fields db initial` now returns `Result model String`. Missing
fields retain their initial values; existing fields that fail decoding return
an error naming the storage key. Both generated and custom codecs follow this
rule. `Live.serve` checks restoration before opening its listener. Code that
constructs `Live.Field` directly must now provide a Result-returning decoder.

`Live.replay` rejects an undecodable event instead of skipping it. Its error
names the one-based event position. Journal envelopes require a string event
kind, an integer session ID, and the fields required by that event kind.
Commands returned during replay still are not executed.

Run `python3 tests/check_persistence.py` after building the compiler. It checks
successful and failed writes, unchanged memory after an append error, missing
and valid fields, incompatible generated/custom decoders, valid replay,
incompatible events, malformed envelopes, fail-fast put, and compaction.

## Guarantees still absent

- An append error can leave partial bytes on disk. It is not a rolled-back
  transaction; callers must not assume blind retries are safe.
- There is no fsync policy or atomic multi-field commit.
- KvLog's raw record parser still skips malformed log lines. Strict decoded
  event validation does not detect records discarded by that parser.
- `AtMostEvery` still needs a later event or orderly shutdown to flush a
  deferred change; there is no independent flush timer.
- Schema/version migrations and cross-version replay remain application work.
- These changes do not repair or establish the absence of scheduler races.
