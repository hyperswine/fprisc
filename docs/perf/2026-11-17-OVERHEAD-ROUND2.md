# Overhead elimination, round 2 (2026-11-17)

Follows the overhead audit of 2026-11-16 (branch `ari/overhead-audit-2026-11-16`, `docs/perf/2026-11-16-overhead-audit`, not on `main`), which ranked compiled-code rows (C) and runtime rows (R). Round 1 was #81. This note records the outcome of each row taken up in round 2, with the measured numbers, and why R1, R4, R5, R8 and both parts of R3 were not shipped. The bench programs used for the runtime rows are in `2026-11-17-overhead-round2/bench/`.

Machine: Linux x86-64, 8 cores, 8 harts (the posix default). Instruction counts are callgrind Ir, the median of 3 runs (at most 2 running at once), at the audit's sizes. Wall and CPU (user+sys) times are medians of interleaved runs on an otherwise idle box, with the run counts given per row. Profiles are `perf record -F 2000..4000` cpu-clock samples (the box has no hardware counters).

## Outcomes

| row | what | outcome | PR |
|---|---|---|---|
| C4, C5, R6, R7 (round 1) | x64 flag branches, cheaper reuse check, wake ring overflow, sleep off the hart | merged | #81 |
| C1 | x64 F64 register class, fused float compares | merged | #82 |
| C3 | String-scan versioning for a scan inlined into an outer loop | open | #83 |
| C10 | a Vector copy takes three blocks, not five | open | #84 |
| R3 (part 1) | channel sender keys on a read-mostly line | measured, not shipped: wall time regressed | - |
| R3 (part 2) | lock-free MPSC shared ring | deferred | - |
| R8 | adaptive spin-before-block on by default | measured, not shipped | - |
| R5 | lock-free freelists | measured, not shipped | - |
| R4 | per-hart Chase-Lev deque and admission clock | assessed, not shipped | - |
| R1 | replace the global `arc_lock` | measured and assessed, not shipped | - |
| C2 (fuel in a register) | | still deferred, as in `docs/2026-11-10-REGISTER-FUEL.md` | - |

Fuel and WCET semantics are unchanged by everything here. x64 tick weights are the rendered native instruction counts of the code a tick covers (`weighTicks`), so the fuel charged per tick moves with any x64 codegen change, as it did with #81; the mechanism and the WCET reference (simple-risc) are unaffected.

## C1: F64 values in xmm registers on x64 (#82, merged)

x64 gained a float register pool (xmm0-5 and xmm8-13, with xmm6/7 as scratch), float literals emitted as `.quad` data after the function, ordered float compares fused into branches (`ucomisd` plus `a`/`ae`), and direct xmm loads and stores of F64 vector elements. The fuel and allocation wrappers save the 12 pooled xmm registers. mandelbrot's `inSet` loop went from 50 to 35 instructions.

