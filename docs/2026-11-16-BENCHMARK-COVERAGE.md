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
