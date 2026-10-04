# Host module publication and watching — 2026-10-04

`fpr publish math.fpr` checks and commits a pinned module closure, builds its
frozen store blob as a host shared module, installs the image at an immutable
identity/host/codegen path, and only then atomically publishes a journal snapshot.
`fpr watch math.fpr` performs that operation on source-byte changes every 300 ms.
`--once` performs one publication and exits. These original forms do not launch an app.
The explicit `fpr watch app.fpr --module NAME` supervisor is described in
[the host workflow follow-up](2026-10-04-HOST-LIVERELOAD-WORKFLOW.md).

The source version database remains separate. A failed image build may leave a
valid committed source version, but cannot advertise an image or replace the
previous publication. Retrying that version completes publication. A repeat of
an already published version emits no new notification. Major interface changes
are refused by the existing commit checker; this watcher does not restart or
migrate the application automatically.

## Reader contract

The publisher prints its journal path:
`.fpr/publications.<os>-<arch>-cg<revision>.tsv`. Each row contains five tab-separated
fields: module name, version, previous published root hash, new root hash, absolute
image path. The first version has an empty previous hash. Paths may contain spaces;
tabs and newlines are refused. Host journals are separate, and paths are local to
the publishing machine. This format is not a package-server or QOS image protocol.

`std/watch` exposes:

- `start journal`: current row count; use it when the app already loaded the
  latest version and should ignore historical notifications.
- `poll journal name cursor`: `Result (nextCursor, List Candidate) String`.
  It validates unread rows, selects one module, advances past unrelated rows,
  and refuses invalid cursors, truncation, malformed snapshots and read failures.
- `identity`, `image`, `event`: extract a candidate's Reload identity, image
  path, or `MV.EReload` event.
- `watch journal name cursor port me`: actor entry, polled every 300 ms; sends
  copied Reload records onto `MV.eventsPort`, advancing its cursor only after a
  successful poll. The application owns and kills the worker on exit.
- `imageFor journal name hash`: resolve the candidate image inside the runner's
  reload adapter, then call `Native.loadVersionAt` with the actual loaded table,
  `info.from`, `info.to`, and that path. Adopt the new environment on `Ok`.

Use `MV.SEvents port` and `MV.runLive`/`gameLive` to deliver notifications between
ordinary events. Source watcher publication, actor delivery and environment
adoption are separate steps; the runtime registry identity/type/contract gate
remains authoritative. Receiving a notification does not adopt an image.
A rejected candidate leaves the runner's environment intact. An app that rejects
an intermediate candidate will also refuse a later candidate whose `from` hash
does not match its loaded baseline; the host workflow example instead checks against its actual loaded baseline
to permit recovery after a refused intermediate publication.

## Evidence

`tests/check_publication.py`, now in the Base suite, builds real shared modules
and exercises source/type/link refusals, publication lock refusal, retry after a
failed build, duplicate suppression, immutable old images, paths containing
spaces, cursor and malformed-row refusal, automatic actor notifications and
native checked swaps on one and four harts. Published candidates also traverse
the real MVU event port/runner while preserving the model and refusing bad events.
A running source watcher survives an invalid save and publishes the next valid
save without restarting itself. Compiler build and this targeted suite passed on
Apple Silicon macOS. Linux loader execution and full QOS check-all were not run
for this stage.

## Remaining boundaries

- The writer lock serializes these publishers. Standalone `fpr commit` and manual
  store edits must not run concurrently with publication. A killed publisher may
  leave `.fpr/publication.lock`; recover it deliberately after checking no writer
  is running. Temporary orphan images are not advertised.
- Atomic rename protects live readers; this is not power-loss durability (no
  file/directory fsync), signing, or hostile-module isolation.
- Watching covers the named scratch source. Closure dependencies must be pinned;
  changing one means committing it and updating the root's pin. No automatic
  transitive scratch dependency rewriting occurs.
- `MV.runWatched`/`gameWatched` now own the extra event port and the worker
  returned by a starter (`Watch.watchFrom path name cursor`). Cleanup covers
  normal and initial-resize quit and startup refusal. Bounded journal compaction
  and loaded-image reclamation remain unfinished.
- QOS now has Files/qlog publication and an owned watcher adapter: see the
  sibling QOS `docs/2026-10-04-QOS-PUBLICATION.md`. Development build/upload
  bridging and native publication verification remain separate. The legacy
  journal/replay loader is separate.
- The host workflow now offers opt-in checked root-edit cold restarts and a shared
  runner with explicit export bindings. Compiler-generated typed descriptors and
  state migration remain later milestones in the original proposal.

## Owned-runner follow-up verification

The full Base suite passed after factoring the shared catalog and adding
`runWatched`/`gameWatched`, multiple typed input ports and per-turn watcher
allocation boundaries. `tests/check_owned_watchers.py` checks worker/port liveness
after normal exit, quit during initial resize and startup refusal on one/four
harts. Existing host publication, real module reload and legacy MVU tests also
passed.
