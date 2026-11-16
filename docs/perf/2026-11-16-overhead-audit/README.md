# Compiler and runtime overhead audit, 16 November 2026 (WIP notes)

Kind: measurement notes and scratch, on the branch `ari/overhead-audit-2026-11-16`. Not a design decision.
Compiler, runtime and std: `origin/main` at **18fce327** ("Open 0.15.0-dev"). Measured on the **Linux x86-64** box
(Debian trixie, 8 vCPU VM, no hardware PMU). Every 14-15 November record was measured on an Apple M4 or under Rosetta;
none of them was timed on Linux x86-64, so these are the first x86-64 numbers for that work.

Method:

- Wall time: `tools/timeit.py.txt`, interleaved FP-RISC / C runs, median of 5 (apps) or 3 (CLBG), stdout md5 compared
  (all 16 programs match C). RSS comes from `wait4`, and the child's figure includes the forked Python's footprint
  (about 17-42 MB), so only the large FP-RISC values mean anything.
- Instructions: `valgrind --tool=callgrind --dump-instr=yes` gives exact counts. `tools/classify.py.txt` joins each
  executed instruction with `objdump` and puts it in a rough class (fuel, tag/untag, overflow check, frame, ...).
  The classes come from a regex heuristic, so treat them as approximate shares.
- C is `cc -O2` (gcc 14). The apps inputs (`sales.csv` 15.8 MB, `corpus.txt` 19.3 MB) are the 14 November profile's.
- Callgrind sizes for CLBG are reduced where the default would take minutes under valgrind: nbody 500k steps,
  spectralnorm 1000, mandelbrot 1000, binarytrees 16. The rest use their defaults.

## 1. Where we stand (ratios against C)

| program | wall fpr / C | instructions fpr / C | 14 Nov x64 instr ratio (3485b92f) |
|---|---:|---:|---:|
| sim | 0.177 / 0.039 s = 4.5x | 3.573 G / 0.722 G = 4.95x | 9.3x |
| csv | 0.456 / 0.036 s = 12.7x | 4.452 / 0.278 = 16.0x | 21.3x |
| wordfreq (std/map) | 0.927 / 0.097 s = 9.6x | 4.888 / 0.475 = 10.3x | 13.5x |
| wordfreq_mutmap | 0.418 / 0.093 s = 4.5x, RSS 231 MB | 2.462 / 0.475 = 5.2x | - |
| treemap (std/map) | 0.856 / 0.126 s = 6.8x | 2.087 / 0.286 = 7.3x | 11.0x |
| treemap_mutmap | 0.350 / 0.120 s = 2.9x | 2.324 / 0.286 = 8.1x | - |
| records | 0.786 / 0.230 s = 3.4x | 2.328 / 1.146 = 2.0x | - |
| format | 0.652 / 0.226 s = 2.9x, RSS 394 MB | 2.814 / 2.565 = 1.1x | - |
| binarytrees | 0.828 / 1.113 s = 0.7x | 0.60x | - |
| fannkuchredux | 0.889 / 0.199 s = 4.5x | 10.4x | - |
| nbody | 1.165 / 0.221 s = 5.3x | 6.7x | - |
| spectralnorm | 1.102 / 0.195 s = 5.7x | 6.8x | - |
| mandelbrot | 2.567 / 0.991 s = 2.6x | 3.2x | - |
| fasta | 0.604 / 0.328 s = 1.8x | 5.6x | - |
| knucleotide | 1.202 / 0.252 s = 4.8x, RSS 216 MB | 8.1x | - |
| revcomp | 0.305 / 0.064 s = 4.8x, RSS 129 MB | 6.6x | - |

Geometric means: CLBG wall **3.2x** C on x86-64 (the 0.14.0 record gives 2.4x on the M4), CLBG instructions 4.8x,
apps wall 5.1x, apps instructions 5.2x. Since 14 November the app instruction counts fell 26-47% on x86-64.

## 2. Hot loops at HEAD (x86-64, from callgrind plus the disassembly; listings in raw/hotloops)

