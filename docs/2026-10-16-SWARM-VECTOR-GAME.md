# Swarm: a game as a workload for `Vector a`, and what it found

Date: 2026-10-16. Kind: experiment record. Follows the vector audit
([2026-10-03-VECTOR-AUDIT.md](2026-10-03-VECTOR-AUDIT.md)) and the
kinds/pipelines/SIMD page ([2026-10-04-VECTOR-KINDS-PIPELINES-SIMD.md](2026-10-04-VECTOR-KINDS-PIPELINES-SIMD.md)).
The question asked: can performance-sensitive FP-RISC programs use the
fused, SIMD, column-stored `Vector a` and its `Vec.map`/`Vec.fold` well? The
answer before this page: nothing in the examples did, and QOS's renderers
use the fixed kernels by hand. So a program was written to find out.

## The game

`examples/swarm.fpr`: thousands of motes hunt the player on an 80x24
terminal (std/term, Base profile on the posix system). Arrows move, Space
pulses (motes near you are thrown back, for energy), a mote in your cell
bites, the score is the ticks survived, thirty ticks a second. A tick is:

1. **step**: every mote steers toward the player (away, inside a pulse),
   its speed is capped, it stays on the field;
2. **bites**: how many motes share the player's cell;
3. **picture**: a density histogram of the field, one glyph per cell.

The same tick is written three ways, selectable with `--mode`, and
`--bench=N` runs N ticks without a terminal and prints the cost per tick,
per mote and per phase. `fpr build -v` prints the compiler's vec notes.

- **records**: one `Vector Mote` of `{x, y, vx, vy}` and the natural
  element functions: `Vec.map (step px py pulse w h)`, `Vec.fold (bite px
  py)`, a fold whose accumulator is the screen vector.
- **captured**: the same, with the five scalars passed as ONE captured
  record `{px, py, pulse, w, h}` whose fields `stepK` projects, and the
  clamps spelled inline: the shape the record kernel takes.
- **columns**: four `Vector Int` columns and the fixed kernels: `axpb`,
  `sar`, `zipAdd`, `zipMul`, `minS`/`maxS`, `ges`, `blend`, `eqS`, with
  `Vec.dup` before every second use of a column.

## What the compiler did with each

Measured on this macOS arm64 host, one hart, 80x24 field; the picture
(a scatter into the screen vector through `Vec.at`/`Vec.put`) is the same
generic fold in all three.

| Mode | 4,000 motes: step / tick | 40,000 motes: step / tick | step per mote |
|---|---:|---:|---:|
| records (generic rows) | 150-170 us / 430-470 us | 1.7-2.3 ms / 3.3-3.5 ms | 40-57 ns |
| captured (record kernel, in place) | ~1,040 us / 1,310 us | 11.1 ms / 11.5 ms | 260-280 ns |
| columns (fixed kernels) | 21-23 us / 200 us | 230-350 us / 1.1-1.2 ms | 5.5-8.5 ns |

The bites fold (`bite px py`, two scalar captures, a closed arithmetic
body) specializes in every mode: 16-17 us for 4,000 motes. The picture is
150-200 us for 4,000 and 0.6-1.5 ms for 40,000, the largest single phase in
the columns mode: there is no scatter-add kernel, so a histogram is a
generic fold with a vector accumulator.

## Why the natural spelling did not engage, in order of discovery

1. **The dualizer's fragment.** A column kernel takes literals, the ten
   operators `+ - * / == != < > <= >=`, `if`, `let`, and calls into the same
   fragment (`compiler/Codegen.hs` `bodyOK`). A top-level constant (`sc =
   256`) is a call it declines; `and`/`or` are not operators to it; `%` is
   not in the set. `step` and `bite` were rewritten with literals and
   nested ifs, and `bite` then specialized.
2. **Record maps take ONE capture, a record.** `step` has five scalar
   captures. The record kernel's capture is a boxed record whose fields the
   element function projects (`soaDualMap`); a capture used whole (an Int
   key to unpack, the first attempt) escapes and declines. The vec note
   said neither: it printed the generic "not a closed arithmetic/record
   dual" because `arithClosure` fails on any record projection. The note
   now names the capture rule and the field rules for record maps.
