# Where the remaining app gap goes: x64 profile, 2026-11-14

Compiler and runtime: `main` at **3485b92f**. Its `compiler/`, `runtime/`, `std/`, `core/`
and `machine/` trees are identical to 23f10023; the commits in between only touch
checks and CI. Measured on x64 native, Debian trixie, an 8-vCPU VM box, with no
hardware PMU (perf `cycles` and `instructions` are "not supported"). Timing therefore uses the
`cpu-clock` event plus wall/rusage, and instruction counts come from valgrind
callgrind 3.24, which gives exact per-instruction counts.

Everything in `raw/` came from these runs. Numbers marked **est.** are my
estimates and were not measured.

## Method

* Inputs come from `tests/bench/apps/gen.py`, recovered from `1b4aca16^` (it was deleted
  in the Sol cutover). The binaries were built with `fpr build`, with the run cache off for the ablations.
* Timing: one warm-up, then N interleaved rounds in shuffled order. Each run starts only
  when the 1-minute load average is ≤ 1.5. I report the median wall time and the median peak RSS
  (from `wait4` rusage), and every output was checked against `expected/`. That makes 5 rounds for the baseline and
  7–10 for the experiments that decide something.
* Profiles:
  * `perf record -e cpu-clock -F 20000` gives time shares, including kernel time.
  * `valgrind --tool=callgrind --dump-instr=yes` gives exact instruction counts. Each executed instruction
    was joined with `objdump -d` and classified (`raw/callgrind/*.class.txt`).
  * `perf record -e page-faults -c 1 -d` gives the address of every page fault and the instruction that took it.
* Peers: only C (`cc -O2`), Rust (`-C opt-level=3`) and Go are installed on this box, not
  OCaml or Java. The peer median below therefore covers C/Go/Rust and is **not comparable** with
  earlier 5-peer medians.

## Baseline (5 rounds, medians; `raw/times-baseline.json`)

| program | wall / peak RSS | user / sys s | vs C | vs C/Go/Rust median |
|---|---:|---:|---:|---:|
| sim | 0.412 s / 14 MB | 0.410 / 0.008 | 9.3x | 6.2x |
| csv | 0.694 s / 170 MB | 0.568 / 0.152 | 15.9x | 9.2x |
| csv_hashmap | 0.755 s / 170 MB | 0.614 / 0.162 | 17.3x | 10.0x |
| wordfreq (std/map) | 1.254 s / 341 MB | 1.078 / 0.210 | 12.1x | 9.3x |
| wordfreq_mutmap | 0.677 s / 341 MB | 0.492 / 0.212 | 6.6x | 5.0x |
| wordfreq_hashmap | 1.264 s / 341 MB | 1.064 / 0.216 | 12.3x | 9.3x |
| treemap (std/map) | 1.054 s / 60 MB | 1.020 / 0.048 | 7.9x | 7.9x |
| treemap_mutmap | 0.429 s / 159 MB | 0.366 / 0.079 | 3.2x | 3.2x |
| treemap_hashmap | 1.693 s / 134 MB | 1.600 / 0.100 | 12.7x | 12.7x |
| format | 0.655 s / 394 MB | 0.422 / 0.221 | 2.7x | 2.7x |
| records | 0.843 s / 125 MB | 0.787 / 0.079 | 3.2x | 3.2x |

Peers: csv C 0.044 / Go 0.138 / Rust 0.076 s; wordfreq 0.103 / 0.196 / 0.135; sim
0.044 / 0.067 / 0.068; treemap 0.133 / 0.129 / 0.172.

## Headline: the user-time gap is the instruction-count gap

| app | FP-RISC instructions | C instructions | ratio | user-time ratio | instr/s FP-RISC vs C |
|---|---:|---:|---:|---:|---:|
| sim | 6.714 G | 0.722 G | 9.3x | 9.8x | 16.4 G vs 17.2 G |
| csv | 5.934 G | 0.278 G | 21.3x | 20x | 10.4 G vs 9.9 G |
| wordfreq | 6.426 G | 0.475 G | 13.5x | 12.3x | 6.0 G vs 5.4 G |
| treemap | 3.148 G | 0.286 G | 11.0x | 11.7x | 3.1 G vs 3.3 G |

