# Cost-sized regions: one memory model for Base

Date: 2026-10-23. Kind: proposal. Nothing here is implemented. It extends
Proposal A of [2026-10-12-MEMORY-I32-REFINEMENTS.md](2026-10-12-MEMORY-I32-REFINEMENTS.md)
(region per turn, implemented) and replaces its Proposal B (precise ARC in
Base) as the long-term direction. It builds on the cost pass of
[2026-10-02-RESOURCE-BOUNDS.md](2026-10-02-RESOURCE-BOUNDS.md) and
[2026-10-02-BOUNDS-IN-SIGNATURES.md](2026-10-02-BOUNDS-IN-SIGNATURES.md).

## The rule

Every allocation goes into a region. A region has a capacity of the same type
as a mailbox:

```
Cap = Type (Static n | Dynamic n).        # std/actor.fpr, today, for mailboxes
```

`Static n` is one block reserved up front that never grows. `Dynamic n`
starts at `n`, grows, and shrinks according to a policy. A value leaves a
region in exactly one way: it is copied into an enclosing region, or, if it
is linear, moved. Value semantics makes the copy unobservable, so **where a
region boundary goes is a performance decision, never a soundness one.** The
compiler places boundaries using the cost pass; the cost pass sizes them.

No garbage collector traces the heap, no value carries a reference count, and
nothing is borrowed.

## What already exists

The pieces are in the tree; they are not yet one model.

- **Per-actor pools.** "In the Base profile an actor allocates into its own
  pool, and nothing in the pool is freed individually"
  (2026-10-12-MEMORY-I32-REFINEMENTS). Memory returns when the actor dies or
  a pool resets (`Sys.poolReset`, `Sys.arena`, `Sys.loop`/`loopWith`).
- **Turn regions.** `compiler/ReceiveTurns.hs` turns a recognised receive loop
  into a trampoline whose every turn runs under a fresh arena; the next state
  is copied into a transfer slab. Keeping the arena across turns took a small
  turn from 214 to 123 ns on one hart
  ([2026-10-19-RECEIVE-TURN-ARENA.md](2026-10-19-RECEIVE-TURN-ARENA.md)).
- **MVU frames.** `std/mvu.fpr`: "All drivers reclaim every frame's scratch
  allocations." The model has value semantics; a `Vector` in frame state is
  refused by `Sys.loop`; stable mutable buffers belong to an explicit owner
  under `Sys.loopWith`.
- **Mailbox capacities.** `AC.spawnWith (AC.Static 16)` and
  `AC.spawnWith (AC.Dynamic 64)`: rings that never grow, or that double.
- **The cost pass.** Signatures may declare `work`, `alloc` and `live` bounds,
  and the compiler answers PROVEN, OVER or UNPROVED. `live` is today the
  conservative `alloc` plus frames: "under the pool model everything allocated
  stays until a boundary" (`compiler/Cost.hs`). Stage 4 of RESOURCE-BOUNDS
  tightens it.
- **In-place reuse.** `compiler/Reuse.hs` overwrites a freshly built
  constructor nothing else holds (halved allocations, about 40% faster on
  Pi 4 and STAR64, [2026-10-20-REUSE-AND-PIPELINE-ROADMAP.md](2026-10-20-REUSE-AND-PIPELINE-ROADMAP.md)).
- **Refcounting at the edges.** Message roots and `sendArc` shares go through
  the global ARC table; `send` deep-copies, `sendLinear` moves
  ([2026-08-25-MEMORY.md](2026-08-25-MEMORY.md)).

## Why change anything

The model works where a boundary exists and fails silently where one does not.

- **The recurring leak is the same leak.** Each was a received value or a
  turn's garbage with no boundary to release it: unnamed receive roots
  (`tests/base/autodrop2.fpr` measured 386 MB for 3,000, 2026-08-25-MEMORY);
  a bare `case receive` body that dropped nothing (pingpong ended with
  1,000,000 live entries and 101.5 MB, 3.75 MB after the fix,
  [2026-10-19-AUTODROP-BARE-CASE.md](2026-10-19-AUTODROP-BARE-CASE.md)); the
  Pi MVU driver holding 31.9 MB against about 25 KB live
  (2026-10-12-MEMORY-I32-REFINEMENTS).
