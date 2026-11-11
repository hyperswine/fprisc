# Static reuse: plan, findings and the first increments

Date: 11 November 2026. Kind: plan with measurements. Decision 5 of
[the copy-out decisions](2026-11-11-COPY-OUT-DECISIONS.md): static reuse is the
next memory work. Copy-out now bounds memory; reuse is the speed item, because
a step that reuses its cells allocates nothing.

## Finding: spine reuse does not fire on the app workloads

Allocation requests (`FPR_COST_PROBE`), sim with 20,000 particles and 2,000 steps:

| Variant | Reuse on | `FPR_NO_REUSE=1` |
|---|---|---|
| sim as written (`List.map move ps`, `gen` exits through `List.reverse`) | 160,082,012 | 160,082,012 |
| the same, copy-out off | 160,044,013 | 160,082,012 |
| initial list from `List.map mk (List.range ...)` (a fresh spine), copy-out off | 160,064,015 | 160,102,014 |
| `bounce` without tuples, a hand-written recursive `stepAll` | 80,082,012 | 80,082,012 |

`tests/check_consuming_reuse.py`'s `fixed_state` (`plain n xs = plain (n - 1) (L.map (fn x -> x + 1) xs)`)
does reuse: 2,052 requests for 64 steps. So the 57201f0 spine reuse works on
its fixture and on none of these shapes. Before any new mechanism, find out why.

Narrowed with three probes of the `fixed_state` loop, 2,048 elements and 64 steps:

| Probe | Requests |
|---|---|
| `L.map (fn x -> x + 1)`, as in the fixture | 2,048 (the initial list only) |
| the same with a typed signature and a `measure` annotation | 2,048 |
| `L.map (fn p -> {a = p.a + 1, b = p.b})` over records | 266,245 (no reuse at all) |

So `measure` is not the cause. **An element computation that builds a record
defeats the spine reuse entirely**, not just the element. sim's `move` and csv's
tuples are both this case. The likely mechanism is that the record constructor reaches
the cursor plan's `allowed` test as a call `Reuse` cannot see (an erased
constructor stub, or a product worker), and `resets` treats it as a possible
reset. Confirming that is the first task.

The candidates:
- the element computation calls a function (`move`, `bounce`'s product
  workers) that `poolResetters` treats as a possible reset;
- `measure`-annotated loops normalise differently;
- a hand-written recursive map is a TRMC cursor worker rather than the
  `std/list` map the planner knows.

## Increment 1 (written, not merged): fresh results

`spineBuildersWith` publishes a function every exit of which returns a fresh
spine whatever its arguments, with seed slot -1. The fresh exits are:
- Nil;
- a cons onto a fresh spine;
- a builder with a fresh seed;
- another fresh-returning function (a greatest fixed point);
- a call or loop region's leave around one.

`List.reverse` qualifies, and so does a builder like sim's `gen` that exits through it.
It builds, and has no measurable effect until the finding above is resolved, so it is
held back from main. The patch is on branch `static-reuse` as its first commit.

## Increments, in order

1. **Diagnose the finding above.** Make sim's `run` and csv's per-line pipeline take
   the existing spine reuse, measured by allocation requests.
2. **Fresh results** (above): `gen`-style builders and `List.reverse` count as fresh.
3. **Re-enter the consuming twin after a cycle.** The cold path `$loop.cycle.f`
   calls the borrowing `$loop.in.f` (`ReceiveTurns.hs` pureMake), so reuse stops at
   the first copy-out cycle. The copy is fresh, so the twin may continue.
4. **Element reuse.** In a consuming map over a unique spine, an element is unique
   only if every builder of the spine stored a fresh element. Extend the builder
   summaries with an element-freshness bit (a fresh constructor, or the result of a
   consuming worker). Then a known `f` whose consuming worker exists, such as
   `move`, which rebuilds the same record, writes into the old element. A shared
   element (`[a, a]`) must never qualify; this is the memory-safety line.
5. **Consuming `Map` updates.** `Map.insert`, `update` and `insertWith` on a map whose last
   reference is given up, for example a fold accumulator, rebalance in place. This needs
   per-path ownership: a path node shared with an old version is copied. The MutMap
   measurements are the target (wordfreq 4.1 s to 0.48 s).

## Gates

- `check_consuming_reuse` and `check_reuse` keep their ledgers.
- The app suite's allocation requests drop on sim (target: one allocation per step for the
  element until increment 4, then none) and on csv and wordfreq after increment 5.