On every app, FP-RISC retires instructions about as fast as the C peer does. So the gap is
not cache behaviour that C avoids; we execute 9–21x more instructions. The other
large cost is **kernel time (page faults)**. It is 21% of CPU time in csv, 16% in wordfreq and 30% in
wordfreq_mutmap, against about 0 for C.

## Where time goes (perf cpu-clock share of samples; `raw/buckets.txt`)

| bucket | sim | csv | wordfreq | wordfreq_mutmap | treemap |
|---|---:|---:|---:|---:|---:|
| kernel (page faults, read) | 0.9% | 25.5% | 17.4% | 27.8% | 3.9% |
| generated: byte scans (`charFrom`, `wordEnd`, `wordsGo`, `linesGo`, split) | – | 19.7% | 13.4% | 24.8% | – |
| generated: Int parsing (`digitsGo`, `toIntGo`, `isNeg`) | – | 7.2% | – | – | – |
| generated: map walks (insert/lookup/rebalance) | – | 14.8% | 27.9% | – | 80.5% |
| generated: other (sim's loop is here) | 95.6% | 2.6% | 3.5% | 4.4% | 4.6% |
| runtime: string ops (`g_strCompare`, `g_substr`) | – | 10.9% | 28.9% | 3.9% | – |
| runtime: hash table (`mm_*`) | – | – | – | 17.9% | – |
| runtime: allocator | 0.0% | 6.3% | 1.5% | 9.5% | 0.2% |
| runtime: regions / copy-out / pend-leave | 0.0% | 11.2% | 5.6% | 8.5% | 9.1% |
| runtime: closures, generic apply, sort | – | – | 0.2% | 2.0% | – |
| runtime: scheduler / fuel | 3.1% | 1.4% | 1.2% | 0.9% | 1.1% |

Instruction shares (callgrind) are in the same file. The time and instruction shares agree, except
for the kernel and the cache-missing tree walks.

## Per app

### sim (0.41 s, 14 MB; 9.3x C)

* 99% of instructions sit in one loop,
  `$worker.spineE.cursor.$worker.trmc.$trmc.3.run.0`. It takes **166 instructions per
  particle-step against C's 18** (6.64 G / 40 M steps).
* In-place reuse works. The loop writes the four fields back into the existing cell
  (`mov %rax,0x8(%r14)` … in `raw/perf/sim.annotate.txt`), there is no allocation and no call
  in the loop, and RSS is 14 MB. **Candidate 2 (reuse/regions) is not sim's problem, and neither are
  the cross-call register allocation or bump-spill parts of candidate 4**, because the loop makes no calls and does not allocate.
* The instruction mix of the loop (`raw/callgrind/sim.class.txt`), as a share of all instructions:
  * register moves 14.3%
  * cmp/test 14.3%
  * **unconditional jmp 11.9%**
  * **tag/untag/overflow checks 10.8%** (`shl $1; sar $1; cmp; jne` after every add, plus re-tagging)
  * conditional branches 10.2%
  * heap loads/stores 9.5%
  * **boolean materialization 9.5%** (`setl; movzbq; mov to frame; reload; test; jne`)
  * **frame spill/reload 8.3%**
  * **`movabs` of small constants 6.0%**
  * fuel tick 1.8%
* Layout sensitivity: `sim` and `sim_nocallreg` execute exactly the same instructions
  (6.714 G vs 6.711 G), yet over 10 rounds they take 0.404 s vs 0.355 s. Their hot loop heads sit at
  different, unaligned addresses (0x41d65f vs 0x41d612). Aligning hot loop heads looks like a cheap ~10%
  for sim; that is my reading of this one pair and is **not yet tested**.

### csv (0.69 s, 170 MB; 15.9x C)

* **Byte scans: 19.7% of time, 31% of instructions.** The `charFrom` loop runs about 30.6 M
  iterations at **28 instructions per byte** (`raw/callgrind/csv-charFrom-per-instruction.txt`):
  * two compare/`set`/`movzbq`/`test`/`jne` sequences
  * three `jmp`s
  * an untag of the loop-invariant byte `c`
  * a dead re-tag of `i`
  * a `movabs $1`
  * a 4-instruction fuel tick in TLS memory

  A memchr-style scan needs about 1 instruction per byte or less; a plain tight loop needs about 4.
* Int parsing: 7.2% of time, 17.8% of instructions. That is about 528 instructions per parsed
  number (`digitsGo` + `toIntGo` + `isNeg`, about 2 M numbers).
* Map walk plus `g_strCompare`: about 24% of time, with 9.16 M string compares for 1 M updates over
  1000 keys. `csv_hashmap` is *slower* (0.755 s); see collections below.
* `g_substr`: 4.0 M calls, 11.4% of instructions including its `fpr_alloc` (the C allocator
  path, about 90 instructions per allocation; 3.99 M of the 4.02 M `fpr_alloc` calls come from substr). That is
  about 7% of time. The pieces are 1–5 bytes, so a slice *view* cell would be no smaller than
  the copy.
* Kernel: 25.5% of time. 82.9 k page faults touch 324 MB to reach a 170 MB peak. The faults break down as:
  * 38% from `memset` inside `transfer_copy_in`, which zeroes copy-out targets (67 calls)
  * 22% from `fpr_alloc`
  * about 24% from stack pushes, because `String.lines` recurses about 1 M frames deep (see wordfreq)
  * The heap also churns on Linux. `hal_heap_release` (`machine/unix/host.c`) uses
    `MADV_DONTNEED` on every freed buddy block (73 calls), so the pages are dropped and later faulted in again
    zero-filled. macOS uses `MADV_FREE`.
* Region machinery: 11.2% of time. It includes `g_call_pend`/`g_call_leave` (3 M / 2.1 M calls), the copy-out
  walks (`g_region_cycle → transfer_copy_in` at 126 M instructions and `region_close → kp_reaches` at 110 M)
  and `fpr_acb_override_slot` (11 M calls).

### wordfreq (std/map, 1.25 s, 341 MB) and wordfreq_mutmap (0.68 s, 341 MB)

* With `std/map`, the AVL walk plus `g_strCompare` take **about 56% of time**: 24.9 M string compares, about 12
  per word. Hashing (mutmap) halves the wall time, so this half of the gap comes from the data structure
  choice, not from codegen.
* `MutMap.insertWith` costs **31.8% of mutmap's instructions** (1.24 G), made up of:
  * the combine closure `fn old new -> old + new`, called through `fpr_apply`: **13.5%** of
    instructions. Each call does an `fpr_alloc`, a `memcpy` and an `fpr_free` (1.95 M of each).
  * `mm_str_hash`: 6.8%, about 131 instructions per word for words of about 8 bytes, so it hashes byte by byte.
  * `mm_find`: 5.2% of instructions but 14% of time, which points at cache misses.
* Byte scans (`wordEnd` and `wordsGo`): 25% of instructions in wordfreq and 41% in mutmap. `isSpace` per byte
  goes through the same compare/`set`/`test` pattern as `charFrom`.
* Kernel: 17% / 28% of time. Of the roughly 90 k faults, 46.9 k (183 MB) are stack pushes; this is the regression below.

### treemap (std/map 1.05 s; std/hashmap 1.69 s)

* 80% of time is in the AVL insert and lookup walks, at **about 4,400 instructions per insert**. The
  instruction mix is the same as sim's. The program retires only 3.1 G instructions/s (C manages 3.3 G with its hash
  table), so it is memory-latency-bound on top of the instruction overhead.
