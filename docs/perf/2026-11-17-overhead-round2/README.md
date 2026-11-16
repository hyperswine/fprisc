# Overhead elimination, round 2: runtime items (2026-11-17)

Follows `docs/perf/2026-11-16-overhead-audit` (plan rows R1-R8). This note covers what was measured for the runtime rows, what landed (R3, first part) and why R1, R4, R5 and R8 did not land in this round. The bench programs are in `bench/`.

Machine: Linux x86-64, 8 cores, 8 harts (the posix default). Wall and CPU (user+sys) times are medians of interleaved runs on an otherwise idle box. The run counts are given per row. Profiles are `perf record -F 2000..4000` cpu-clock samples. The base is `ari/vec-copy-alloc` (b33f466f): main plus C1, C3 and C10, whose changes are all in compiled code or `vec.c`.

## Benches

| program | shape | expected output |
|---|---|---|
| `pingpong` | 1,000,000 request/replies, two actors, placed by the scheduler | `pingpong = 500001500000` |
| `xpingpong` | the same, the ponger on hart 1 | `xpingpong = 500001500000` |
| `mhsend1` | one client/server pair (harts 0 and 4), 1,000,000 request/replies, each carrying a heap String (copied on send) | fixed checksum |
| `mhsend` | four such pairs (harts 0-3 to 4-7), 250,000 each | fixed checksum |
| `spawnchurn` | 25,000 waves of 8 spawn / request / reply / exit | `spawnchurn = 2500300000` |
| `fanin` | 16 senders on all harts into one receiver (9 of them through the shared ring), every message acknowledged | `fanin = 2403200160000` |

## R3: channel sender keys on a read-mostly line (landed)

In pingpong's profile `chan_for` was 12-16% of the samples. Most of those samples were on the compare right after the load of `ch[i].sender`. The key shared the producer's line with `rt`, so each lookup by the receiver (`chan_for`, `p_any`, `p_res`, `next_ready_channel`) pulled a line the producer had just written. The key now sits beside `rv0`, on a line written only when a slot is claimed or the channel is initialised. The inline slots start a line of their own. `chblk_t` grows by MAXSND x 64 bytes at most. Nothing else changes: same fields, same atomics, same claim protocol.

pingpong profile: `chan_for` went from 12.4% to 5.0% of the samples. Wall times are in the PR.

Not done:
- **A direct channel index.** With the keys on read-mostly lines, the scan is at most 7 compares against lines already in the cache. A per-sender slot hint would replace that with about as many loads, plus a validity check against slot reclamation.
- **A lock-free MPSC shared ring for the 8th and later senders.** In `fanin` (9 senders on the shared ring), `ring_push` including its `shlock` is 2.3% of the samples. The lock also orders `take_at`'s in-place shifting (selective receive removes from the middle of the ring), ring growth, the death check against reaping, and bounded-inbox charges. A Vyukov ring supports none of these as they are. The measured share does not justify redesigning them.

## R8: adaptive spin-before-block on by default (not landed)

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

## R5: lock-free freelists (not landed)

In `spawnchurn`, `fpr_fl_take` is 0.23% of the samples and `fpr_bkt_take` 0.41% (mostly its memset). The freelist spinlocks are uncontended there, so a lock-free or per-hart-cached freelist could save at most about that much. The same profile shows the cost that is really there: the per-spawn stack guard. `mprotect` and the TLB-shootdown IPIs it causes (`smp_call_function_many_cond` 6.3%, plus VMA work) are an order of magnitude more than the freelists. Keeping guarded stacks warm across spawns is the better next step. It is not in the plan yet.

## R4: per-hart Chase-Lev deque and admission clock (not landed)

The backlog is not a queue. Admission picks the oldest aged entry (the tier that carries the WCET bound `Wait(a) <= tau + ...`) or a weighted random pick among the rest. The aging compares stamps from one machine-wide clock, `g_adm`, and a stolen actor keeps its stamp. A Chase-Lev deque gives only its two ends, and per-hart clocks make stamps from different harts incomparable. Both change the scheduling model the WCET bound rests on, and this round keeps WCET semantics identical. No profile here shows `steal_from` or `g_adm` above 1% (`deq` is 2.3% of fanin).

## R1: the global arc_lock (measured; not landed)

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

## Pre-existing crash found while stress testing

`sleepmig2` (the R7 stress program from #81, `qf/rt/sleepmig2.fpr`) segfaults intermittently:

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