- **sim** (`$worker.spineE.loop.$loop.in.run`, 98.5% of instructions): **88 instructions per particle-step**, against
  about 18 for the whole C program (0.722 G / 40 M). The loop already reuses the cell in place and allocates nothing.
  What remains:
  - 12 for the cons test, which materialises a Bool with `sete`/`movzbq` and then tests it again;
  - 9 for a dynamic layout check before the in-place write (tag bit, type id, variant), on a cell whose layout is
    statically known;
  - about 16 for untag and retag (`sar`, `lea 1(x,x)`) and four `shl`+`jno` overflow checks;
  - 7 frame spills and reloads, 3 for the fuel tick, and several redundant `mov` chains.
- **wordfreq/csv byte scan** (`wordsGo`, 18% of wordfreq; `charFrom`, 14% of csv): **33 instructions per byte**.
  Removable work in every byte:
  - a loop-invariant "is this a String" check (6), plus re-untagging the length (2);
  - a second bounds check after the loop test has already done it (4);
  - the fuel tick (3), and an index carried both tagged and untagged.
- **treemap lookup** (`maplookup.getGo`): about 24 instructions per tree level. It re-untags the key on every level,
  loads all four node fields eagerly, and ticks fuel.
- **treemap insert** (`mapown.walk.insGo`, 72%): about 160 instructions per level, a non-tail recursion. Of the 301
  hot instructions, 46 are frame loads and stores.
- **mandelbrot** (`inSet`, 92%): 45 instructions per iteration, of which only 9 are float operations. 21 are
  `movq` between general and xmm registers, or `movabs` of a constant. **x64 has no float register class**: the
  "floats in float registers" change of 07cd2bca was A64 only (docs/2026-11-15-VECTOR-VIEWS-BUFFERED-OUTPUT.md §5).
- **nbody** (`advance`, 99%): about 328 instructions per body pair, against about 60 in C. Of those, 53 are gpr<->xmm
  moves, 64 are frame operations and 21 are inline bounds checks.
- **fannkuchredux**: 16% of instructions are in the C allocator, `alloc_in_size` (11.5%) and `free_block` (4.4%).
- **knucleotide**: 37% is in the C MutMap (`g_mutmapInsertWith` and `mm_find`), applying the closure through C.
- **Kernel page zeroing** (`clear_page_erms`, perf cpu-clock share): csv 20%, wordfreq 15%, wordfreq_mutmap **43%**.
  This is the cost of the footprint: memory touched once and never reused.
- **`g_strCompare` (C)**: 34% of wordfreq's time (18% of its instructions) and 9% of csv's.
- Copy-out walks (`kp_reaches`): 3.5% of treemap, 2.9% of wordfreq and 5.6% of wordfreq_mutmap instructions.
- **Fuel ticks**: still a TLS load plus a memory read-modify-write on x64 (`mov %fs:..,%r10; subq $n,(%r10); jg`).
  A64 (x27) and RISC-V (s11) keep the counter in a register since #67.

## 3. Actors (x86-64)

- `pingpong`, 1 M round trips on one hart: 0.977 s median, about **980 ns per round trip**.
- `xpingpong`, the same across two harts: 1.013 s.
- Both use about 2.1 s of user CPU for 1 s of wall time. The idle side spins: `block_unless` is 26% and `p_any` 10%
  of samples. `chan_for` (12%) and `fpr_send_as` (11%) lead the real work.


## 4. Runtime blocking points (source read at 18fce327)

`fpr_lock` (runtime/fpr.h:834) is a test-and-set spinlock with exponential `nop` backoff, not an OS mutex. "Spin"
below means that a holder preempted by the OS stalls every other hart that wants the lock. It is short, but it is not
lock-free.

