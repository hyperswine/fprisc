# What the benchmarks cover, and a first end-to-end workload

Date: 16 November 2026. Kind: assessment and implementation record. Compiler at `b454950a`
(0.15.0-dev), Apple M4.

## What exists

| Suite | What it is | What it steers |
|---|---|---|
| `tests/bench/clbg` | eight Benchmarks Game programs, nine languages | the three optimisation rounds of 14 and 15 November |
| `tests/bench/apps` | csv, wordfreq, treemap, records, format, sim against C, Go, Rust, Java, OCaml, with memory ceilings in CI | the allocation and reuse work of 11 to 14 November |
| compile budget | compiler allocation on hello, std-live, pos1 | compile time |
| micro-probes | ping-pong, cross-hart, fixed cost, reclamation; the QOS round-trip benches | one runtime path each |

## Where this is too narrow

1. **The suite that steers optimisation is the least like the programs FP-RISC is for.** The
   Benchmarks Game is numeric loops over flat arrays in single files. Inlining a callee named once,
   vector views and typed stores fit that shape exactly. nbody halving says little about a logbook,
   a POS or a QOS app, which are actors, records, strings, maps and many small modules.
2. **Nothing measures code across modules.** Every benchmark is one file, so the inliner's "named in
   exactly one place" rule always fires. Real programs call std containers from many sites in many
   units. Whether std data structures written in FP-RISC can match C ones is open, and no benchmark
   would show it either way.
3. **Nothing measured the products.** No end-to-end number existed for an FPRLive app (sales a
   second, latency, memory after a day) or for QOS Main (start time, frame time, memory on the Pi).
   The actor probes measure one message hop, not a workload.

Smaller gaps: timing is taken on one machine (Linux x86-64 and RISC-V are checked for correctness
only, the Pi not at all); no speed regression is gated (only compile allocation and memory
ceilings); and eight programs tuned over three rounds make their geometric mean partly a measure of
fit to those eight.

## Plan

1. End-to-end workloads from real code: a scripted pos1 or logbook session, and QOS Main
   start-to-ready plus a scripted interaction on the Pi. **Started below.**
2. A multi-module benchmark where std containers are called from many sites, to settle the
   cross-unit inlining question.
3. An instruction-count gate in CI for a handful of programs.
4. Freeze the Benchmarks Game suite as a regression check and stop choosing work from it.

## Item 1, first workload: cashiers on pos1

`tests/bench/e2e` ([specification](../tests/bench/e2e/SPEC.md)): `posdrive.c` is a headless page.
It opens websockets to a running `examples/pos1.fpr`, signs in, and makes sales with the frames the
real page sends (cart mirror, then Card or Cash), each session in a closed loop with no think time.
`sol run.sol` builds, runs and checks that the shop log holds every sale.

Results (server under `/usr/bin/time -l`; latency is mirror sent to acknowledgement received):

| Run | sales/s | p50 ms | p99 ms | KB received per sale | server instructions per sale | peak memory |
|---|---:|---:|---:|---:|---:|---:|
| 1 cashier, 25 sales | 61.7 | 16.7 | 21.6 | 432 | 388 M | 0.42 GB |
| 1 cashier, 50 sales | 45.2 | 21.6 | 34.7 | 765 | 559 M | 0.93 GB |
| 1 cashier, 200 sales | 31.4 | 34.8 | 37.2 | 1,238 | 816 M | 5.2 GB |
| 8 cashiers, 25 sales each | 73.9 | 90.3 | 240.7 | 1,514 | 1,191 M | 6.0 GB (footprint 8.7 GB) |

All sales were acknowledged and logged in every run. One earlier 200-sale run with the compiler at
`18fce327` peaked at 2.8 GB; the runtime changed in between and the runs were not repeated, so the
peak figure is one sample each.

For scale: the same machine runs nbody's 5,000,000 steps in 15 G instructions. One sale here costs
0.4 to 1.2 G.

### What the numbers already show

None of this was visible in the other suites.