* Copy-out on the owned-map loop is pure overhead. With `FPR_NO_PERSISTENT_COPY_OUT=1`, wall time goes
  from 1.164 to **0.976 s (−16%, 10 rounds)**, instructions drop 10.4%, and RSS falls from 60 to **43 MB**. The
  loop rebuilds the map in place, yet `g_region_cycle` still walks it (`dc_size_in`, `kp_reaches`).

## Candidate causes: verdicts

1. **Substring copying / no slice views: mostly refuted as the big win.** substr
   with its allocation is about 7% of csv time and about 3–5% of wordfreq. The pieces are tiny, so views save little. The real
   string-side costs are the scan loops (20–25% of time) and, in csv, Int parsing. The win is
   to *not materialize* pieces at all: parse an Int from a range, and hash or insert a word from a range.
2. **Unfinished reuse and regions: refuted as a gap; the regions themselves are now a cost.** Reuse works
   (sim 14 MB, treemap rebuilt in place). Loop regions and copy-out are essential for memory:
   without them csv grows from 170 to 336 MB and wordfreq from 341 MB to 1.79 GB (`raw/experiments/ablation-times.json`).
   But their bookkeeping costs 5–11% of time, and on owned-map loops copy-out is 16% of wall time
   with no memory benefit.
3. **Collection layout and boxing: partly confirmed, in a different form.**
   * Ordered string-keyed maps cost wordfreq about 56% of its time (algorithmic).
   * `std/hashmap` is an AVL tree ordered by (hash, key), not a hash table. In treemap it loses to `std/map` because:
     * the final `toMap` sorts with the comparator through the generic closure path
       (`g_sortListWith → apply2 → fpr_applyN → callf`, 7.2 M calls, **29% of instructions**)
     * the insert walk costs +15% instructions (an `HK` box per key)
     * the hash function is called through a closure (1 M `callf → g_intHash`).
   * Ints are not boxed in the nodes I looked at. Tree walks are latency-bound, so node layout and locality matter for
     treemap, but I have no measurement isolating the layout itself.