| program | before (main + #81) | C1 | change |
|---|---:|---:|---:|
| mandelbrot | 1246.8M | 872.2M | -30.0% |
| nbody | 2018.0M | 1863.3M | -7.7% |
| fasta | 1727.6M | 1617.5M | -6.4% |
| spectralnorm | 3773.4M | 3653.0M | -3.2% |

The other 12 programs moved by +0.2% or less. nbody still spills floats: the slow-path C calls of vector reads (`fpr_g_$vec.get.float_call2`) sit on joined paths, and there are no callee-saved xmm registers.

## C3: String scans inlined into an outer loop (#83, open)

`StringScan.versionScan` versioned only a scan that was a whole function. It now versions an innermost loop whose exits leave only through block parameters (plus empty exit-forwarding tails), so `wordsGo`'s inner loop runs its byte scan without the per-byte type test, length untag and second bounds check. Base is C1.

| program | C1 | C3 | change |
|---|---:|---:|---:|
| wordfreq_mutmap | 2369.2M | 2150.2M | -9.2% |
| wordfreq | 4697.7M | 4478.8M | -4.7% |

The other 14 programs moved by 0.2% or less. #83 was merged up with `main` (53a4d861) as codegenRev 241.

## C10: a Vector copy takes three blocks, not five (#84, open)

A copied column's storage now sits in the same block as its `col_t`, and the kind bytes sit right after the column directory, so `Vec.dup` of a one-column vector allocates three blocks instead of five. Only `runtime/vec.c` changes; no layout seen by generated code changes. Base is C3.

| program | C3 | C10 | change |
|---|---:|---:|---:|
| fannkuchredux | 10704.7M | 9699.4M | -9.4% |

fannkuchredux duplicates its permutation vector once per permutation. The other 15 programs moved by 0.3% or less.

## Runtime rows

The base for the runtime rows is `ari/vec-copy-alloc` (b33f466f): main at 18fce327 plus #81, C1, C3 and C10, whose changes are all in compiled code or `vec.c`.

### Benches

| program | shape | expected output |
|---|---|---|
| `pingpong` | 1,000,000 request/replies, two actors, placed by the scheduler | `pingpong = 500001500000` |
| `xpingpong` | the same, the ponger on hart 1 | `xpingpong = 500001500000` |
| `mhsend1` | one client/server pair (harts 0 and 4), 1,000,000 request/replies, each carrying a heap String (copied on send) | fixed checksum |
| `mhsend` | four such pairs (harts 0-3 to 4-7), 250,000 each | fixed checksum |
| `spawnchurn` | 25,000 waves of 8 spawn / request / reply / exit | `spawnchurn = 2500300000` |
| `fanin` | 16 senders on all harts into one receiver (9 of them through the shared ring), every message acknowledged | `fanin = 2403200160000` |

### R3: channel sender keys on a read-mostly line (not shipped; ring deferred)

In pingpong's profile `chan_for` was 12-16% of the samples. Most of those samples were on the compare right after the load of `ch[i].sender`. The key shared the producer's line with `rt`, so each lookup by the receiver (`chan_for`, `p_any`, `p_res`, `next_ready_channel`) pulled a line the producer had just written. The key now sits beside `rv0`, on a line written only when a slot is claimed or the channel is initialised. The inline slots start a line of their own. `chblk_t` grows by MAXSND x 64 bytes at most. Nothing else changes: same fields, same atomics, same claim protocol.

pingpong profile: `chan_for` went from 12.4% to 5.0% of the samples. But wall and CPU time went up, in two separate interleaved sets:

| program | runs | wall, base | wall, R3 | CPU, base | CPU, R3 |
|---|---:|---:|---:|---:|---:|
| pingpong | 11 | 958 ms | 1033 ms | 1901 ms | 2072 ms |
| pingpong | 21 | 974 ms | 1079 ms | 1957 ms | 2148 ms |
| xpingpong | 11 | 946 ms | 1034 ms | 1894 ms | 2077 ms |
| xpingpong | 21 | 1018 ms | 1101 ms | 2011 ms | 2198 ms |

Both sets have R3 about 8-11% slower. The cause has not been measured; a likely one is that the larger `chblk_t` spreads each channel over more lines, so a round trip touches more of them than it saves. The change was not opened as a PR. It is on branch `ari/chan-sender-line` (b030ae7d) for reference.

Not done:
- **A direct channel index.** With the keys on read-mostly lines, the scan is at most 7 compares against lines already in the cache. A per-sender slot hint would replace that with about as many loads, plus a validity check against slot reclamation.
- **A lock-free MPSC shared ring for the 8th and later senders.** In `fanin` (9 senders on the shared ring), `ring_push` including its `shlock` is 2.3% of the samples. The lock also orders `take_at`'s in-place shifting (selective receive removes from the middle of the ring), ring growth, the death check against reaping, and bounded-inbox charges. A Vyukov ring supports none of these as they are. The measured share does not justify redesigning them.

### R8: adaptive spin-before-block on by default (not landed)

The default flip (`FPR_ADAPTIVE_BLOCK_SPIN 1`, which halves the window after each expired spin, down to one probe) is a regression on the round-trip shapes. 11 interleaved runs each:

| program | wall, off | wall, on | CPU, off | CPU, on |
|---|---:|---:|---:|---:|
| pingpong | 962 ms | 1312 ms | 1908 ms | 2602 ms |
| xpingpong | 942 ms | 1491 ms | 1891 ms | 2996 ms |
| mhsend1 | 1604 ms | 2498 ms | 3211 ms | 5013 ms |
| mhsend | 990 ms | 956 ms | 7490 ms | 7097 ms |
| spawnchurn | 1556 ms | 1494 ms | 3239 ms | 2789 ms |

Once the window has collapsed, a waiter blocks on replies that would have arrived within the full window. Each block then costs a wake and a context switch, so CPU goes up, not down.

A variant that keeps at least a quarter of the configured window was roughly neutral (9 runs each): pingpong 927 to 943 ms, xpingpong 967 to 944 ms, mhsend 990 to 985 ms, spawnchurn 1548 to 1481 ms (CPU 3159 to 2821 ms). That is within the spread on every row except spawnchurn's CPU. It does not reach R8's goal of cutting pingpong's CPU: pingpong burns about 2 CPU-s per wall-s either way, and that comes from both harts spinning in `block_unless` (22-27% of the samples), not from the block window. The default stays 0.

### R5: lock-free freelists (not landed)

In `spawnchurn`, `fpr_fl_take` is 0.23% of the samples and `fpr_bkt_take` 0.41% (mostly its memset). The freelist spinlocks are uncontended there, so a lock-free or per-hart-cached freelist could save at most about that much. The same profile shows the cost that is really there: the per-spawn stack guard. `mprotect` and the TLB-shootdown IPIs it causes (`smp_call_function_many_cond` 6.3%, plus VMA work) are an order of magnitude more than the freelists. Keeping guarded stacks warm across spawns is the better next step. It is not in the plan yet.

### R4: per-hart Chase-Lev deque and admission clock (not landed)

The backlog is not a queue. Admission picks the oldest aged entry (the tier that carries the WCET bound `Wait(a) <= tau + ...`) or a weighted random pick among the rest. The aging compares stamps from one machine-wide clock, `g_adm`, and a stolen actor keeps its stamp. A Chase-Lev deque gives only its two ends, and per-hart clocks make stamps from different harts incomparable. Both change the scheduling model the WCET bound rests on, and this round keeps WCET semantics identical. No profile here shows `steal_from` or `g_adm` above 1% (`deq` is 2.3% of fanin).

### R1: the global arc_lock (measured; not landed)

The benchmark this row asked for is `mhsend`. With four pairs, the ARC paths take about 21% of the samples:
- `fpr_arc_incref` 9.5%, most of it spinning on the lock
- `fpr_slabs_unhold` 5.0%
- `arc_decref_in` 4.5%
- `arc_reserve` 1.2%
- `arc_slot_for` 0.6%

`mhsend` (4 x 250k) runs in a median of 990 ms wall, against 1604 ms for `mhsend1` (1 x 1M). Four pairs move the same number of messages only 1.6x faster.

`arc_lock` is more than the table's lock. It also orders the slab `owner`/`escaped`/`holds` protocol, which is taken by:
- `arena_reset` (every receive turn) and `arena_close`
- `region_adopt` and `region_adopt_state`
- `transfer_retire` and `slab_free_ownerless`
- the message-slab holds in `msg_build_cell` and `msg_copy_held_in`
- the remote `fpr_free` in `arc_decref_in`, whose comment relies on "owner read is death-race-free"

A sharded table needs every one of those slab-chain walks to take per-slab locks in a fixed order. Per-object counts need a header word, which is the ABI v2 the ARC comment mentions. Either way it is a redesign of the memory protocol, with the arc_churn gauges (`fpr_arc_cap`, compactions, grows) changing meaning. A plan, for a decision:
1. Make the slab counts (`holds` and `escaped` in one word) atomic, releasing when the word reaches zero and `owner` is clear, with a teardown that adds and drops a hold.
2. Shard the table by object address, with per-shard locks and gauges summed.
3. Decide whether a fresh message root needs a table entry at all. A sole receiver could hold it through the slab count alone.

## Pre-existing crash: intermittent sleepmig2 segfault

`sleepmig2`, a stress program written for #81's sleep change (R7), segfaults intermittently with rc=139, in about 1% of runs on an idle box:

| tree | runs | segfaults |
|---|---:|---:|
| 18fce327 (before #81) | 300 | 2 |
| 3dced95a (#81) | 200 | 3 |
| C1 | 200 | 2 |
| C3 | 200 | 0 |
| C10 | 200 | 3 |
| C10, interleaved with R3, box loaded | 400 | 17 |
| R3, interleaved with C10, box loaded | 400 | 12 |

The crash is older than #81 and isn't caused by these branches. It shows up more often under load. It has not been diagnosed: the box has no debugger. `sleepmig`, `xwake`, `fanin` and `xpingpong` had no failures in 100 runs each on R3.

### Repro

The program is `2026-11-17-overhead-round2/bench/sleepmig2.fpr`: 64 sleepers each sleep 100 us 300 times while three pokers send them 20,000 rounds of messages, so sleeping actors are woken early and stolen across harts. It must print `sleepmig: ok, 64 sleepers x 300 sleeps`.

```
fpr build -o sleepmig2 docs/perf/2026-11-17-overhead-round2/bench/sleepmig2.fpr
fails=0; for i in $(seq 300); do timeout 60 ./sleepmig2 > /dev/null 2>&1 || { echo "run $i rc=$?"; fails=$((fails+1)); }; done; echo "fails=$fails"
```

A failing run exits with rc=139 (SIGSEGV) and no output. Expect about 1 failure in 100 runs on an idle 8-core machine. It is more frequent when the box is loaded (12 to 17 in 400 in the interleaved runs above). Tree 18fce327 is the oldest checked, so the crash may be older still.