- **A sale resends the receipts region whole, and a receipt is large.** In a five-sale probe with
  two products, each sale's patch grew by about 18.7 KB: one receipt's markup. The page at sign-in
  is 166 to 259 KB. So bytes per sale grow with the receipts shown, to 1.2 MB by 200 sales.
- **Server work per sale grows with the receipts too**: 388 M instructions at 25 sales, 816 M at
  200.
- **Most of the server's busy time is equality over lists.** A four-second sample of the 200-sale
  run (one hart) has, outside the idle waits, 1,389 samples in the runtime's structural equality
  (`veq`) and 577 in `entryMember` of the UI library's CSS collection, against 203 in the next
  function (string quoting). `entryMember` asks "is this entry already in the list" with `==`, once
  per entry: quadratic in the number of CSS atoms, on every render.
- **Peak memory grows with the number of sales**: 0.42, 0.93, 5.2 GB at 25, 50, 200 sales. The cause
  is not established. It may be garbage held until a region ends, or retention.

These are library and application costs (how std/ui collects CSS, how a list region is patched),
not code generation. That is the point of the workload: the last three rounds made loops over
vectors about twice as fast, and none of it touches what a sale costs.

### Limits of this first version

- One application and one script. `logbook` and QOS Main on the Pi are not done.
- No think time, so memory that would be released between events at a shop's pace may not be.
- macOS only so far. `run.sol` picks `/usr/bin/time -v` on Linux but has not been run there.
- The driver's acknowledgement is specific to pos1 (the cart emptying). Another app needs its own.
- Not in CI and not gated.

### Next

1. Find the causes behind the three findings above, in that order of cost: the `entryMember`
   membership scan, the whole-region resend, the memory growth.
2. Add `logbook`, then the QOS Main start-to-ready measurement in the QOS repository.
3. Once the numbers are stable, gate instructions per sale and peak memory in CI.

## Follow-up the same day: three fixes, and what is still open

Same machine and compiler; the table is `sol run.sol` before and after.

| Run | instructions per sale | p50 ms | KB received per sale | sales/s | peak memory |
|---|---:|---:|---:|---:|---:|
| 1 cashier, 25 sales | 388 M → 116 M | 16.7 → 5.8 | 432 → 35 | 61.7 → 164.6 | 0.42 → 0.21 GB |
| 1 cashier, 50 sales | 559 M → 127 M | 21.6 → 6.1 | 765 → 30 | 45.2 → 161.2 | 0.93 → 0.52 GB |
| 1 cashier, 200 sales | 816 M → 147 M | 34.8 → 7.4 | 1,238 → 25 | 31.4 → 140.0 | 5.2 → 2.7 GB |
| 8 cashiers, 25 sales each | 1,191 M → 337 M | 90.3 → 21.6 | 1,514 → 1,453 | 73.9 → 163.5 | 8.7 → 5.7 GB |

1. **CSS entries deduplicated through a set** (`std/view.fpr`, `nubEntries`). It asked "is this name
   in the rest of the list" for every entry of the page: quadratic, on every render. The names seen
   now go in a `Set`, walking backwards so the entry kept is still the last occurrence, in the same
   order. 200 sales: 163 G to 48.6 G instructions, the bytes sent unchanged.
2. **A cut mark** (`View.cut`, `View.cutKids`; `std/view.fpr`, `std/livejs.fpr`). The wire sends
   statics and dynamics as two arrays and a change re-sends whole elements. Cached receipt rows hold
   no `Dyn`, so the whole list was one static and every sale re-sent it. `cut` is a `Dyn` whose text
   is a reserved mark; it ends a static piece and the page script gives it no slot element, so
   nothing is drawn. pos1's `receiptRow` puts its children between two cuts. A sale then sends its
   own row: 1,238 KB to 25 KB per sale at 200 sales. The cut goes in the row renderer, so a cached
   row and a fresh one still render the same (the `verify` comparisons hold).