- **Unrecognised loops still grow.** Swarm's keeper: "The keeper's pool grows
  by a tick's answer per tick for the life of a game"
  ([2026-10-19-STD-SUITE-REPAIRS.md](2026-10-19-STD-SUITE-REPAIRS.md)). QOS
  keeps an inventory of skipped receive-loop groups
  (qos `docs/2026-10-12-RECEIVE-TURN-COVERAGE.md`).
- **Programmers write the boundaries by hand.** `keep` in
  `examples/service.fpr` (the store must own its keys because `serve` drops
  each request), `answer = keep m; _ = drop m` in `std/task.fpr`.
- **A pure loop has no boundary at all.** The RV32 Tang Nano classifier ran
  out of its 8 MiB heap in the first of ten iterations, which is why the
  conservative collector `FPR_GC=1` exists
  ([2026-10-20-TANGNANO20K-GC.md](2026-10-20-TANGNANO20K-GC.md)).
- **Sizes are not known up front.** Mailboxes have `Static n`; the memory an
  actor needs has no counterpart, so admission and WCET stop at the heap.

## The model

### Regions an actor owns

| Region | Holds | Reset |
|---|---|---|
| mailbox | received messages not yet taken | a message dies with the turn that took it |
| turn | everything a turn allocates | at the end of every turn |
| state | what the actor carries from turn to turn | by its policy (below) |

Calls may open further regions inside a turn. Regions nest and close in LIFO
order, as stack frames do.

### Where boundaries go

1. **A receive turn or an MVU frame**, as today, for every loop shape the
   runtime can see, not only those `ReceiveTurns.hs` recognises.
2. **A self tail call** whose arguments are small: the arguments are the
   state, everything else is scratch.
3. **A call whose `alloc` is much larger than the size of its result.**
   `argmaxL (subL (addL a b) c)` builds two lists and returns an `Int`: one
   region, one word copied out. This is escape analysis giving stack
   allocation.
4. **Never where the result is about as large as the allocation.**
   `zerosL k` allocates exactly its result; a region per level would copy the
   list once per level, quadratically. Its cells go to the caller's region.

When the compiler can tell from the result type which values escape, it
allocates those directly in the enclosing region and only scratch in the
inner one. This is Tofte and Talpin's storage choice used as an optimisation:
a wrong guess costs a copy, never a dangling pointer.

### Sizing

- **`Static n`** when the cost pass proves `live <= n` for the region. The
  region is one block reserved at spawn: a bump pointer, no growth check, no
  free. Admission at spawn says yes or no before the actor runs. The bound may
  depend on spawn arguments: if `alloc tick <= c*n + d`, the swarm keeper for
  `n` motes gets `Static (c*n + d)`.
- **`Dynamic n policy`** otherwise. It starts at `n` and doubles when full,
  like a `Dynamic` mailbox ring. The policy says when it shrinks and, for a
  state region, when it compacts:

  | policy | meaning |
  |---|---|
  | `Shrink Never` | keep the high-water mark |
  | `Shrink ToMark` | give back down to the last turn's mark at the boundary |
  | `Compact AtDouble` | state region: copy the state to a fresh region when it reaches twice its last live size |
  | `Limit m` | a bound the programmer chose; reaching it is a named refusal |

  There is no default `Limit` (docs/2026-09-19-BOUNDS.md: limits come from
  fundamentals or from the programmer). Growth is counted and reported, so an
  unbounded region is visible rather than silent.
- **A strict build** may require every boundary to be `Static`; an allocation
  the cost pass cannot bound is then a compile error.

### Copy-out, generationally

A turn's survivors are copied into the state region. The copy follows
pointers only while they lie inside the turn region and stops at pointers
already in the state region (an address-range compare). `Map.insert` shares
all but about log n nodes with the old map, so a `Put` copies those nodes,
not the store.

Nodes the state no longer reaches stay in the state region until its policy
compacts it: the state is copied to a fresh region and the old one released.
That compaction is a copying collection with exactly one root, the state. It
scans no stack, guesses no pointers, runs only when the policy says, and its
pause is proportional to the state's size, which `size` bounds can bound. The
proposal does not pretend otherwise. Uniquely owned state updated in place by
`Reuse.hs` produces no such garbage in the first place.