4. **x64 codegen: confirmed, and it is the largest bucket, but not for the reasons I gave.**
   The hot loops make no calls and do not allocate, so cross-call register allocation and bump spills are not what they pay
   for. They pay for per-instruction selection:
   * comparisons turned into 0/1 values and then tested
   * jumps to the next block
   * `movabs` for small immediates
   * tag/untag/overflow checks on every Int operation, plus dead re-tags
   * frame spill and reload of values that are reused at once
   * a fuel tick in memory on every iteration of counted scans.

   Across apps, these classes make up 17–37% of all instructions. Inlining and closure calls
   matter in the runtime-heavy cases: MutMap's combine function and sortWith comparators.
5. **New: page faults and stack depth.**
   * Deep non-tail recursion in `String.words`/`String.lines`
     (see the regression below).
   * Linux `MADV_DONTNEED` on every freed block. With releases disabled, csv faults drop from 82.9 k to 44.3 k and wall time from
     0.711 to **0.627 s (−12%, 7 rounds)**; RSS goes from 170 to 174 MB.
   * Copy-out zeroes its targets with `memset`.

## wordfreq_mutmap memory regression (231 → 341 MB): explained

* aee9ce39 (2026-11-12, "Allocation sites, std/string, …") rewrote `String.words` from an
  accumulator plus `rev` into front-to-back cons recursion, meant to compile as TRMC.
* On x64 it does **not** become a loop: `fpr_fn_wordsGo` contains `call fpr_fn_wordsGo`, so the program builds
  2 M nested native frames, one per word. Each frame also pends a call region around its `wordEnd` call.
* The page faults are pushes at the top of fresh stack pages, from `call` in `wordsGo` and from
  `push` in `g_call_pend`: 46.9 k faults, 183 MB touched.
* Checks:
  * The same source built by the 57201f0 and b8518da compilers peaks at 231 MB.
  * On `main`, the app with an inline accumulator `words` (`raw/experiments/wordfreq_mutmap_accwords.fpr`) peaks at **231 MB**
    and takes 0.713 → **0.655 s**, with sys time 0.194 → 0.136 s.
  * Plain wordfreq also drops from 342 to 232 MB.
  * csv with an accumulator `lines` drops from 170 to 144 MB.
* Call regions are not the cause: `FPR_NO_CALL_REGIONS=1` leaves wordsGo recursive at 341 MB. **I did not find
  why TRMC misses `wordsGo`** (the `--remarks=all` output shows no TRMC remark for it).

