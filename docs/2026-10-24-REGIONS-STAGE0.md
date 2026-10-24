# Regions, stage 0: the numbers before anything changes

Date: 2026-10-24. Kind: measurement. Stage 0 of
[2026-10-23-COST-SIZED-REGIONS.md](2026-10-23-COST-SIZED-REGIONS.md): the
per-frame model copy against the model's size, and the state's size against
what a turn allocates, measured on the tree as it was before stage 1
(main `a6043da`) so the later stages have a baseline. The harness is
`tools/regions-stage0.py`; the raw JSON and the run log are in
`docs/evidence/2026-10-24-regions-stage0/`.

## How it was measured

Three probe-only additions to the runtime, nothing in an ordinary build:

- `cost_state_copies` and `cost_state_bytes` on the hart ledger
  (`runtime/fpr.h`, under `FPR_COST_PROBE`): of the copies `cost_copies`
  already counts, the ones `transfer_copy` makes across a turn boundary. That
  is the state's size as the regions plan means it: what survives the turn.
- `FPR_COST_REPORT=1` (or a file path) in a probe build prints the whole
  process's ledger as one JSON line at exit, at `Sys.exit` and at SIGTERM
  (`machine/unix/host.c`, `machine/unix/main.c`), so a program needs no
  `Cost.report` call of its own. `tests/bench/costprobe.c` reports the two
  new counters too.
- The harness builds every program twice from the same tree, plain for the
  time and with `FPR_COST_PROBE=1` for the ledger, the way
  `tools/receive-turn-costs.py` does.

Host: this Mac (Darwin arm64), other sessions building beside the runs; the
ratios are the finding, the nanoseconds are indicative. `Sys.mtime` ticks at
10 MHz, so a tick is 100 ns.

## A. The per-frame copy against the model's size

A `Sys.loop` whose state is the logbook's model (`examples/logbook.fpr`:
`Model = {nextId, rev, sessions : List Sess}`, a `Sess` being five fields,
one of them a short string) with n sessions, and one whose state is a store
shard's `Map Int Entry` (`std/store.fpr`; an `Entry` is an id, a stamp, a
55-byte text and a two-element tag list) with n entries. Each turn changes
one `Int` and returns the state; the loop copies the whole state out, as every
turn boundary does today. One hart, best of three plain runs for the time;
the ledger from the probe build, which runs the same turns.

| n | shape | ns per turn | state bytes copied per turn | bytes per element |
|---|---|---|---|---|
| 0 | model | 36 | 48 | |
| 0 | store | 55 | 96 | |
| 10 | model | 378 | 1,648 | 160 |
| 10 | store | 1,072 | 3,296 | 320 |
| 100 | model | 3,458 | 16,048 | 160 |
| 100 | store | 9,976 | 32,096 | 320 |
| 1,000 | model | 38,236 | 160,048 | 160 |
| 1,000 | store | 109,359 | 320,096 | 320 |
| 10,000 | model | 369,352 | 1,600,048 | 160 |
| 10,000 | store | 1,104,940 | 3,200,096 | 320 |

The copy is exactly linear in the model: 160 bytes and about 37 ns per
session, 320 bytes and about 110 ns per entry (a `Map` node, the record, its
string, two list cells and two static tags), on top of a 36 to 55 ns turn. A
frame that changes one `Int` in a model of 10,000 sessions costs 0.37 ms;
over a store shard of 10,000 entries, 1.1 ms. This is the cost stage 3
(generational copy-out, "proportional to the change, not the model") has to
remove; stage 1 does not touch it.

The turn's own allocation is 96 bytes a turn whatever n (the `(Bool, state)`
pair and the updated record or tuple), until the figure the ledger shows at
n = 1,000 and 10,000 rises to a few KB a turn: that is not the turn but the
final state copied into the caller's pool when the loop returns
(`kp_dup`, about three cells per session or entry), counted before the
report line is printed. Allocation inside the turn stays at 96 bytes.

## B. The real logbook

`tests/std/logbook_ws.py` drives `examples/logbook.fpr` as a browser does:
two tabs over the websocket, 25 entries posted, a search, paging, an edit, a
delete, then a kill, a replay from the journal and a restart. Three
processes, three ledgers:

| process | turns | state copies | bytes per state copy | receives | message copies | message bytes | allocated in all |
|---|---|---|---|---|---|---|---|
| the served session (two tabs, 26 commands) | 143 | 135 | 692 | 504 | 778 | 5.35 MB | 93.9 MB |
| `--replay` | 0 | 0 | | 4 | 14 | 3.7 KB | 2.4 MB |
| the restart, one tab | 10 | 5 | 269 | 28 | 49 | 0.8 MB | 27.9 MB |

The logbook's model is small by design (the entries live in the store, the
model holds the sessions), so the per-frame state copy is 692 bytes: at that
size the copy is noise next to the frame. What moves per frame is the
rendered page, as messages: 778 message copies, about 6.9 KB each on average
(a page of entries as statics and dynamics to the writer actor), 5.35 MB in
all. The whole-process allocation (93.9 MB, 1.57 million requests for 143
turns) is not a per-turn figure: it is dominated by start-up, the kvlog,
HTTP parsing and rendering outside the session loop's turns, and this probe
cannot split it by turn. Measuring the logbook with thousands of entries
means measuring the store shard, which is row A's `store` shape.

## C. The state against what a turn allocates

