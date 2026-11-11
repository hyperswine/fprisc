# Application workloads in the tree, and the garbage that is never freed

Date: 11 November 2026. Kind: measurement record and proposal. Baseline: main
`57201f0`. It changes no compiler, runtime or library behaviour; it adds
`tests/bench/apps/` (item 0 of the [performance priorities](2026-11-09-PERFORMANCE-PRIORITIES.md)).

## Summary

- The six application workloads now live in `tests/bench/apps/` with a
  specification (`SPEC.md`), a deterministic input generator, FP-RISC
  programs, C/Rust/Go/OCaml/Java peers that print byte-identical output, and
  a runner that refuses a wrong answer.
- On an Apple M4 at `57201f0`, FP-RISC is **12.6x C and 7.9x the peer
  median** (geomean). The 9 November figures on the Xeon VM were 17.8x and
  8.8x, but the machine, the inputs and the programs differ, so the two are
  not a trend.
- csv, wordfreq and sim are still 14-30x the peers, and all three peak at 1.4-3.8 GB.
  The garbage has three sources:
  - a loop's state is rebuilt on every step (sim, the folds);
  - a persistent tree is path-copied (wordfreq, csv, treemap);
  - every string piece is a separate object (format, csv).
- The copy-out fallback added today works (sim: 3775 MB to 15 MB) but doubles
  the time. The reason is mechanical: it copies the whole live state every
  64 KiB of allocation. Three changes would make it cheap enough to be the
  default safety net: a trigger scaled to live size, no copying of objects
  outside the region, and preserved sharing. See "What can be done".

## Measurements

Apple M4 (10 cores), macOS, `57201f0`, `fpr build` defaults. One warm-up
round, then 5 shuffled interleaved rounds. The table shows median wall time
and median peak RSS (`/usr/bin/time -l`). Peers: Apple clang `-O2`, rustc
`-C opt-level=3`, Go 1.27.4, OCaml 5.1 (no flambda), OpenJDK 17 (time
includes JVM start). Raw data: `tests/bench/apps/results/2026-11-11-m4-57201f0.json`.

| Workload | FP-RISC | FP-RISC MutMap | C | Rust | Go | OCaml | Java | /C | /peer median |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| csv | 0.908 s / 1356 MB | | 0.025 / 17 | 0.052 / 17 | 0.066 / 67 | 0.124 / 66 | 0.200 / 235 | 37.0x | 13.7x |
| wordfreq | 1.248 s / 1795 MB | 0.241 / 232 | 0.053 / 26 | 0.063 / 24 | 0.088 / 73 | 0.248 / 39 | 0.329 / 203 | 23.4x | 14.2x |
| format | 0.645 s / 1026 MB | | 0.196 / 71 | 0.108 / 102 | 0.185 / 94 | 0.418 / 82 | 0.803 / 706 | 3.3x | 3.3x |
| records | 0.333 s / 209 MB | | 0.101 / 32 | 0.059 / 48 | 0.158 / 36 | 0.543 / 51 | 0.304 / 148 | 3.3x | 2.1x |
| treemap | 0.586 s / 614 MB | 0.248 / 163 | 0.063 / 50 | 0.096 / 12 | 0.073 / 20 | 0.469 / 49 | 0.365 / 134 | 9.4x | 6.1x |
| sim | 1.347 s / 3775 MB | | 0.030 / 2 | 0.037 / 2 | 0.046 / 5 | 0.097 / 4 | 0.107 / 77 | 45.3x | 29.5x |

The MutMap columns are the same program rewritten by hand to use MutMap. With them,
wordfreq is 4.5x C and treemap 3.9x C.

Caveats:
- Several C/Rust runs take 25-60 ms, close to process start-up.
- sim's C and Rust loops are probably vectorised.
- On sim, the installed 0.13.0 compiler peaks at 1.4 GB and takes 3.25 s;
  main peaks at 2.5-3.8 GB and takes 1.35 s. The extra memory on main is
  not explained yet.

## Where the garbage comes from

Facts about reclamation today come from a code survey at `57201f0`. A
hosted program's `main` is actor 0 and gets no turn arena, so nothing it
allocates is freed until it exits, except in four cases:
- loop regions, for bounded-state loops;
- call regions, which free only when the call returns, and adopt the result instead of freeing if it is large;
- consuming reuse;
- explicit `Sys.arena`/`loop`/`poolReset` and `free`.

| Workload | Garbage | Why nothing frees it |
|---|---|---|
| sim | a new `P` record, a new cons cell and two `bounce` tuples per particle-step (40M steps, about 94 bytes each) | `run` is declined as a loop region (`live parameter 2 has List P`). Spine reuse needs a fresh initial spine, but `gen` ends in `List.reverse`. Element records are never reused. |
| wordfreq, csv | the AVL path (about 17 nodes) copied by every `Map.update`, plus an `Option` and a tuple per update | The fold accumulator is unique, but nothing proves it for std `Map`. The loop is std `List.fold` with a closure, so no named function can be selected for copy-out. |
| csv, format | one object per string piece: `lines`, `split` and `toInt` pieces; interpolation fragments and number strings | The pieces are short-lived, but `main` never resets. |
| treemap | AVL path copies in `inserts` | Same as the maps above. |
| records | each pass of the merge sort reallocates every cell | Same. 209 MB is tolerable. |

Experiments on sim (single runs, M4):