Linear values (`Vector`, connections, tokens) are moved, not copied: a
`Vector` handle crossing a boundary costs a word.

### Messages and sharing

- `send` copies into the receiver's mailbox region, as today.
- A received message is the turn's input and dies when the turn ends. Keeping
  part of it means returning it in the next state, which copies it. There is
  no `drop` to insert and no `keep` to write.
- `sendArc` freezes a region and counts references to the region, not to the
  values in it. One count per shared region replaces the per-value ARC table;
  the last release frees the whole region.

## Worked examples

### The ponger (`tests/bench/pingpong.fpr`)

```
ponger self = case receive self of (who, n) -> send who (n + 1) >> ponger self.
```

A turn allocates the reply and the next-turn closure; the state is `self`.
The cost pass can prove a constant `live`, so the turn region is `Static k`
and resets by moving one pointer. The message dies with the turn. With a
`Static 64` mailbox and a bound on message size, the whole actor is sized
before it runs.

### A loop that receives but is not a receive loop

```
ping me p k acc = if k == 0 then acc else
  _ = send p (me, k);
  r = receiveFrom me p;
  ping me p (k - 1) (acc + r).
```

The self tail call is the boundary (rule 2). Four `Int`s are copied out; the
`(me, k)` tuple dies every iteration. The `receiveFrom` in the middle does not
matter.

### `serve` and the store (`core/prelude.fpr`, `examples/service.fpr`)

```
serve self h st =
  m = receive self; (rt, q) = m;
  (st2, r) = h st q;
  _ = send rt r; _ = drop m;
  serve self h st2.

store state q = case q of
  ... | Put k v -> (Map.insert (keep k) (keep v) state, Stored) ...
```

`drop m` and both `keep`s go away: `st2` is copied out of the turn, which
takes `k` and `v` out of the dying request. Each `Put` copies the inserted
path, about log n nodes. The state region is `Dynamic` with
`Compact AtDouble`.

### `ask` inside a handler (`route` in `examples/service.fpr`)

```
route storeActor workers listener req =
  ... (case ask me storeActor (Get key) of Found v -> Http.text 200 v ...
```

A receive deep in a call with `req` and `key` live on the stack. Each
connection is its own actor and ends after its request, so one `Dynamic`
region freed at death is enough, as today. The hard case is narrower: a
long-lived actor that receives inside a loop the compiler cannot see as a
boundary. Rule 2 covers most; what remains grows visibly as `Dynamic` until
the enclosing turn ends.

### Swarm's keeper (`examples/swarm.fpr`)

```
keeper self mode s =
  m = receive self; (from, id, q) = m; _ = drop m;
  case q of ...
  | Step px py pulse w fieldH ->
      (a, s2) = tick mode px py pulse w fieldH s;
      _ = AC.reply (from, id) a;
      keeper self mode s2.
```

The tail call is the boundary, so `tick`'s scratch goes every tick: the
growth STD-SUITE-REPAIRS records is gone. `s2` holds linear vectors, moved,
not copied. With a proven `alloc tick` the turn region is `Static` and sized
from the spawn arguments.

### The classifier (`tests/dtree.fpr`)

Training builds many short-lived count lists (`zerosL`, `bumpL`, histogram
rows) and returns a `Tree` of about 55 nodes. `train` is rule 3's clearest
case: each iteration runs in its own region and copies out the tree. Ten
iterations on the 8 MiB board need no collector, no root scanning and no
register saving.

### Plain functions

A function the cost pass does not pick allocates into its caller's region.
Inside one region `live` equals `alloc`:

```
total = sumL (map score (filter keep rows))
```

Three things keep that small: a boundary around the expression (the result
is an `Int`), the existing map/filter/fold fusion, and in-place reuse of
values nothing else holds.

## Where it lands

| Layer | Profile | Regions |
|---|---|---|
| drivers on the QOS HAL | Builtin (`--raw`, `--arc`) | `Static` everything, or no allocator; unchanged by this proposal |
| applications | Base, `std/mvu` | a frame region per event, a `Dynamic` model state region |
| concurrent work | `std/task`, `Cmd` | one region per worker, freed at its death |
| subscriptions | `std/mvu` `Sub` | mailbox regions, sizes derivable from `subs model` |
| services | Base actors | `Dynamic` state regions with explicit policies |

