# Allocation measurement: where allocations happen and what they cost

Date: 2026-10-27. The first step of 6b in
[steps 6-8: what remains](2026-10-27-STEPS-6-8-REMAINING.md): before
building an inline bump-allocation path, count allocations by pool and
caller, and time what they cost.

The two C changes below are now implemented; see
[the allocator fast-path note](2026-10-27-ALLOC-FAST-PATH.md) for the
implementation, regression coverage and follow-up measurements. The
counts, profiles and scratch timings on this page are the original pilot.

## Method

- **Counts.** A scratch copy of `runtime/runtime.c` counted every
  `fpr_alloc`/`fpr_alloc_bulk` call by caller (generated code or runtime C,
  from the return address through `dladdr`), by pool (the actor or hart
  pool, a bucketless compiler region, a `Sys.arena`), and by the path that
  served it (bucket reuse, big-free reuse, bump, bump after a slab refill).
  Each benchmark's output matched its `.expected` file.
- **Profiles.** `xctrace` Time Profiler on the unmodified runtime, one hart,
  1 ms samples. It recorded sha and pingpong; strbuild failed to record
  twice.
- **Timings.** Fastest of seven runs, one hart, Apple M4 at load average
  2-3, comparing the unmodified runtime with two scratch variants. The
  compiler was the same throughout (main at `2a44c44`).

## Where allocations happen

| Benchmark | Allocations | Where |
|---|---|---|
| sha | 4,587,961 | 98.5% generated code in compiler regions; 1.5% generated code in the actor pool |
| strbuild | 3,020,009 | 33% generated code in compiler regions; 67% runtime C (string building) in compiler regions |
| pingpong | 1,001,070 | 100% generated code in compiler regions (one per message) |
| xpingpong | 1,000,736 | 100% generated code in compiler regions |
| byteloop | 100,004 | 96% generated code in compiler regions |
| vecread | 74 | setup only |
| nbody, helpers, fib, floatcmp, specialization, mixed_locals | 2-5 | none in the hot path: their loops run unboxed |

Bucket reuse almost never happened (one call in strbuild, one in sha),
and big-free reuse never did. Nearly every allocation was a plain bump,
in actor pools as well as regions. The plan's expectation that
allocation matters for nbody and helpers was wrong: they do not allocate.

## What it costs

sha (114 samples): `nth` 43.9% (the O(n) list indexing in `std/digest`),
`alloc_in` 11.4%, `fpr_alloc` 2.6%, `_platform_memset` 6.1% and its
`bzero` stub 2.6%. The `memset` comes from `alloc_in` zeroing the rounding
pad with a call even when the pad is a single 8-byte word.

pingpong (193 samples): the allocator is 0.5%. The time is in the
scheduler (`block_unless` 15%, `hart_loop` 9%, `deq` 8%, context
switches) and in copying messages (`dc_size_in` 8%, `dc_dup` 6%).

Timings:

| | unmodified | pad zeroed with one store | plus a C fast path for regions |
|---|---|---|---|
| sha | 108.2 ms | 102.9 ms | 100.3 ms |
| strbuild | 74.4 ms | 73.9 ms | 72.0 ms |
| byteloop | 83.2 ms | 83.5 ms | 83.0 ms |

In a separate run of the first two columns: sha 106.6 -> 100.0 ms,
strbuild 72.9 -> 70.9 ms, byteloop unchanged.

- **Pad store:** when the pad is one word, store a zero instead of calling
  `memset` (all three places in `alloc_in`). Worth 3-6%.
- **C fast path:** at the top of `fpr_alloc`, when the current pool has no
  buckets (a compiler region), the size is under the bucket ceiling and
  the current slab has room, bump directly: header, pad, `allocated` and
  the region clock, skipping the bucket and big-free checks. About another
  2.5%. Region trips and refills still take `alloc_in`.

## Conclusion

The inline path would remove only what remains after these two changes:
the call, the hart lookup, the override-slot indirection, and the register
traffic around the call. The pilot suggests a limited marginal win, but
does not establish an upper bound for inlining. It would cost a native ABI
revision (the hart's bump window), runtime write-back points (C allocation, region
open/cycle/close, override changes, actor switches) and code in three
backends. **Deferred:** not worth building now. Revisit if a workload
shows generated allocation in regions as a larger share of its time than
sha does.

## Next steps

In order:

1. **The two C changes are implemented** in `runtime/runtime.c` (the pad
   store and region fast path). See the linked validation note. No compiler
   or ABI change.
2. **`std/digest` indexes a vector, not a list.** `nth` is 44% of sha; it
   is the largest single cost in any benchmark here.
3. **The parked receive loop is already fixed** in `4f56c95`; see
   [the retention and analysis note](2026-10-27-PARKED-RECEIVE-AND-ANALYSIS.md).
4. **pingpong's costs are the scheduler and message copying**, not
   allocation: the next work there is the copy (`dc_size_in`/`dc_dup` on
   each send) and the block/wake path.
5. Then 7b (splitting at loop boundaries) and 8 (tick amortization) as
   designed, each measured first.

The instrumented runtime was a scratch copy and is not checked in.