| # | where | what | kind |
|---|---|---|---|
| 1 | runtime.c `arc_lock` (l.450): `fpr_arc_incref`, `arc_decref_in`, `fpr_arc_promote_share`, `fpr_arc_movable_root`, `msg_copy_held_in`, `arena_close`/`arena_reset`, `region_adopt*`, `g_poolReset` | one **process-wide** lock over the ARC table. Every non-immediate `send` that misses the inline small-message path increfs under it. So do `sendArc`, `sendLinear`'s movable-root probe, and the drop of every message from a promoted slab | spin, global |
| 2 | buddy.c `buddy_lock`; actors.c `fpr_mem_take` (l.4571) | buddy refill: `buddy_alloc_try` first (trylock). When the lock is busy, the request queues on the memory actor and **the actor parks** (`block_unless`). The per-hart `blkcache_t` (4 orders x 4) sits in front | spin + actor-blocking slow path |
| 3 | runtime.c `fpr_fl_take`/`fpr_fl_put` (l.455) over `grant_fl`, `bkt_fl`; actors.c `stack_fl`, `acb_unpublished` | the shared freelists | spin LIFO |
| 4 | runtime.c `free_block` (l.965) and the pool buckets/bigfree; inline bump in generated code | per-pool size classes, freed by CAS push; the bump window is hart-local | lock-free (CAS); bump wait-free |
| 5 | actors.c `ring_push` / `send_inline` (dedicated channel) | at most 7 dedicated SPSC rings per receiver (`MAXSND`=8); `chan_for` does a linear scan plus CAS | lock-free, wait-free when not full |
| 6 | actors.c `ring_push` on the shared ring (8th and later sender), any bounded inbox; `take_at` off-head | `a->shlock` | spin, per actor |
| 7 | actors.c `ring_push` growth | a full Dynamic ring doubles; its block may come from `fpr_mem_take` (row 2), taken outside the lock | can park the sender |
| 8 | actors.c `xpush` (l.1136) | cross-hart wake ring `xr[src][dst]`, XCAP=64; **busy-waits when it is full** | lock-free SPSC, blocking when full |
| 9 | actors.c `wake`/`ship`/`drain` | a CAS from BLOCKED to READY, then a local enqueue or `xpush` plus a doorbell | lock-free |
| 10 | actors.c `steal_from`/`backlog_add` (l.1252) | the victim's `bl_lock`, then an O(n) walk of a linked list that skips pinned, running and non-READY entries | spin, per hart |
| 11 | actors.c `g_adm` (l.1198) | machine-wide admission clock: a plain load and store from every hart (one shared cache line) | not blocking; a coherence hot spot |
| 12 | machine/unix/park.c `hal_wfi` | an idle hart spins 20 us (`FPR_SPIN_US`), then sleeps in `pthread_cond_timedwait` capped at 20 ms | blocking by design (idle only) |
| 13 | actors.c `block_unless` spin-before-block (`hal_block_spin_ns`) | spins while the hart is quiet; in pingpong it is 26% (plus `p_any` 10%) of samples, with 2.1 CPU-s for 1 s of wall time | burns CPU, never blocks |
| 14 | actors.c `a_sleep_us` (l.2537) | parked sleep on a per-hart list. It falls back to **`nanosleep` of the whole hart** when there is no actor, or when the actor is still linked on another hart's list (posix/hal.c `fpr_hal_sleep_us`) | actor-blocking; the fallback blocks the hart |
| 15 | actors.c timer `tmr_dl_get/set` | atomic on 64-bit; `tmr_dl_lock` on 32-bit | lock-free (64-bit) |
| 16 | actors.c spawn: `acb_block` (`acb_lock`), `stack_take` (`stack_fl`, `fpr_mem_take`) | refills happen outside the lock, but may park on the memory actor | spin, can park |
| 17 | actors.c `chb_lock` (channel-block limbo), runtime.c `img_lock`, `layout_extent_lock`, mod.c `xlock`/`layout_lock`, `pols_lock`, per-actor `watch_lock` | cold paths (reap, loading, policy, death watch) | spin |
| 18 | runtime.c `fpr_con_lock`, `log_lock`; posix/hal.c stdout | console lines go through stdio (the glibc FILE lock). A flusher pthread `fflush`es within 50 ms. `fwrite` into a full pipe blocks the printing hart | blocking |
| 19 | posix/os_io.c `Os.read`/`Os.write`/`Os.open`/`Os.seek` | raw syscalls on the hart. Readiness checks use `poll(...,0)` (`Os.ready`, `Os.poll`), but a read on a blocking descriptor (file, stdin, pipe) **blocks the hart** | blocking |
| 20 | posix/base_file.c `fileRead`/`fileWrite`; os_fs.c `Os.readFile` etc. | whole-file `fopen`/`fread`/`read` on the hart | blocking (disk) |
| 21 | posix/os_net.c `Os.connect`, `Os.listen` | `getaddrinfo` and a blocking `connect` on the hart (the code says so). After that, sockets are `O_NONBLOCK`. The async `os_resolver.c` and non-blocking `os_connection.c` exist alongside | blocking |
| 22 | unix/os_proc.c `Os.run` | fork/exec, then a `poll` loop and `waitpid` **for the child's whole lifetime, on the hart** | blocking |
| 23 | posix/os_job.c | a broker pthread for blocking platform calls; the result comes back as an IRQ | non-blocking for the hart |