3. **`Encoding.hex` over a byte buffer** (`std/encoding.fpr`). It built two one-character strings
   and two cells per byte and joined them; std/view names every class by the hex of its
   declaration. 200 sales: 37.5 G to 29.4 G instructions, output identical.

Checks: std golden 49 of 49; `check_live_patch`, `check_view_utilities`, `check_client_state` pass;
in headless Chromium pos1's receipts render and go from 5 to 8 rows by live patch with no mark in
the page, no extra slot elements and no page errors. `check_client_calculations` times out waiting
for the cart total, with and without these changes (not investigated).

### Still open

- **A session's writer holds memory until the session ends.** About 13 MB a sale, linear, not
  released when idle; with `FPR_HEAP_MB=256` the server stops with "heap exhausted" before 200
  sales, so this is held memory, not lazily freed pages. After the cashier leaves, the runtime
  reports 18 MiB in use. The writer's own gauge (`heapUsed`) reads a constant 464,848 bytes across
  turns while it renders megabytes each turn, so `Actor.tidy` never fires: what a turn allocates
  is neither counted in the actor's pool nor released at the end of the turn. This is in the
  runtime or the turn regions, not in the application, and is the next thing to find.
- **Eight cashiers still receive 1.45 MB per sale.** The row cut fixed the session that made the
  sale; what the other sessions are sent was not examined.
- **A receipt is about 18.7 KB of markup**, mostly class names that are the hex of a declaration.
- Each event still renders the page outside the cached cards and rows: 116 to 147 M instructions a
  sale.

## The memory held by a session: a call region around a loop that never returns

Found and fixed the same day (`codegenRev` 240).

| Run | peak memory before | after |
|---|---:|---:|
| 1 cashier, 25 sales | 0.21 GB | 28 MB |
| 1 cashier, 50 sales | 0.52 GB | 45 MB |
| 1 cashier, 200 sales | 2.7 GB | 48 MB |
| 8 cashiers, 25 sales each | 5.7 GB | 279 MB |

With `FPR_HEAP_MB=256`, 200 sales now complete (46 MB resident) where the server used to stop
with "heap exhausted".

**Cause.** The compiler puts a pending region around a call to a function that allocates
(`ReceiveTurns.callRegions`): what the call allocates goes to the region's arena and dies when the
call returns. Nothing excluded a callee that never returns. Live's session writer (`writing` in
`std/live.fpr`) is such a loop; it is not a compiler receive loop (its state holds the app's
functions), so it keeps itself small by hand with `Actor.tidy`, which resets the actor's pool once
`heapUsed` passes a limit. Under the pending region every turn's allocation went to the arena
instead: the arena never ended, `heapUsed` never moved (a constant 464,848 bytes while megabytes
were rendered each turn), and `tidy` never fired. The session held everything it had ever
allocated until it died.

How it was found: the buddy's block takes by actor showed one actor taking 445 MiB of slabs in 30
sales; that actor never cycled a receive region; its retired state slabs were all reusable; its
count of shared objects was flat. So the memory was in an arena that was never reset.

**Fix.** `costly` in `compiler/ReceiveTurns.hs` no longer admits a callee that may wait for a
message (it may be an actor's loop) or one that manages its own pool (`Sys.poolReset` and the
rest: under a region it would reset the pool and leave the arena). Both sets already existed in
the analysis and include what a function reaches in other units.

**Cost.** The writer now does its boundaries: 200 sales take 34.9 G instructions against 29.5 G
(147 M to 175 M per sale; p50 7.4 to 8.4 ms). That is the price of the reclamation that was
silently not happening. Any long-lived actor with a hand-written loop was exposed to this, not
only Live's writer; QOS apps should be re-measured at the next pin.

Checks: compiler unit suites pass; the Sol suite runs 18 checks with 0 unexpected outcomes; std
golden 49 of 49; the four end-to-end runs log every sale.

Still open from the list above: what eight cashiers are sent (1.5 MB per sale), the size of a
receipt's markup, and the render outside the cached parts.