## Ranked fixes

The gains below are shares of each app's wall time today. **Measured** means it was measured by an
experiment on this box; everything else is an **est.** from the instruction and time shares above. The gains overlap,
so they do not add up.

| # | fix | evidence | sim | csv | wordfreq | mutmap | treemap |
|---|---|---|---:|---:|---:|---:|---:|
| 1 | x64 peephole/selection: fuse compare+branch (no 0/1 materialization), jump threading, immediates instead of `movabs`, drop dead re-tags, keep loop values in registers instead of frame slots | class shares (upper bound on removable instructions: sim 37%, treemap 30%, csv/wordfreq 23%, mutmap 17%); IPC is equal to C, so fewer instructions ≈ less time | est. 25–35% | est. 15–20% | est. 15–20% | est. 10–15% | est. 20–25% |
| 2 | tight byte scans: `charFrom` as memchr; `wordEnd`/`isSpace` as a table or range test with one tick per loop, not per byte | 28 instructions/byte today; scans are 13–25% of time | – | est. 12–17% | est. 8–11% | est. 15–20% |  – |
| 3 | `String.words`/`lines` back to bounded stack (accumulator, or make TRMC fire) | **measured**: mutmap −8% wall, −110 MB; wordfreq −110 MB; csv −26 MB | – | ~0 (−26 MB) | ~0 (−110 MB) | **−8%** (−110 MB) | – |
| 4 | Linux heap release: `MADV_FREE` or retention hysteresis instead of `MADV_DONTNEED` on every free | **measured** with release disabled: csv −12% | – | **−12%** | ~0 | ~0 | n/m |
| 5 | region cost: no copy-out walk on owned (in-place) loops; skip call regions around callees that never take a slab (e.g. `wordEnd`); back off after declines | **measured** ablations: treemap copy-out off −16% wall and −17 MB; csv call regions off −3% (10 rounds; −11% in a 5-round run), instructions −6.2% | ~0 | est. 5–10% | est. 3–5% | est. 5–8% | **−16%** |
| 6 | MutMap: inline/specialize the known combine closure (no allocation per call); word-at-a-time string hash | 13.5% + 6.8% of mutmap's instructions | – | – | – | est. 12–18% | – |
| 7 | `std/hashmap` as a real hash table, or known-comparator specialization in `g_sortListWith` | treemap_hashmap `toMap` sort is 29% of instructions; walk +15% | – | (csv_hashmap) | – | – | (hashmap −30–40%, est.) |
| 8 | parse Int from a string range (`String.toIntRange`/a primitive) instead of substr+generic loop | 7.2% of csv time, about 528 instructions per number | – | est. 5–8% | – | – | – |
| 9 | string-slice views / non-materialized split | substr+alloc about 7% of csv time | – | est. ≤5% | est. ≤3% | est. ≤3% | – |
| 10 | align hot loop heads | identical instructions, 12% wall difference between two sim builds | est. ~10% | ? | ? | ? | ? |

For wordfreq with `std/map`, the remaining half of the gap is the ordered-map choice: it makes 24.9 M string
compares. Fix 7 (a real hash table behind `std/hashmap`) and fix 6 are the levers there, not codegen.

Suggested order: 3 and 4 first (each is small, local and measured); then 2 and 1 (the largest, and they share
the selection work); then 5, 6 and 7.

## Reproduce

Builds use `./fpr build -o bin-fpr/<w> tests/bench/apps/<w>.fpr`. The ablations set the existing switches
`FPR_NO_CALL_REGIONS=1`, `FPR_NO_LOOP_REGIONS=1` and `FPR_NO_PERSISTENT_COPY_OUT=1`; the `xflags` build sets
`FPR_TYPED_IR_{LOOP_MOTION,SHRINK_WRAP,FORWARD_PARAMS,FRAMELESS_ENTRY}=1` (no significant change).
The no-release build comes from `raw/experiments/no-release.patch`, which was applied only in a scratch
`FPR_HOME` and is not proposed as-is. The profiling helper scripts stayed outside the repo,
because `main` is Sol-only.