| Variant | Time | Peak RSS |
|---|---:|---:|
| as written | 1.35 s | 3775 MB |
| `bounce` without tuples | 1.23 s | 3068 MB |
| a hand-written recursive `stepAll` instead of `List.map` | 1.81 s | 3535 MB |
| initial list from `List.map mk (List.range ...)` (fresh spine), reuse on | 1.62 s | 3217 MB |
| the same, `FPR_NO_REUSE=1` | 1.76 s | 3725 MB |
| `FPR_PERSISTENT_LOOP=run` (copy-out) | 2.59 s | 15 MB |
| copy-out, `bounce` without tuples | 2.80 s | 12 MB |

What the experiments show:
- **Spine reuse fires** once the initial spine is fresh, and saves about 0.5 GB.
- **Records are the bulk** of what remains: the element record is rebuilt every step and never reused.
- **Copy-out bounds memory at about 2x the time.**
- **Interpolation pieces are short-lived garbage.** format with explicit `String.concat` instead of interpolation still peaks at 778 MB to hold 56 MB of lines.
- **Copy-out did not apply elsewhere.** Selecting `fold` (csv, wordfreq) or `inserts` (treemap) produced no copy-out; only sim's `run` and records' `gen` were accepted.

## What can be done

This follows the [11 November decision](2026-11-11-MEMORY-RECLAMATION-INTENT.md):
(a) static reuse first, (b) regions with copy-out as the fallback, no ARC in
Base. The items are ordered by what they buy.

### 1. Make copy-out cheap, then make it the default for declined loops (b)

Copy-out is the only mechanism that bounds memory without a uniqueness proof.
Today it costs about 2x on sim because the cycle trigger is a fixed 64 KiB:
sim's live state is about 1.3 MB, so each cycle copies about 20x what it frees.
Three runtime and placement changes:

1. **Trigger on growth relative to live size.** Cycle when the bytes bumped
   since the last copy reach k times the bytes that copy produced (k = 2, the
   open `Compact AtDouble` question). The copy work is then at most 1/k of
   allocation, and peak memory is at most about (k + 1) times live. A
   per-loop `last_live` word beside the mark is enough; the back-edge test
   compares against it instead of the constant `65536 * 8`
   (`Codegen/Target/A64.hs:422`, `runtime.c:2199`).
2. **Do not copy what lies outside the region.** `dc_dup` re-copies
   caller-pool objects on every full compaction. Those objects cannot die
   while the loop runs, so the copy can stop at any pointer outside the
   region's arena. That is the 23 October proposal's rule, which the code does
   not implement. Without it, a fold over a large input list copies the
   remaining input every cycle.
3. **Preserve sharing.** `dc_dup` duplicates DAGs. A forwarding word, or a
   small address table per copy, keeps a shared subtree single, as a
   semispace copy does.

With these three, copy-out can be selected automatically for every loop that
stage 2 declines, instead of through `FPR_PERSISTENT_LOOP=<one name>`. It
must also reach loops inside std higher-order functions (`List.fold`), whose
state is the closure's accumulator. These are the gates the intent already
names: sim RSS flat; csv and wordfreq RSS at most about 2x for 2x input.

### 2. Extend static reuse to element payloads and std maps (a)

This is the speed item. When uniqueness is proved, a step allocates nothing.

- **Element reuse in consuming map workers.** In
  `case ps of p :: rest -> f p :: ...` with a unique spine, `p` is unique too.
  When `f` is known and returns a record of the same layout (sim's `move`),
  a consuming twin of `f` writes the result into `p`'s cell. Together with the
  spine reuse that already exists, sim's steady state allocates nothing.
- **Freshness through `List.reverse` of a fresh accumulator**, so builders
  written the usual way (sim's and records' `gen`) count as fresh.
- **Re-enter the consuming twin after a region cycle.** Today the cold path
  `$loop.cycle.f` re-enters the borrowing `$loop.in.f` (`ReceiveTurns.hs:503`),
  so (a) and (b) do not compose.
- **Consuming twins of `Map.insert`/`update`/`insertWith`** for a uniquely
  owned map, such as a fold accumulator whose last reference is given up.
  They rebalance in place instead of path-copying. Per the MutMap measurement
  this closes most of wordfreq and treemap without asking the programmer to
  switch to MutMap. It needs the per-path ownership evidence the copy-out
  page says is missing.

### 3. Allocate less in the first place

- **Interpolation as one sized builder.** Size the pieces, allocate once and
  fill, with no intermediate fragments or digit strings. This is a format and
  csv reporting cost.
- **String slices for `lines`/`split`/`words`**: a view into the input
  buffer instead of a copy per piece. This is priorities item 2a. It interacts
  with copy-out, which must not keep a whole buffer alive for one slice (an
  open question in the intent).
- **Unboxed pair returns** for small helpers like `bounce` (unboxing
  proposal A1/A2): about 0.7 GB on sim.

### Suggested order

1. Runtime only: copy-out triggered on live size, stopping at foreign pointers, preserving sharing. Gate on sim and fixed_state.
2. Automatic selection of declined loops, including through `List.fold`.
3. Element reuse plus freshness through `reverse`, and the cycle re-entering the consuming twin.
4. Consuming twins for std `Map`.
5. Interpolation builder and string slices.

Item 1 is the smallest change and decides whether (b) can be on by default.
Measure it first.
