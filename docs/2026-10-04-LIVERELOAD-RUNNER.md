# Live reload: the first runner implementation

Date: 2026-10-04. Implements the first slice of
[the object-level reload proposal](2026-10-03-LIVERELOAD.md).
This is a working QOS Portable integration, not the complete dev loop.

## The language/library boundary

`std/mvu` now carries `EReload info` and `EReloadRefused info reason`, with
`Reload = {name : String, from : String, to : String, version : String}`.
`runLive me cfg mapp reload` owns the environment; its adapter has the contract
`reload me info env -> Result env String`. The adapter runs between updates.
On success, update receives `EReload` with the replacement environment. On
failure, update receives `EReloadRefused` with the old environment. Ordinary
events later in the same batch see the adopted environment. `MQuit` stops
processing the batch before any further attachment.

`SEvents port` subscribes to typed events queued by `eventsPort`. It preserves
order within that port; it does not promise a global order across input sources
or senders. `portSync me port` acknowledges that the sender's prior events
have reached the queue, using the existing per-sender FIFO guarantee. Event
strings are copied before the drained receive root is dropped.

The persistent render worker receives the current environment in each frame
request, instead of capturing the initial environment for its lifetime. A
successful swap forces a statics rebuild even if the app's key did not change.
The runner terminates its render worker on quit. Subscriptions are evaluated
once per turn, including the typed-event subscription.

`LiveApp init update subs view` has `view env model -> scene` and is run by
`gameLive me cfg app reload`. Existing `App` retains `view model`; `game` and
`run` retain their old call shapes. A runner with no adapter refuses a reload.
`MApp` statics still receive viewport/model only; its dynamic `vals` receive the
current environment. The browser driver has not acquired a reload adapter.

## Attachment policy belongs to FP-RISC

`std/reload.attachAt baseline attach bytes` validates a stored baseline index,
invokes the platform attachment callback and gates exactly one new table with
`Mod.compatAt baseline candidate`. A refusal detaches the candidate registry
entry. `bindAt` resolves exports within an adopted table, without a global
newest-name lookup. This is important when several live modules coexist.

The adapter must register one table on `Ok`, none on `Err`, and be the sole
attachment writer during the operation. This library does not provide a
registry transaction or synchronization against other attachment actors.
Loaded images remain mapped. Code that consults global `Mod.find` concurrently
can see a candidate before the gate; the supported live runner uses its own
scoped function values. Stored old function values remain callable.

QOS `std/mvureload` supplies store retrieval and `Plug.attach`; it delegates the
shared gate and binding policy to FP-RISC. `tests/livereload.fpr` now uses this
path through MVU. Update ignores successful reload events, and its accumulator
survives the swap. An unrelated table between math versions proves the gate
compares the stored math baseline rather than the globally newest table.

## Verification

- `python3 tests/check_mvu_reload.py`: six variants on one hart and three
  repeated four-hart executions each. Runner ordering, ignored/observed reload
  events, rejection, unchanged legacy runners, environment-aware views, statics
  invalidation, quit, and invalid baseline preflight all pass.
- Host tests explicitly supply `tests/base/mvuclock.c`, a deterministic test
  clock. The current MVU driver still uses QOS's `read`/CLINT clock interface;
  that historical test used a clock shim; the production clock and attachment
  path now have separate coverage in POSIX-RELOAD.
- QOS `python3 tools/mvu-reload-check.py` checks real plugin images on one/four
  harts: `20,22 -> 30 -> refused -> 36`, accumulator `108`, three frames/two
  statics builds, old saved function returning `20`, and three adopted tables.
  Missing store image and missing baseline both refuse without adding a table.
- QOS smoke suite: 16/16 passed, including its existing MVU engine, shell
  controls, browser multi-client driver and three RV64 virt legs. The legacy
  `pathnotes` message-port/loader application and interpreted Sol `mvutick`
  (31 frames/four statics builds) also passed. This is not a native
  RV64 reload test or a complete check-all sweep.

## Remaining work and delivery order

1. Runtime interface stamps and gates are now implemented in
   [RUNTIME-INTERFACES](2026-10-04-RUNTIME-INTERFACES.md), following
   [CHECKED-INTERFACES](2026-10-04-CHECKED-INTERFACES.md). Types, contracts and
   ABI are compared for trusted compiled images; opaque boundaries refuse.
   Source identity matching against event `from`/`to` is now implemented in
   [RELOAD-IDENTITY](2026-10-04-RELOAD-IDENTITY.md) for trusted compiled images.
   The production publisher/watch path and its binding policy remain open.
2. POSIX attachment and a production clock are implemented in
   [POSIX-RELOAD](2026-10-04-POSIX-RELOAD.md), with real host module/MVU tests.
   Store watching (`SStore`/`std/watch`) and `fpr watch` publication/restart
   remain open.
3. Typed live-module declarations and automatic rebuilding of their env rows,
   instead of the explicit adapter used here.
4. QOS journal/replay through the new event path, followed by migration of the
   other drivers and deletion of the old loader/livereload libraries. The new
   adapter does not write `sys/live`; legacy loader replay remains available.
5. Image reclamation, transactional/concurrent registry publication and measured
   long-session costs. Each accepted or refused attachment still retains its
   mapped image; sending the env each frame adds copying cost.

Native RV64 attachment, real browser/GL reloads, major-version restart and the
complete check-all sweeps are not established by this slice.
