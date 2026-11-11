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