- `run.py --ceilings` passes, and outputs stay byte-identical.

## Status, later on 11 November (branch static-reuse)

Increments 1 to 3 are done. The cause was not record construction itself;
there were five blockers.

1. **The initial list was not fresh.** A spine from `List.map` or a `gen`-style
   builder is not a "builder" in the old sense. Fresh results (increment 2) plus
   one more exit shape fix it: a TRMC builder's first step, which makes a fresh cell the
   cursor worker's root and cursor. The fixture's `L.range` was always fresh, which is why it worked.
2. **The size guards.** The fresh-result walk and the loop plan used the 256-node bound of the
   other plans. A TRMC map with its element inlined, or a region's inner loop, is past
   it. They now take 4096 and 2048; both walks are linear.
3. **Copy-out regions on TRMC map entries.** A map entry frees nothing, but automatic copy-out
   wrapped it, hiding it from the start plan. `ReceiveTurns` now declines copy-out for a loop that calls a
   TRMC worker. Bounded state still gets its ordinary region.
4. **The cycle re-entered the borrowing loop** (increment 3). The consuming inner loop's cold
   edge now calls a cycle twin that re-enters it.
5. **A memory-safety hazard, now closed.** A consuming twin writes a new record (in the arena)
   into a reused cell that may lie outside the region, or in the retained state
   slab. Copy-out's outside rule (a9006074) and retained generations do not
   descend such cells, so the record was lost at the reset.
   - The fix: every cycle a twin reaches carries `REGION_MUT_BIT` on the
     sequence number, and the runtime marks the region mutating. A mutating region's copy-out descends everything.
   - The test: `persistent_aliases records` returned 291296522 instead of 379990000 without the fix, and passes with it.
   - On main (`33c77f5a`) the hazard is latent. Copy-out plus spine reuse does not compose there,
     because of blockers 2 and 3, so the same program is correct.

Allocation requests, instructions retired and peak RSS, with reuse against `FPR_NO_REUSE=1` (copy-out on in both):

| Workload | Reuse on | Reuse off |
|---|---|---|
| sim | 120.1M, 21.4 G, 81 MB | 160.1M, 33.1 G, 97 MB |
| csv | 33.2M, 23.3 G | 34.2M, 23.5 G |
| wordfreq | 35.0M, 28.7 G | 37.0M, 29.2 G |
| records, treemap | unchanged | |
| format | 20.1M, 6.4-6.9 G | 20.1M, 6.3 G |

- **format** varies with reuse on (+5% on average, no allocation change), from std-unit code. Open.
- **The record loop** in `persistent_aliases`: 120.0M to 60.1M requests, 17.5 to 9.1 G instructions.

`check_base` passes, apart from the four checks red at 57201f0. Also passing: check_consuming_reuse,
check_reuse, check_persistent_reclamation (records added), check_state_generations, check_digest_vectors and
check_compiler_options. The app ceilings pass, and sim's ceiling drops to 125 MB.