## 5. Ranked remaining overhead sources

1. **Boxed, tagged scalars in hot loops.** This covers untag and retag, `jno` overflow checks, and record fields as
   tagged words. It is about 20% of sim's loop and is spread over every Int loop. Docs: "raw values in hot loops"
   is awaiting a representation decision (2026-11-15-CLOSURES-COPY-OUT-CLONES.md).
2. **x64 backend gaps behind A64:**
   - no float register class: about half of mandelbrot's loop, 16% of nbody's;
   - the fuel counter lives in memory through TLS;
   - Bools are materialised with `setcc`/`movzb`/`test`.
3. **Loop-invariant checks not hoisted, and redundant bounds checks.** In byte loops: the String type check, the
   length untag and a second bounds test. In vector loops: 21 bounds checks per nbody pair.
4. **Memory footprint turned into page faults.** Kernel `clear_page` is 15-43% of time in csv, wordfreq and
   wordfreq_mutmap. The causes are intermediate lists that are materialised (`words`, `lines`), and fresh pages that are
   never recycled within a run.
5. **String compare and hashing in C.** `g_strCompare` is 18-34% of wordfreq, `mm_str_hash`/`mm_find` 16% of
   wordfreq_mutmap, and the MutMap plus closure applies from C 37% of knucleotide.
6. **Frame spills in non-tail recursion and big loops.** These are 46 of 301 hot instructions in treemap's insert,
   and about 20% "frame" in nbody, fannkuch and knucleotide's lifted count.
7. **Out-of-line allocation in vector-heavy code**: fannkuch's `alloc_in_size`/`free_block` take 16%.
8. **Copy-out walks** (`kp_reaches`): 3-6%.
9. **Runtime message path.**
   - The global `arc_lock` is on every non-inline send.
   - `chan_for` scans linearly.
   - Pingpong costs about 980 ns per round trip, and the spin-before-block burns about 2x CPU.

## 6. Plan (prioritised)

Impacts are **estimates** unless marked measured. Each comes from the shares above. Effort: S = days, M = about a
week, L = several weeks.

### Codegen

