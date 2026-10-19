# Two std-suite failures: a receive loop's entry cells, and named records the checker could not see

Date: 2026-10-19. Kind: repair record. Applies from this change, on top of
main `3e44148`. `python3 tests/check_std.py` stopped at two checks that fail
at that revision with the unchanged compiler; both predate the branches that
noticed them ([linear string builders](2026-10-18-LINEAR-STRING-BUILDERS.md)).

## 1. `poller`: 100,000 asks of an empty mailbox allocated 112 bytes

`tests/std/poller.fpr` measures `heapUsed` around `spin me 100000`, a loop of
`receiveNow` asks, and records 0 bytes. It printed 112.

**Cause.** Not `receiveNow`: a bare `receiveNow` on an empty mailbox still
allocates nothing (it answers a static `Err empty`). `spin` is a tail-recursive
receive loop, and since [receive turns](2026-10-12) (`compiler/ReceiveTurns.hs`,
`f79d8e4`, `ef84189`) such a loop is compiled as a trampoline: the entry stub
packs the live parameters into a tuple, partially applies the turn helper to
it, and hands that closure to the runtime's `$receiveLoop`, which runs every
turn under a fresh arena. The tuple and the closure are the only two cells
the stub allocates, in the caller's pool, before any arena exists; the
runtime never freed them. Measured with the activation count held and the
ask count varied:

| loop | bytes per activation | of which |
|---|---|---|
| one live parameter (`one me`) | 64 | the closure (40 + 16 preheader, rounded) |
| two or three live parameters | 112 | the closure + the packed tuple (24 + 16) |
| `spin me 0`, `spin me 1`, `spin me 100000` | 112 each | the same two cells; the asks add nothing |
| the same loop entered from inside another receive loop | 0 | the outer turn's arena reclaims them |

So every activation of a receive loop in an actor that is not itself inside
a turn leaked 112 bytes of that actor's pool until the actor died: each
`Clock.receiveWithin`, each `Poller` wait, each `Term` run.

**Fix.** The stub now tells the runtime how many live parameters it packed
(`$receiveLoop thunk k`), and `g_receive_loop` (runtime/runtime.c) frees the
closure, and the tuple when `k > 1`, after the loop returns: the first turn
unpacked them into locals and every later turn's state is a fresh copy in
transfer storage, so both are dead by then. A single live parameter is the
caller's own value and is not freed. The cells go back to the pool's
buckets.

**The test.** `heapUsed` is the actor's bump gauge: bytes ever taken from its
slabs, with bucket hits not re-counted. The first activation therefore still
shows the two cells once, fix or no fix. `poller.fpr` now warms the loop with
`spin me 1` before `h0`; the measured window then holds only what the asks
allocate, which is 0, and it would read 112 again if the runtime stopped
recycling the cells. The test says so in a comment. `std/clock.fpr`'s claim
that a timed wait allocates nothing is amended to say per ask, and what the
loop's entry costs.

## 2. `examples/swarm.fpr`: refused by the linearity checker

`fpr build examples/swarm.fpr` printed 24 refusals: record projections that
discard owned fields, projections from an owned record with an open row, and
owned variables used 2 to 14 times, in `freeCols`, the three `advance`
functions, `update` and `release`.

**Cause, in the example.** The example (`4c57c0f`, 2026-10-16) keeps its
`Vector Mote` and a `Cols` record of four `Vector Int` inside the MVU
`Model`, and reads scalars out of that model dozens of times a turn. The
[ownership corrections](2026-10-17-OWNERSHIP-CORRECTIONS.md) of the next day
made that a refusal on purpose: a record holding an owner is owned, a
projection moves it, and reading only metadata from it discards the owner.
`std/term`'s runner reads the model several times per turn (`update`, `subs`,
`view`), so a model that owns the swarm cannot be accepted without borrowing,
which [the design rules out](2026-10-17-VALUE-SEMANTICS.md): a service owns
the resource. The refusals were the checker being right.