Programs that run turns, built with the probe and run as their suites run
them (`FPR_HEAP_MB=64` where the suite sets it, `FPR_HARTS=4` for
xpingpong). "state bytes" is what the turn copies out; "allocated" is what
the turn allocated (`fpr_alloc`, every actor), both per turn; "message bytes"
is the deep-copy traffic of `send` over the run.

| program | turns | receives | state bytes per turn | allocated per turn | allocated / state | message bytes | wall s |
|---|---|---|---|---|---|---|---|
| tests/base/receiveturns.fpr | 1,000,102 | 1,000,102 | 176 | 624 | 3.5 | 96.0 MB | 0.77 |
| tests/base/receivecoverage.fpr | 140,007 | 140,006 | 126 | 277 | 2.2 | 1.0 MB | 0.27 |
| tests/base/loopstate.fpr | 1,001,000 | 0 | 96 | 576 | 6.0 | 0 | 0.46 |
| tests/base/loopwith.fpr | 21,010 | 0 | 48 | 2,634 | 54.9 | 0 | 0.71 |
| tests/base/mvueventports.fpr | 683,431 | 261,312 | 550 | 392 | 0.7 | 26.1 MB | 0.70 |
| tests/base/autodrop2.fpr | 6,604 | 3,300 | 64 | 240 | 3.8 | 0.7 MB | 0.80 |
| tests/base/autodrop3.fpr | 201,003 | 200,000 | 96 | 169 | 1.8 | 4.9 MB | 0.33 |
| tests/base/deadmail.fpr | 1,204 | 3,600 | 1,164 | 248 | 0.2 | 63.5 MB | 0.60 |
| tests/msgpack.fpr | 10,666 | 10,667 | 140 | 4,170 | 29.8 | 26.1 MB | 0.27 |
| tests/fanin.fpr | 120,123 | 120,040 | 120 | 216 | 1.8 | 5.8 MB | 0.33 |
| tests/bench/pingpong.fpr | 2,000,002 | 2,000,000 | 96 | 168 | 1.8 | 48.0 MB | 1.08 |
| tests/bench/xpingpong.fpr, 4 harts | 2,000,002 | 2,000,000 | 96 | 168 | 1.8 | 48.0 MB | 1.28 |

What the table says:

- The state that crosses a turn is small everywhere: 48 to 176 bytes in ten
  of twelve programs (the next-turn closure and a few words), 550 bytes where
  the state carries a list (the event collector), 1,164 bytes where it carries
  a 1 KiB string (deadmail). Copy-out is cheap at these sizes.
- A turn allocates between 1.8 and 6 times what it keeps in most programs,
  30 to 55 times in the two that build scratch per turn (msgpack's payload
  verification, loopwith's frame work). That ratio is the regions bet: the
  garbage a boundary frees against the copy it costs. It holds in ten of
  twelve; mvueventports (0.7) and deadmail (0.2) keep more than they allocate
  because what they keep is what they received, which they copy to keep.
- Message copies outweigh state copies in every program that receives:
  pingpong copies 48 MB of messages for 192 MB of next-turn closures of 96
  bytes each, but deadmail copies 63 MB of messages for 1.4 MB of state. The
  per-message copy (`send`) and the per-turn copy are the two costs the model
  pays; stage 1 changes neither, it changes who frees the message.
- `tests/frames.fpr` was not measured: it needs a `--with` device file the
  harness does not know. QOS Main was not measured either (section D).

## D. QOS Main

Not measured by this probe. The attempt: `tools/guishell-check.py` in QOS
with `FPRISC_ROOT` at the baseline tree, `FPR_COST_PROBE=1` and
`FPR_COST_REPORT` set, which rebuilds `qosp-gl` and runs the Main profile
(six onboard sessions, two boots); the check passed (`HOLDS` on every leg),
but the ledger file holds only the sixteen tiny programs the Editor built and
ran through the compiler daemon (441 allocation requests, no turns each).
`qosp` has its own process entry and exit (`portable/host.c`: its own
SIGINT/SIGTERM handling, `exit` and `_exit`), so neither the exit report of
`machine/unix/host.c` nor the SIGTERM hook of `machine/unix/main.c` runs
there; and Main's turns run inside the kernel's `g_loop` through the memory
plane, so they are the kernel's ledger to print. Getting the number means a
report hook in QOS's host (a QOS change, not this repository's), after which
the same command gives Main's turns, state bytes and allocation at once. What exists instead is static: QOS's
`docs/2026-10-12-RECEIVE-TURN-COVERAGE.md` counts Main's receive-reaching
groups as 9 automatic, 40 under explicit regions and 6 skipped, and its Pi 4
soaks (`docs/2026-10-12-PI4-DEFAULT-TURN-MEMORY.md`) hold the Main shell flat
at 43 MiB over 100 s of use. The state-against-allocation ratio for Main is
an open row of this page.

## What this page fixes for the later stages

- Stage 1 acceptance is memory and root counts, not time; this page's turn
  costs (36 ns for an empty turn, 96 to 176 bytes of state in a receive loop)
  are what it must not move.
- Stage 3's acceptance ("large-model frame copy proportional to the change")
  has its baseline in row A: 160 bytes per session, 320 per entry, linear.
- Stage 2's threshold question (rule 3: how much larger `alloc` must be than
  the result) has its first data in column "allocated / state": 1.8 to 6 is
  the common case, so a boundary that costs more than a few hundred
  nanoseconds would not pay for itself on a small turn.