What remains:
- **Increment 4: element reuse.** It is now the whole of sim's gap: three allocations
  a step (the record, and `bounce`'s two tuples, which unboxed pair returns would remove).
- **Increment 5: consuming `Map` updates.**
- **format's variance.**

## Increment 4: element reuse (later on 11 November)

sim now makes 80.1M allocation requests, its two `bounce` tuples per
particle-step, against 160.1M with `FPR_NO_REUSE=1`. Instructions: 13.7 G against
33.1 G (-59%). Peak RSS is 129 MB, against 81 MB with spine reuse only, because copies are rarer once only tuple
garbage is left, so the arena grows further between them. The sim ceiling is raised to 195 MB for that reason.
`mainbug` (a builder of records into a map loop) makes 40,020 requests in all,
the initial list only, against 120M. Its instructions are 3.6 G against 17.5 G.

### How it stays sound

- **Two twin families.** `$worker.spine.*` reuses cells. `$worker.spineE.*`
  reuses cells and elements. A call site picks spineE only when the list is spine-fresh and
  element-fresh: every element is stored in that spine only.
- **Element freshness** is a parameter-dependent summary (a greatest fixed point). Each function
  gets the set of argument slots whose spines must have fresh elements for its result's to be. The leaves are:
  - Nil, and the tail of a parameter's cell;
  - a cons whose element is a fresh constructor (seen through `let r = ... in r` and ticks), or an element moved once out of a parameter's cell;
  - calls through summaries;
  - region leaves, and a region cycle's packed state (a copy is fresh, a deferral is the same state);
  - a TRMC builder's first step, when its worker only stores fresh constructors;
  - std's `revOnto` and `reverse`, vouched for by the linked builder table.
- **Spine freshness** uses the same walk with elements ignored. This is what admits a
  seeded builder behind a copy-out region wrapper.
- **An element never reaches the spine behind it.** A cell whose element mentions any variable its tail depends on (through
  `let`s and parameters) refuses, as with `seed :: seed`. `ReuseCheck` caught that hole in the first version.
- **The spineE cell step.** The element computation's value-producing constructor is rewritten
  to bind its fields, test the old element's (tag, variant), and then build over it, or
  allocate when the layout differs.
  - The test reads the header. Some read of a field of the old element proves it is a constructor.
  - Every other binding in the step may read the old element only by projection or layout test.
  - The element may be the old one moved, a fresh constructor, or the rewrite. Anything else refuses the
    plan, so spineE's outputs stay element-fresh.

### Tests

`persistent_aliases` (in `check_persistent_reclamation`, with reuse on) gains three cases:
- `elements`: element reuse with copy-out cycling. The answer is checked, and requests must be under 70M (they were 120M without element reuse).
- `shared`: one record stored twice. Requests stay above 150,000 (no element reuse), and the answer is checked.
- `kept`: a record still used after the loop is unchanged.

`check_reuse` (with `ReuseCheck`), `check_consuming_reuse`, `check_state_generations`,
`check_digest_vectors` and `check_compiler_options` pass. The app ceilings pass.

### Still open

- **h-style initial lists.** A `List.map` over `List.range` in `main` gets a copy-out region whose inner loop is not
  yet summarised, so element reuse starts one iteration later. Spine reuse still applies.
- **The tuples.** Unboxed pair returns would remove sim's two remaining allocations.
- **Increment 5:** consuming `Map` updates.

## Increment 5: owned maps (later on 11 November)

A std/map threaded through a loop from an empty map is unique all the way down.
Path copying shares unchanged subtrees only with the previous version, which
the loop gave up. Its tree walker then rebuilds, in place, each node it took
apart and rebuilds with the same layout. That covers the common case, an update
of an existing key, where every path node is rebuilt unchanged in shape. Inserts that
rebalance still allocate through `balance`.

| Workload | Requests, reuse on | Reuse off | Instructions | Peak RSS |
|---|---|---|---|---|
| wordfreq | 11.1M | 37.0M | 23.7 against 28.8 G | 435 against 513 MB |
| csv | 24.0M | 34.2M | 21.9 against 23.4 G | 233 MB, both |
| `persistent_aliases mapcount` | 1.41M | 3.40M | | |

### How it stays sound

- **Deep walkers.** A walker recurses on a tree parameter t, after a Leaf test on t. Each tail result of
  its node branch is a tuple `(node, d)`. A tail node of t's layout, built from fields
  that only read t, becomes `$reuse.fresh t`. A self call on a child of t becomes the
  twin. t may otherwise only be projected, tested, or returned unchanged as a tuple's
  first field.
- **Tiers.** There are three:
  - map operations: non-recursive, like a specialised `alter`, whose one consumer of the map is a walker;
  - map loops: recursive, or a region's inner loop, whose consumer is a walker or an operation;
  - entries: wrappers handing the map to a loop or region wrapper.

  The map is used only by projection or layout test, or handed on whole (a tail value,
  the recursive slot, the cold edge), never captured or stored. It is consumed at most once on any path.
- **The empty map's wrapper and its `Leaf` are shared statics and are never written.**
  A call site enters a twin only with one of std/map's empty maps (`strings`, `ints`, `empty`).
  They are matched by name and tied to the std/map unit whose `Leaf` the walkers
  test. Sharing that empty map elsewhere is harmless.
- **Regions.** Cycles from a twin carry `REGION_MUT_BIT` and now also the written
  component of the packed state (`REGION_MUT_SHIFT`, read off the cycle's own
  packing). The runtime copies that component whole and keeps the outside
  rule for the rest; no other component can reach the unique structure's
  cells. Copying the whole state took csv to 740 MB, because the walk counted all of its remaining
  input; with the component it is 233 MB again.

### Tests

`persistent_aliases` gains three cases (reuse on):
- `mapcount`: an owned map with per-step scratch, so copy-out cycles while nodes are written. The answer is checked, and requests must be under 2M.
- `maphistory`: every old version is kept, so the loop must not own its map. The sizes of all versions are checked.
- `mapshared`: the empty map it started from is still empty.

### Still open

- **The loop without a region.** Field workers unbox the map into (comparator, size, tree) first, a
  shape the plans do not take. Copy-out is on by default, so the default build is covered.
- **Inserts that rebalance.** A consuming `balance` would let rotations rebuild nodes in place too. This is
  treemap's case (393k distinct keys out of 500k inserts); it gains nothing yet.
- **Maps not built from empty in the loop** (a map passed in from elsewhere) stay persistent, by design.

## Increment 6: consuming balance, std/map's own walker, and a soundness fix (12 November)

### A soundness hole in increment 5 (fixed here)

Increment 5's use check counted consumers per path, but it did not stop a loop from
returning the map it had already consumed. For example:

    staleGo xs m = case xs of
        Nil -> m
      | x :: rest -> m2 = M.insert (x % 50) x m; staleGo rest (if x % 7 == 0 then m else m2).

Once the insert has run in place, `m` is no longer the old map: it carries the
insert that the program discarded. The merged `4740d788` takes this plan. No app
workload has this shape, but the plan is wrong.

The check is now path-sensitive:

- **After the consumer.** Once x is consumed on a path, x may not appear on that path again. There is one exception: x may be the value of a branch on the walker's own "nothing changed" result (`d == 2`), and only for walkers that keep that contract. A walker keeps it when every tail `(t', 2)` hands back t itself or the static `Leaf`, and every rebuilding tail's second field is a constant other than 2, or a code an enclosing branch has shown is not 2. By induction, `d == 2` then means nothing was rebuilt anywhere along the path, which is std's `alter`.
- **Tail tuples.** x may be moved whole into a tail tuple only on a path that never consumed it.
- **Hand-on bindings.** A binding whose one use hands its value on whole (the loop's map slot, or the result) counts as a tail for x. Without this, csv's fold loop lost its plan.

### Consuming balance

The walker twin inlines std/map's `balance` and `node` into its tail tuple. The bodies come from the linked program: `Compile.hs` passes them as `tgtMapBodies` and `Pipeline` as `optMapBodies`. Each inlined site gets binders of its own.

- **No rotation.** The node rebuild over t becomes `$reuse.fresh t`. Overwrite now also descends the branches of an `if` whose test only reads t.
- **Rotation.** Rotations still call `rotRight`/`rotLeft` and allocate.
- **Acceptance.** A twin is accepted only if it rebuilds over t somewhere.

### std/map's own walker

When insert is inlined into a loop, the consumer is std/map's `insGo`, which lives in the map unit. Walkers were taken only from the unit's own functions, so treemap got no plan. Now:

- **The body.** `insGo`'s linked body is plumbed with `balance` and `node`. Its variable aliases are substituted away (`dropAliases`), and it is admitted as a walker.
- **Std/map is recognised by its bodies.** That means `insGo` and `balance` in the map bodies, and its `Leaf` in the unit. A unit that inlined insert names no `Leaf` of its own, so the old test found nothing, and the empty map at the entry was not vouched for either.
- **The twin.** The twin is a private copy in the using unit, named `$worker.mapown.walk.insGo@H.<tag>`. The tag is FNV-1a over the unit's own names, so two units' copies never share a symbol.

### Measured (M4, requests from `FPR_COST_REPORT`)

| Workload | Before (increment 5) | Now | Instructions | Peak RSS |
|---|---|---|---|---|
| treemap | 11.0M | 1.94M | 6.96 -> 5.32 G | 614 -> 134 MB |
| wordfreq | 11.1M | 10.4M | 23.7 -> 23.6 G | 435 -> 417 MB |
| csv | 24.0M | 24.0M | 21.9 G | 233 MB |
| `persistent_aliases inserts` | 3.95M (reuse off) | 0.66M | | |

All outputs match. `stale` and `staleout` give the no-reuse answers.

### Tests

`persistent_aliases` gains three cases, all with reuse on:

- **`stale`.** The hole above. The answer is the check.
- **`inserts`.** Insert inlined, with a tuple exit holding the map. Requests must stay under 1M.
- **`staleout`.** It returns, in a tuple, the version it consumed. It must be refused, and the answer is the check.

### Still open

- **Rotations** still allocate. A consuming `rotLeft`/`rotRight` would reuse t and its child.
- **Other std/map walkers** are not plumbed: only `insGo` is. `remGo` and alter's walker would follow the same path when a workload inlines them.
