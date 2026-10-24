# Regions, stage 1: a message dies with its turn

Date: 2026-10-24. Kind: runtime and compiler change, with its checks. Stage 1
of [2026-10-23-COST-SIZED-REGIONS.md](2026-10-23-COST-SIZED-REGIONS.md).
Baseline numbers: [2026-10-24-REGIONS-STAGE0.md](2026-10-24-REGIONS-STAGE0.md).

## The rule

A received message is the turn's input and dies when the turn ends. The
runtime enforces it; the compiler inserts no `drop` any more.

Every root an actor takes from its mailbox (`take_at`, every receive form)
joins the actor's list of received roots (`fpr_rx_t` in the acb,
`runtime/fpr.h`). The list is released, newest first, at every boundary
where the next state has just been copied out, so nothing the actor keeps
can point into the dying message:

| boundary | where | released |
|---|---|---|
| a `Sys.loop` or `Sys.loopWith` turn, and the receive-loop trampoline (`$receiveLoop`, which runs through `g_loop`) | `runtime/runtime.c`, after `transfer_copy` of the next state | the roots taken since the loop's scope began |
| a `Sys.arena` | after `transfer_copy` of its result | the roots taken inside it |
| `Sys.poolReset` (the hand-written loop's own boundary, `A.tidy`'s `boundary` included) | `g_poolReset`, before the borrow windows are drained | the roots no open region owns: those received outside every `Sys.loop` and arena scope; a region still open keeps its current turn's roots, since its state is not copied out yet |
| the body returning | `trampoline` in `runtime/actors.c`, before the result's own release | all of them |
| death by kill or trap | `reap` | all of them, and the grown list block |

Regions nest: each scope records the list's length at entry (`rx_mark`) and
releases only what was taken above it, so a receive before a loop keeps its
root until the enclosing boundary, and an inner arena's receives die with
the arena.

Outside every region there is no boundary: a root received by a loop the
compiler does not recognise, or deep in a call, is held until the enclosing
region's turn ends, or `poolReset`, or the actor's end. The alternative was
tried and withdrawn (below).

## Never silent