| # | item | expected impact (why) | effort |
|---|---|---|---|
| C1 | **x64 float register class**: port A64's block-parameter floats in float registers (07cd2bca §5) and keep float constants in registers or a literal pool | 21 of mandelbrot's 45 hot instructions and 53 of nbody's 328 are gpr<->xmm moves or `movabs` (measured). Est. mandelbrot -35-45% instructions, nbody -15%, spectralnorm similar | M |
| C2 | **x64 register fuel** (A64 x27, RV s11 already have it, #67) and one tick per loop back-edge | removes a TLS load and a memory RMW per tick. The classifier counts 1-5% of instructions as fuel, more in byte loops (3 of 33 per byte). Est. 3-8% on scan-heavy apps | S |
| C3 | **Hoist loop-invariant type/tag checks and untags; drop bounds checks the loop test already implies** (interval facts exist in the typed IR) | wordsGo/charFrom 33 -> about 20 instructions per byte (est.), and those loops are 14-36% of csv, wordfreq, wordfreq_mutmap and revcomp. nbody's 21 bounds checks per pair: most index a fixed 5-body vector | M |
| C4 | **Branch on the flags, never on a materialised Bool, in x64** (the `setcc; movzb; test; jcc` pattern; the A64 fix of 233 was partial on x64) | 12 -> 3 instructions on sim's cons test, est. -10% of sim's loop, and it appears in most variant tests | S |
| C5 | **Static reuse without the dynamic layout check** when Reuse.hs proved the cell's constructor | 9 of sim's 88 instructions (measured), est. -10% on reuse loops | S |
| C6 | **Raw (unboxed) Int/F64 fields and loop-carried scalars**, with overflow checks only where exact Int can actually overflow (needs Jack's representation decision) | untag/retag/`jno` is about 20 of sim's 88; with C4+C5 sim est. 88 -> about 40 per element (2.2x C). Applies to every Int-heavy loop | L |
| C7 | **Streaming `words`/`lines`/`split` into consumers** (fusion or an iterator form), so the list is never built | wordfreq_mutmap's 43% kernel page clearing and 231 MB RSS come mainly from the materialised 2 M-word list (est. about 110 MB of cons + strings, unmeasured) | M |
| C8 | **Inline string compare (length, then a word-wise prefix in generated code) and a direct-call MutMap fast path** (combine closure called from generated code, not `fpr_apply2` in C) | strCompare is 18% of wordfreq's instructions; the MutMap and apply paths are 37% of knucleotide | M |
| C9 | **Register allocation: shrink-wrapped saves and live-range splitting in non-tail recursion** | 46 of 301 hot instructions in treemap's insert are frame operations, and about 20% elsewhere. Est. -10-15% on treemap and nbody | M-L |
| C10 | **Inline vector allocation and reuse of a dead linear Vector** (fannkuch) | 16% of fannkuch's instructions are in `alloc_in_size`/`free_block` (measured) | S-M |
| C11 | Copy-out cost: sizing walk only on the region that actually grew (`kp_reaches`) | 3-6% (measured share) | S |

### Runtime

| # | item | expected impact | effort |
|---|---|---|---|
| R1 | **Replace the global `arc_lock`** with an atomic count in the slab or preheader (or a table sharded by slab) | the only process-wide lock on the message path; send, sendArc and drop scale per object instead of per process. Throughput gain unmeasured; needs a multi-hart send benchmark first | M |
| R2 | **Take blocking I/O off the harts.** Route `Os.read` on blocking fds, `fileRead`/`readFile`/`fileWrite`, `Os.connect`/`Os.listen` (`getaddrinfo` + connect), `Os.run` and stdout flushing through a reactor (epoll/kqueue; io_uring later) plus the existing job broker (os_job.c). Actors park; harts never wait | removes every hart-blocking syscall in rows 18-22. Without it, one slow file, DNS lookup or child process stalls every actor on that hart | M-L |
| R3 | **MPSC lock-free shared ring** (Vyukov-style) instead of `shlock` for the 8th and later senders and bounded inboxes; a hash or direct slot index instead of `chan_for`'s linear scan | `chan_for` is 12% of pingpong; servers with more than 7 clients go through a spinlock | M |
| R4 | **Chase-Lev deque per hart for READY actors**, replacing the locked linked backlog walk in `steal_from`, and a per-hart (not global) admission clock | removes `bl_lock` and the O(n) scan; `g_adm` stops bouncing one cache line between harts | M |
| R5 | **Lock-free freelists** (tagged-pointer Treiber stacks, or per-hart caches in front) for grant, bucket, stack and acb; more per-hart buddy block cache depth | removes spinlocks from spawn and refill | S-M |
| R6 | **`xpush` overflow without spinning** (a per-hart overflow list) | no hart waits on another hart's drain | S |
| R7 | **Sleep never blocks the hart** (migrate the sleeper record, not a `nanosleep` fallback) | removes the remaining hart-blocking sleep | S |
| R8 | **Adaptive spin-before-block by default** (`FPR_ADAPTIVE_BLOCK_SPIN` exists, default 0) | pingpong burns about 2 CPU-s per wall-s; adaptive spinning should cut idle CPU with little latency cost (needs measurement) | S |

Suggested order:

1. C2, C4, C5, R6, R7: small and independent.
2. C1, C3, C10: x64 parity and check hoisting.
3. R2 and R1: non-blocking and scalable.
4. C7, C8, R3, R4, R5.
5. C6 and C9, after the representation decision.