**Cause, in the checker.** Only the functions without a signature were
refused. `stepCols : ... -> Cols -> Cols` projects `c.xs`, `c.ys`, `c.vxs`,
`c.vys` from the same owned record and was accepted, as was `advance : Model
-> Model`. `shapeOfTy` turned a type written by name (`Cols`, a `TShape`)
into an unrestricted constructor shape, so its vectors were invisible to the
checker, while the same record spelled out in the signature
(`{ xs : Vector Int, ... }`) or inferred for an unannotated function was
owned. A declared named record type was a hole. The receive-turn pass
already expands named shapes before deciding what may cross a turn
("nominal declarations are checked deeply"); the ownership checker now does
the same: `shapeOfTyIn` resolves a `TShape` name to its fields, recursively,
with a seen-set against a self-referential shape.

**What the closed hole changes elsewhere.** Every `tests/std/*.fpr`,
`tests/*.fpr`, `examples/*.fpr` and `examples/ideal/*.fpr` was compiled with
the checker before and after the change; 186 files, and no file's set of linearity refusals changed (the rewritten
swarm compiles under both; the old swarm gained refusals in `stepCols`,
`cellsOf` and `advance` under the new one, the three places that had been
passing through the hole). Named records with
owned fields are rare in this tree (`Cols` and `Model` here were the only
ones in std and the examples). QOS was not compiled with it; see "Not done".

**The example now.** The swarm lives in one *keeper* actor for the life of
the game, as `Swarm = Records (Vector Mote) | Columns (Vector Int) ...` (a
sum type, so each spelling destructures its owned fields by pattern), and
answers a `Step` request per tick with the bites and the picture through
`std/actor` call/reply; the model keeps the keeper's address and the
scalars. `stepCols` and `cellsOf` take and return the columns as a tuple.
The bench threads the same `Swarm` through the same `tick` by hand, with no
actor between the timings and the kernels. The three spellings, the
captured-record kernel and the fixed-kernel column tick are unchanged, so
the vec tiers the example exists to compare are the same sites.
`check_std`'s assertions are unchanged: the three modes run headless, print
their phases, and records and captured agree exactly.

## Checked

- `python3 tests/check_std.py`: exit 0, all 52 checks, end to end, on this
  Mac (arm64, the -O0 compiler at codegen revision 50).
- `tests/std/poller.fpr`: "100,000 asks of an empty mailbox allocated 0
  bytes" with the warm-up; a probe of back-to-back activations after the
  first (`spin me 1`, `spin me 1000`, three `spin me 5`) bumps 0 bytes, where
  the same probe bumped 112 per activation before.
- `examples/swarm.fpr --motes=2000 --bench=20`, the three modes, on this
  Mac: records 374 us per tick (step 96, bites 8, picture 164), captured
  1137 (808, 128, 232), columns 186 (13, 8, 126); records and captured
  leave health 256, columns 254, as before (columns floor where the
  others truncate).
- `tests/check_receive_turns.py`: all legs pass (million-message stress on
  one and four harts, imported helpers, arity spill, cancellation, the five
  "reported unchanged" refusals).
- `tests/check_structural_ownership.py` and `tests/check_generic_ownership.py`:
  29 structural/control-flow cases and 42 generic cases pass, native and
  Sol, with the closed hole.
- The codegen revision is 50: the stub's call to `$receiveLoop` gained an
  argument, so cached prelude and unit objects from revision 49 must not
  link against the new runtime (they did, once, and failed to link).

## Not done

- QOS (`programs/*.fpr`, `apps/`, `tests/*.fpr`) was not check-compiled
  with the closed hole. A named record with an owned field passed through a
  declared signature there will now be refused where it was accepted;
  [the polymorphism page](2026-10-17-OWNERSHIP-POLYMORPHISM.md) found two
  such places last time (both in `editapp.fpr`, since fixed on the QOS side
  by keeping the owner out of the model).
- The entry cells are still bumped once per activation; only their recycling
  is new. Avoiding them would mean the runtime building the first turn's
  closure inside the first arena, which needs a protocol with the stub that
  passes the live parameters unboxed.
- The keeper's pool grows by a tick's answer per tick for the life of a
  game, as the old model's actor did; `Sys.loopWith` cannot take it (several
  vectors, fresh ones every tick).