The list starts inline (`FPR_RX_INLINE` 8 roots) and doubles into a buddy
block when one turn holds more. Every doubling is counted
(`fpr_rx_grows_count`) and the most roots one actor held at once is kept
(`fpr_rx_hwm`); `tests/arc_churn/arcprobe.c` exposes both as `Arc.rxGrows`
and `Arc.rxHwm`, and the deadlock dump prints each actor's `roots`. There is
no cap: a receive loop the compiler does not recognise, or a receive deep in
a call with no boundary above it, holds its roots until the actor ends, and
the gauges say so. That is the shape the proposal names ("what remains
grows visibly as `Dynamic` until the enclosing turn ends").

## What changed

- `runtime/fpr.h`, `runtime/actors.c`, `runtime/runtime.c`: the list, its
  four operations, the boundaries above, the gauges. The acb grew by the
  list, so `FPR_NATIVE_ABI` moves to 8 on hosted A64 and 7 elsewhere:
  kernels and modules rebuild together, as they did for the scope chain.
- `compiler/FPRISC.hs`, `compiler/Compile.hs`: the `autoDrop` pass is
  deleted (its five shapes, the transitive receive-origin set, the notes).
  `codegenRev` 89 to 90.
- `core/prelude.fpr`: `serve` is an explicit `Sys.loop` whose every turn is
  one request (`serveTurn`). The request dies with the turn and the next
  state is copied out of it, so a handler may keep parts of the request in
  its state. The state may not hold a Vector; `Sys.loop` refuses that by
  name, as it always has.
- `examples/service.fpr`: `Put k v -> (Map.insert k v state, Stored)`, no
  `keep`. `std/task.fpr`: `poll` returns the worker's value as it is (it runs
  inside the collector's `Sys.loop`, whose turn copies `done` out); `start`
  receives the collector's answer inside a `Sys.arena` of its own and returns
  it: the answer is copied out to the caller and the message dies at the
  arena's end, whatever loop the caller is in. Without that region the
  `repeat` loop of `tests/base/taskfailure.fpr` (600 `Task.map` calls from an
  unannotated, hence unrecognised, loop) held 600 collectors' answers and
  their slabs in `main` and ran a 64 MiB heap out; a library call that
  receives on the caller's behalf owes the caller a boundary.
- `tests/base/autodrop3.fpr`, `tests/check_base.py`: the check asserts that
  the compiler prints no `autodrop:` note and that the runtime ends with
  `arc_live = 0` and `rx_grows = 0` on one and four harts.
- `tests/base/turnroots.fpr` (new, in `check_base`): a `serve` store keeps
  5,000 requests' keys and values with no `keep` and every one reads back,
  zero roots left after the loops; a root received inside a `Sys.arena` is
  gone at its exit with the result intact; a root received outside every
  boundary is held (1) until `Sys.poolReset`, then gone; under 16 MiB
  retained; on one and four harts.
- Probe-only, from stage 0: `cost_state_copies`, `cost_state_bytes`,
  `FPR_COST_REPORT`.

`Sys.poolReset` already ended the borrow windows ("soft death = end of
frame"); it now ends the turn's received roots first, so a hand-written loop
that resets its pool each round (the `backend` of `tests/base/mvuscoped.fpr`:
`(from, q) = receive me; reply me from q`, with `Sys.poolReset 0` in `reply`)
frees each request as autodrop's inserted `drop` did. Without this the first
suite run held 20,000 request roots and their senders' slabs in that actor
(108 MB over the test's frames). The children of a released root stay
readable until the reset's own drain, exactly the window the old `drop` left.

Not changed: `A.tidy` (it is `poolReset`, so it gets the same boundary),
`sendArc` (a share received is a root like any other and dies with the turn
unless dropped or kept), `keep` and `drop` as primitives, the Builtin
profile.

## Acceptance

From the proposal's table, all on this Mac, `./fpr` built from this branch:

| check | result |
|---|---|
| autodrop2 (3,000 direct destructures, 3,000 Result-wrapped receives) | under 32 MiB each way |
| autodrop3 (100,000 pingpong messages and 1,000 Result-wrapped receives, bare `case receive` bodies, no drop anywhere) | `arc_live = 0 rx_grows = 0` on 1 and 4 harts; no `autodrop:` note from `-v` |
| deadmail (900 deaths with 49 KiB of mail unread) | under 16 MiB on 1 and 4 harts |
| receiveturns (1,000,000 ordinary recursive receives) | bounded, caller and roots survive, on 1 and 4 harts |
| `examples/service.fpr` without `keep`, driven over HTTP (52 responses: puts, 40 parallel puts, gets, keys, digests, bad paths, shutdown; 93 log lines) | every response byte-identical to the build before this change; the log lines identical as a multiset (the 40 parallel puts land in a different order each run, before and after) |
| `std/task.fpr` without `keep`/`drop` (`tests/std/apps.fpr`: `Task.mapBounded 3`, `Task.map` over digests) | output identical to the build before this change |
| turnroots (new) | as described above, on 1 and 4 harts |
| mvuscoped (`tests/check_mvu_reload.py`: 20,000 frames against a hand-written `poolReset` backend) | under 4 MiB on 1 and 4 harts, once `poolReset` became a boundary (it held 108 MB before that) |
| taskfailure (`tests/check_deadlines.py`: 600 failed joins from an unrecognised loop, 64 MiB heap) | HOLDS on 1 and 4 harts, once `Task.start` received inside its own arena (it exhausted the heap before that) |
| `python3 tests/check_base.py -j 4` | PASS: 125 jobs in 632 s on 4 workers, exit 0 (this Mac), on the final runtime. Three earlier runs each stopped at one failure and taught the stage something: mvuscoped (the `poolReset` boundary), taskfailure (the `Task.start` arena), and `tests/check_actor_claim.py`, whose harness compiles `actors.c` alone and needed a stub for the new push hook (it now also asserts that every take joins the turn) |
| QOS sweep (`check-all.sh` with `FPRISC_ROOT` at this worktree) | 149 passed, 4 failed, 9 skipped of 162 on this runtime. Three of the four are not this change: gfxapps and the Main Profile failed on a stale `qosp-gl` (built by the stage 0 probe run from the baseline tree and newer than the worktree's compiler, so make kept it: "built for abi 22.90 but this shell is 22.89"), and pass after a forced rebuild; the liveboard leg timed out on a websocket read under the sweep's load and passes alone. The fourth is real: `tests/preferences.fpr` (below). |

## The one red leg, and the window that was tried

`tests/preferences.fpr` in QOS asserts that 500 preference updates leave at
most eight more live roots. A probe copy of the test, run on this runtime,
showed the holder: not the frozen legacy `ep#c66ad65e68dd97f5` it also
imports (that module only supplies client helpers there), but the namespace
actor of the bounded module `epservice#e8bce05a1ddf73db`, whose loops are
`A.tidy`-managed hand loops (`m = receive me; (from, id, q) = m; ...`) that
relied on autodrop for the per-message `drop`. Under this stage's rule each
request root now lives until the actor's next `poolReset`, which `A.tidy`
fires only when the actor's heap has doubled; between resets the roots pin
their senders' message slabs, which `heapUsed` does not see. Measured: 16
roots over the check's 8 on one hart, 69 held by the namespace at that
point, all released by its reset. Bounded by the tidy cadence, so not a
leak, but more than the check allows.

The repair would be one line per loop in `epservice.fpr` (`_ = drop m` after
the destructure, as its `untilStep` already has) and a re-pin of the test to
the new version. It is written in the QOS worktree
`/Users/jasonqin/Documents/GitHub/qos-regions` (branch `regions-stage01`,
uncommitted), with the `unsafe` signatures the module's own helpers were
missing, but `fpr commit` refuses to mint the version: the safe/unsafe line
fails on the frozen dependencies the module pins (17 functions of
`std/actor#201a0e9bf98a5154` and 14 of the legacy `ep#c66ad65e68dd97f5`
lack explicit `unsafe` signatures under today's rules), and the unmodified
module fails the same way. Every one of the 23
pins of `epservice` in QOS, Main's included, is the frozen `e8bce05a`, so the
fix also needs QOS's publication workflow, not a test edit.

The obvious runtime repair was tried and withdrawn: a receive with no region
open releasing the actor's earlier roots, the old law's borrow window, so
unrecognised loops behave as under autodrop. It is unsound for the shapes
autodrop declined (a root still read after a later receive): with it, three
kernel legs the first sweep passed read freed messages (qlog routing's
`nativeowner`, the failure injections' `nativerefusal` with "blk: page out of
range", epecho). The runtime cannot tell the two shapes apart; that analysis
was autodrop.

What remains is QOS's: mint the corrected `epservice` (which means a
`std/actor` and `ep` pin the safety line accepts, or a commit that waives the
dependencies' line), or let the preferences check measure after a tidy
boundary. Decided 2026-10-24: this branch is committed with that one leg red
and the QOS repair left in its worktree, unminted; the leg is the open item
of this stage.

## What a turn costs now

A receive pushes one word (a bounds check and a store); a boundary pops and
decrefs what it pushed, which is the decref `drop` cost before. A decref
scans the current turn's list for the value first, usually one or two
entries. Stage 0's turn costs were not re-measured on this branch beyond the
checks above; `tools/regions-stage0.py --home <this worktree>` reruns them.

## What stage 2 now needs

Stage 2 is boundaries at self tail calls and cost-chosen calls. What this
stage leaves for it:

- **A boundary that is not a receive loop.** The list and its marks are
  ready for any scope: a self-tail-call boundary opens a scope, copies the
  arguments out and releases above its mark, exactly as `g_loop` does. The
  swarm keeper and `ping` (the proposal's rule 2 examples) are receive loops
  the compiler already recognises or declines for a reason the notes give;
  stage 2's work is in `ReceiveTurns.hs` or beside it, not in the runtime's
  release path.
- **Library calls that receive for their caller.** `Task.start` now opens
  an arena around its receive; `ask`, `A.call` and the `std/store`,
  `std/kvlog` and `std/journal` request helpers still hand the caller a root
  (or `keep` a copy and `drop`, by hand). Each is a one-line boundary of the
  same shape, and the two suite failures this stage met (mvuscoped,
  taskfailure) were both hand-written loops that an unrecognised shape left
  without one. The QOS sweep is the measure of how many more there are
  (below: one, in a frozen module).
- **Roots received before a loop.** A receive in a start function that then
  enters a recognised loop (`irqRouteStart`, `logStart` in the prelude) holds
  its one root until the actor ends, because the loop's initial state is not
  copied on entry and the caller's frame may still read it. One slab hold per
  such actor for its life. Copying the initial state on loop entry would
  release it, at the price of one copy per loop activation; whether that is
  worth it is a stage 2 measurement.
- **`serve` copies its whole state every turn.** The service's `Map` is
  copied per request, as stage 0's row A prices it (320 bytes and 110 ns per
  entry for an `Entry`-sized value). Stage 3's generational copy-out is the
  fix; until then a store of 100,000 keys pays about 10 ms per request.
- **Higher-order and polymorphic receive loops.** `serve` could not be a
  recognised turn (a function-typed and a polymorphic live parameter), which
  is why it is an explicit `Sys.loop`. A loop-invariant parameter (passed
  unchanged by every call in the group) need not be copied at all; teaching
  `ReceiveTurns.hs` that would recognise every `serve`-shaped loop in
  applications too.
- **`frames.fpr` in the stage 0 harness** needs its `--with` device file.
