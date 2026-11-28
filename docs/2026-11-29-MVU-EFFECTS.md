# std/live in-turn commands; pos1, inventory and printer-host updates made pure (29 November)

Branch `refactor/mvu-effects` in fprisc, inventory and printer. The point:
`update` should be a pure function that answers commands, as Elm's is, and
the disk, the clock and blocking calls belong to the driver.

## std/live: commands performed in the turn

`Live.Cmd` had After, Run, Navigate, Emit and Quit. `Run` performs its work
in a new actor, which is right for slow work but wrong for the writes
pos1 and inventory make: the order of their journal is its meaning, and
a page must never show a change the disk does not have. So both apps did
the append (and the clock reads that time each event, and pos1 also did
its metrics file) inside `update`.

Five new constructors, modelled on std/game's `Task` (the app names the
work and says which message the answer becomes):

| command | performs | answer |
|---|---|---|
| `Append j lines toMsg` | `Journal.append lines j`, one write | `Ok us` (how long it took) or `Err why` |
| `Put db key value toMsg` | `KvLog.tryPut key value db`, waited for | `Ok Unit` or `Err why` |
| `WriteFile path text toMsg` | written beside, renamed over | `Ok Unit` or `Err why` |
| `Now toMsg` | `Clock.now` (wall clock, seconds) | the time |
| `Took toMsg` | none | how long the asking `update` took, in us |

The register performs them **itself, in the order given, after `update` and
before the broadcast**. Each answer is run through `update` at once as
`Live.Msg 0 reply`, in the same turn. No other event comes between, and the
sessions see the model once, after every reply. A failed Append or Put
**withholds the broadcast**. The app's reply handler decides what happens
next: pos1 and inventory stop the process, as they did before. The other
commands (After, Run, Navigate, Emit, Quit) are performed after the in-turn
ones, in their own order. This is a change only in that in-turn effects now
come first, so the disk has a change before a Navigate or Emit for it goes
out.

`Live.turn seen update ev model` is that turn without a server. It returns
the model after every reply, the commands left for the driver, and whether
a durable write failed. `advance` is now `turn` plus the existing persist,
perform and broadcast. When `journal = True`, replies are journaled like
any event, so `Live.replay` still rebuilds the model.

The rules for apps:

- Accept replies from sid 0 only. A reply constructor is part of the app's
  `Msg`, so it is in the codec and a browser can send it. pos1, inventory
  and printer-host match `Live.Msg 0 (Reply ...)` and treat any other sid
  as an unknown action, as they already do for `Clear`.
- A reply that asks for another in-turn command loops. The register does
  what it is told.

Sol's `sol/lib/live.sol` has its own `Cmd` and is unchanged.

Golden test: `tests/std/liveturn.fpr`, a special case in `std-golden`
because it runs in a temporary directory with a journal path. It covers
reply order, the commands left for the driver, a forged reply from sid 1,
and an append to a journal whose file was removed (Err, held, Quit).

## inventory (`src/inventory.fpr`)

`update` no longer calls `Sys.timeUs` or `Journal.append`:

- `flush` hands the pending lines to `Live.Append` and clears `pend`.
- `Live.Took (Timed kind)` times each event.
- Three reply messages update the profile: `Timed kind us`, `Wrote us` and
  `WriteFailed why`.

`WriteFailed` stops the process with `Program.fail 1`. It used to be
`error`, which an actor now contains: that would leave a server that
answers the page and never commits again (pos1's note). Still in `update`:
`Clock.now` for line timestamps and `randomHex` at sign-in.

## pos1 (`examples/pos1.fpr`)

- The journal append is `Live.Append`. Boot keeps a direct write
  (`flushNow`) for the seed, because `init` is not `update`.
- The metrics file is `Live.WriteFile`. It runs in event order, so a later
  stock never loses to an earlier one, which a `Run` could allow. A failure
  shows on the Admin profile instead of stderr.
- Event timing is `Live.Took`.
- New replies: `Timed`, `Wrote`, `WriteFailed`, `MetricsWritten` and
  `MetricsFailed`.

The restock line now folds through `pos1_core.restock` and its contracted
`addStock`. This is the same call the register makes before committing the
line, so every line the register wrote folds to the stock it reported.
Before, the fold added the delta unchecked. A line the core refuses moves no
stock and is counted: `refused` is printed at boot and reported by
`rebuild`. Such a line can only come from a log written before the 9999
shelf bound (2026-10-17) or edited by hand.

**This can change a production shop's folded stock** if its log has such a
line. Check the shop log before deploying. The boot line will say so.

`setStock` stays the plain delta for sale and void lines. A sale's
quantities were clamped to stock by `Core.quantity` when it was committed,
and a void must return exactly what its sale took, so neither may be
refused at fold time.

Still in `update`: `Clock.now` in committed lines, `Journal.lines` in the
console's `rebuild`, and pricing's `Watch.poll`/`Reload.reload`.

## printer-host (`src/printer-host.fpr`)

`update` made two blocking actor calls (`Registry.get`, `Care.get`) on every
event and a third (`Care.change`, which saves the maintenance log) on a care
change. Now:

- On `Tick`, a `Live.Run` command reads the registry snapshot, the care
  state and both clocks, and replies with `HostRefreshed raw notes mono now`.
- A `CareChange` from a session is a `Live.Run` that calls `Care.change`
  and replies with `CareDone sid raw notes`. The reply sets that session's
  notice and emits `care-saved` when the change was saved.

Run replies can arrive out of order, so a care state older than the one
held (by `rev`) and a snapshot older than the one held (by `generated_at`)
are not adopted. The registry and care data now refresh once a second (the
`Tick` period) instead of on every event. Both reply constructors are in
`printers.fpr`'s `Msg`.

## Checks

- fprisc: `sol tests/run.sol --jobs 6`: 139 pass, `trust:std/toml.fpr` a
  known failure. `cost` failed once on its 60 s Todo-report limit (60.1 s,
  with another worktree's suite running) and passed when run alone (12 s).
  std-golden: 63 cases, 0 failed, `liveturn` included. `make unit-tests`:
  all 50 suites pass.
- `tests/bench/e2e`: all four default runs, with the shop log's sale count
  matching each time. Before and after on the same compiler: 1x200 at
  112.0 vs 112.5 sales/s, 403 frames both. 8x25 is noisy (167-209 sales/s
  on main, 135-185 here).
- A restock fold probe gave FW 22, BIG 9999 and 3 refused, as expected.
- inventory: `sol project.sol test` passes (native checks and loopback HTTP).
- printer: `src/printers.fpr` and `tests/care.fpr` build, and the care
  policy passes. `src/printer-host.fpr` does not build on main because
  `gateway.fpr` still calls the removed std/httpclient (this was already
  so). With that one call stubbed in a scratch copy, printer-host builds and
  `tests/check.sol` passes (gateway, login, telemetry and logout).