3. **Record maps take no helper calls in their fields**, even arithmetic
   ones that `bodyOK` would admit: `clamp lo hi v` declined, inline ifs
   pass. (The dualizer inlines saturated calls to a depth of eight before
   stripping; why `clamp` still declined was not chased.)
4. **Bug: the projection dispatch took the first arm.** When two record
   types share a field name, the desugarer projects through a shape
   dispatch. The dualizer's field walk treated any shape test on the
   element as true and took the first arm, which could be the OTHER
   record's column index; the kernel then read a frame slot (a tagged Int)
   as a column cursor and crashed (`fpr_vspec_mvmap_two`, found by a probe
   that declared a four-field record beside a two-field one). Fixed: the
   walk takes the element's own arm (`strip` already knew the shape).
   The same dispatch on a captured record now takes the capture's arm
   when the call site builds the record literally, and declines when the
   capture's shape is unknown. `tests/base/vecshape.fpr` is the test; the
   swarm itself hit the capture case (`Player.w` beside `Model.w`).
5. **Bug: same-type record maps were read as type-changing.** `Vec.map f`
   stays a plain map (and a kernel candidate) only when the element type
   is unchanged, and that was tested with the derived `Eq` on types, whose
   record rows are chains in the order the fields were met. `{ x = p.x +
   p.vx, y = .. }` met `vx` before `y`, built a row in another order than
   the declared type, and the map became `Vec.mapAs`, which no kernel
   matches; the heap grew by a vector per pass and no note said so (the
   audit's P1 "type-changing lowering" item, from a wrong classification).
   Fixed: compared in canonical form (`canonicalType`, both types
   canonicalized together: each alone, two distinct type variables both
   become `t0`, and a generic `convert f v` read as unchanged, which
   `tests/base/veclimits.fpr` caught on the first attempt), so every
   same-type record map is a candidate. Probes r3/r4/r5 on this day went
   from 25-39 ns per element and 385-514 MB of growth over 100 passes to
   4-9 ns and zero.

## What the record kernel costs when it does engage

Each output field of a record map is a separate unboxed clone
(`fpr_ufn_mv_<f>_<i>`), called per element from the kernel loop. The clone
is compiled like any FP-RISC function: every argument spilled to its
frame, every `+`/`-` with the Int overflow check sequence, and fuel
accounting per call. Shared `let`s are substituted into every field that
uses them, so `stepK`'s four fields each recompute `dx`, `dy`, `near` and
the clamped speeds. For `{ x = p.x + 1, y = p.y + 2 }` that is 5 ns per
element and no allocation, seven times the generic tier's speed; for
`stepK` it is 260 ns, three to five times SLOWER than the generic rows,
which compute the body once per element. The fixed kernels, each a C loop
over one column with the vectorizer on, are 5-8 ns per mote for the whole
step, at the price of eleven `Vec.dup` copies per tick and shifts in place
of division (`sar 7` floors where `/ 128` truncates: the two modes'
health counts differ slightly for that reason).

## What a program author should do today

- Numeric state that changes every tick belongs in `Vector Int` columns
  with the fixed kernels. Keep the kernel count low and `Vec.dup` where a
  column is read twice; it is the only tier that is fast now.
- A record map pays off when its fields are a few operations each and it
  has no captures or one captured record; it is in place and allocation
  free, and the fixes above make the natural spelling reach it.
- A fold with arithmetic captures (`bite px py`) specializes and is cheap.
- A histogram, a scatter, anything indexed by the data has no kernel:
  write the fold and expect the generic tier.

## What the compiler should do next

- Hoist shared lets out of the per-field duals, and inline the field
  clones into the kernel loop (or at least compile them without the spill
  frame): the record kernel's per-element cost is the clone call, not the
  arithmetic.
- A scatter-add kernel (`Vec.bump idx counts` or a histogram) for the
  picture shape; a `Vec.modS`/`Vec.divS`, since `%` and division by a
  scalar are what field arithmetic wants.
- Let `and`/`or`, `%`, and top-level Int constants into the fragment; the
  constants are literals after inlining.
- Say in the vec note when a site is `Vec.mapAs` because the output type
  differs, and when a kernel's runtime guard fell back: both were silent.
