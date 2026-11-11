# Static reuse: plan and first findings

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