The Builtin profile keeps its own ARC and raw modes; a driver and an
application meet only through copied HAL messages.

## What goes away, what stays

Goes away: compiler-inserted `drop` (`autoDrop`), `keep` in application and
library code, the gap between recognised and unrecognised receive loops, the
per-value ARC table, and the need for `FPR_GC` on the Tang Nano.

Stays: per-actor isolation, deep copy on `send`, `sendLinear`, linear
resources, explicit regions (`Sys.arena`, `Sys.loopWith`) as overrides, the
Builtin profile's ARC, and in-place reuse.

New cost: copy-out of new state each boundary, and state-region compaction.

## Alternatives considered

| | For | Against |
|---|---|---|
| Precise ARC everywhere (Perceus, Swift; Proposal B) | frees at last use; reuse in place; no pauses | count traffic on most copies and drops; code size; atomic counts for cross-hart sharing; no up-front size; Proposal B as written needs borrowed parameters, which FP-RISC rules out |
| Region inference (Tofte and Talpin, ML Kit) | no copying; static lifetimes | inference must be sound, so complex; known to leak in loops without region-polymorphic recursion |
| Epoch-based reclamation | cheap for concurrent shared structures | a technique for shared data, not an allocator; turns already are epochs |
| Tracing GC | general | pauses, root scanning, no up-front sizes; the conservative RV32 collector needed register and stack roots and is mutually exclusive with ARC |

Cost-sized regions keep what region inference is good at (bulk freeing, no
per-value work) and drop what makes it hard (soundness), because copy-out is
always correct.

## Open problems

- **Large state.** Generational copy-out is the answer on paper; its cost on
  a large-model MVU app (logbook with thousands of entries) and the swarm is
  unmeasured.
- **Receives with live stack frames** in long-lived actors that are not loops
  over a tail call. Either the compiler restructures them into turns, or they
  stay `Dynamic` until the enclosing boundary.
- **`Static n` is only as common as `live` is precise.** Until Stage 4 of
  RESOURCE-BOUNDS, most regions will be `Dynamic`.
- **Rule 3's threshold** (how much larger `alloc` must be than the result) is
  a tuning question to settle by measurement.
- **Frozen shared regions** need a freeze that does not copy what is already
  in a region of its own.
- **Region bookkeeping per call** must stay cheaper than the garbage it
  avoids; small functions should never get regions.

## Staged plan

Each stage lands on its own with its acceptance check in `tests/check_base.py`
or the QOS sweep.

| Stage | Work | Acceptance |
|---|---|---|
| 0 | Measure: per-frame model copy cost against model size (logbook), state size against turn allocation across check_base and QOS Main | numbers recorded in a dated page |
| 1 | A message dies with its turn; `autoDrop` retired | autodrop2/3, deadmail and receive-turn checks green with `arc_live = 0`; `keep` removed from `examples/service.fpr` and `std/task.fpr` with identical output |
| 2 | Boundaries at self tail calls and cost-chosen calls, each reported under `--cost` | `tests/dtree.fpr` 512 rows x 10 under 8 MiB on RV32 QEMU without `FPR_GC`; swarm keeper resident memory flat over 10,000 ticks |
| 3 | Generational copy-out and `Dynamic` policies | service `Put` time flat as the store grows from 1,000 to 100,000 keys; large-model frame copy proportional to the change, not the model |
| 4 | `Static n` from proven `live`; spawn-time admission (needs RESOURCE-BOUNDS Stage 4) | the ponger proven `Static`; a strict build refuses an unbounded boundary by name |
| 5 | Frozen shared regions replace the per-value ARC table | `sendArc` checks green; 4-hart benchmarks no slower than [2026-10-18-ARC-TABLE-CHURN.md](2026-10-18-ARC-TABLE-CHURN.md) |

## Rules this keeps

- **No borrowing.** Owned values hand themselves back, services own
  resources; regions add no lifetimes to types
  ([2026-10-17-VALUE-SEMANTICS.md](2026-10-17-VALUE-SEMANTICS.md)).
- **No arbitrary bounds.** Capacities come from proofs, fundamentals or the
  programmer; a reached limit is a named refusal, never a truncation.
- **Never silent.** A region that grows is counted and reported.
