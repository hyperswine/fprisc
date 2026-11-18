# Record vectors, record sorts, and what sim's gap is made of (18 November)

Items 2, 3 and 4 of the 18 November round (docs/2026-11-18-OWNED-MAP-FOLDS.md
lists them): flat record vectors and untagged Int fields for `sim`, and the
comparator cost in `records`. Apple M4, standard inputs, best of five.

## What sim's gap is made of

sim (20,000 particles, 2,000 steps, a `List` of records rebuilt by
`List.map move`) already allocates nothing per step: the map writes every
record and cell in place (40,000 cells in the whole run). Its loop runs at
about 10 cycles a particle against C's 3, and the ratio is the same with 500
particles (all in L1), so it is not memory latency. With no hardware counters
on this machine (no Xcode), C written with FP-RISC's layout measured the
parts:

| version (40M particle updates) | time | share of the gap |
|---|---|---|
| C, array of structs | 0.030 s | |
| C, list of cells pointing to records | 0.053 s | 35%: the layout |
| + tagged Ints and 63-bit overflow checks | 0.068 s | 23% |
| + rewriting each cell in place (head, Nil, previous tail) | 0.073 s | 8% |
| FP-RISC | 0.095 s | 34%: everything else, spread thin |

Two A64 changes were tried against the last row and reverted: hoisting wide
constants out of loops (1000000 and 2000000 were built twice a particle; the
pressure gate needed to stop counting checked arithmetic, inline-bump
allocation and in-place reuse as calls) removed four instructions a particle
and changed no time on sim, fannkuch, nbody, spectralnorm, mandelbrot or
fasta. The steady-state loop already ticks fuel once a particle (the other
ticks were in the peeled first iteration), so there was no tick to merge.

## Record maps that take a helper's tuple apart (`Core/Opt/Vector.hs`)

A `Vector` of records is stored a column per field, Int fields as raw words,
and `Vec.map f` over a known record-to-record `f` can run as a column kernel
that writes the columns in place. `move` declined: the vec note said its
fields "did not dualize". `(x, vx) = bounce (p.px + p.vx) p.vx` is a let of
the inlined `if .. then (a, b) else ..`, a tuple tag test and a projection per
name, and the dualizer could not see through a projection of an `if`.

`takeApartProducts` runs after inlining: lets are substituted (as `strip`
already does for its spine), projections and tag tests move into the branches
until they meet the construction, a tuple's tag test is True, and an `if` on
a known Bool or with equal arms is that arm. Each output field then dualizes
to its own arithmetic. As with a substituted let that a field does not use,
a computation no field needs is not evaluated, so its overflow is not raised.

`tests/bench/apps/sim_vector.fpr` is sim over a `Vector P` (same output),
built as the `fpr-vector` variant:

| sim | time |
|---|---|
| List (sim.fpr) | 0.093 s |
| Vector, generic tier (before) | 0.726 s |
| Vector, record-map kernel (now) | 0.162 s |
| C | 0.029 s |

The kernel is 4.5x the generic tier but not yet the list. It computes each
output field as a separate dual, inlined one after another: `bounce`'s
arithmetic and its overflow checks are repeated per field (33 trap sites),
each field brings its own fuel tick, and results are retagged before they
are stored back into raw columns. A kernel that evaluates the element
function once and stores all fields (one multi-result dual) is what would
make the layout's 35% available; it is the next step for record vectors.

**Untagged Int fields (item 3)** are what a Vector's columns already are. For
records on the heap (list elements, tree nodes) the tag is part of every
consumer's contract, and changing it is a representation change across the
compiler and runtime; not done.

## Sorting records: prefetch in the merge (`runtime/runtime.c`)

`records` sorts 1M records by three keys with `List.sortWith`. The runtime
merge sort already calls the comparator directly (resolved once), and the
comparator is about 30 instructions; 60% of the samples were in it. The ratio
to C grows with size (1.4x at 50,000 records, 2.2x at 1M), the signature of
cache misses: after the first passes the merged runs point to records
anywhere in 48 MB, and every comparison waited on two misses. The merge knows
its next elements, so it now prefetches the cells `SORT_AHEAD` (24) places
ahead in both runs, in the list merge and in `Vec.sortWith`'s permutation
merge:

| SORT_AHEAD | none | 6 | 12 | 24 | 48 |
|---|---|---|---|---|---|
| records | 0.206 s | 0.195 | 0.187 | 0.183 | 0.185 |

A prefetch never faults, so an Int or static element costs nothing.
Inlining the comparator into a sort written in FP-RISC would save the call
(frame, stack check, fuel tick) per comparison; with the misses hidden that
is what remains, and it was not done here.
