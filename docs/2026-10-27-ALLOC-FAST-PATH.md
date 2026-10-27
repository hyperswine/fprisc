# C allocator fast path

Date: 2026-10-27. Implements the two C changes identified in the
[allocation measurement](2026-10-27-ALLOCATION-MEASUREMENT.md).

## Change and boundaries

`alloc_zero_pad` replaces `memset` with a zero-word store when rounding
leaves exactly `sizeof(uw)` bytes. Other padding sizes still use `memset`.
The helper covers bump allocation, small bucket reuse and exact-fit
big-block reuse. Payload bytes remain untouched, apart from the existing
big-free link-word clearing. Word alignment is sufficient; buddy-backed
slabs are not guaranteed to start on a 16-byte boundary.

`fpr_alloc` bumps directly when the current pool has no buckets, the raw
size is at most the small-block ceiling minus the header, and the current
slab has room. The raw-size check precedes rounding. The shortcut writes
the same headers and padding, advances the same slab pointer, and charges
the same pool allocation gauge, region clock and optional cost counters.

Bucketed pools, large blocks and refills still use `alloc_in`, preserving
bucket reuse, big-free reuse, fixed-heap exhaustion and pending-region
trips. `fpr_alloc_bulk` continues to allocate in the base pool and never
charges the region clock. No compiler change, native ABI revision, hart
layout change or codegen revision is needed.

## Regression coverage

`tests/check_alloc_fast.py`, registered in Base, adds a C probe to a
temporary runtime copy. A thread-local counter proves eligible requests
avoid `alloc_in`, while reuse, bulk allocations and actual slab refills
enter it. Production code contains no test hook.

The probe checks poisoned byte/word pads, untouched payloads, hidden
headers, exact fits, fixed pools, both sides of the bucket ceiling,
bucket and big-free reuse, bulk isolation, real region refills, pool
gauges, the region clock and cost counters. It runs on one and four harts,
with cost probing off and on. The original runtime fails the dispatch
assertion, as expected.

Alignment sanitization of the changed `runtime.c` and its probe passes.
Instrumenting every runtime translation unit instead stops during channel
setup at `runtime/actors.c:755`: a `chblk_t` needing 16-byte alignment is
backed by an address eight bytes off that boundary. This reproduces with
the original allocator before the probe starts and is a separate existing
alignment issue. The focused result is not a whole-runtime sanitizer pass.

That channel issue is now fixed separately; the
[channel alignment note](2026-10-27-CHANNEL-ALIGNMENT.md) records the carve
correction and focused workloads with all runtime C alignment-instrumented.

All 144 Base jobs passed across the initial four-worker run and follow-up
runs. The initial run passed 65 jobs, then the four-hart live runner timed
out waiting 20 seconds for `fpr watch` to exit. That check passed in
isolation (40 seconds total); the remaining 79 jobs, including a repeat of
the finalized allocator probe, passed in a resumed four-worker run (278
seconds). The initial failure is not a clean first-attempt suite pass.
Runtime and compiler sources stayed frozen throughout validation.

## Paired measurements

Apple M4, macOS AArch64, Apple clang 21.0.0, the same compiler at
`2a6a098` (codegen 135) throughout. Each variant changes only `runtime.c`:
the original, padding stores only, and padding plus the C bump shortcut.
Runtime objects use the normal `-O2` flags, compiled for four harts;
benchmarks run on one hart except xpingpong on four. Cost probing is off.

Each binary gets one untimed warmup, then 12 measured runs. The six
variant orders each occur twice; benchmark order rotates between rounds.
Every run matches its expected stdout, exits successfully and has empty
stderr. No builds or tests run alongside the measurements. Other host
activity remains: sampled CPU idle is 67.5% before and 70.7% afterward.
This is not a quiet-machine qualification.

Times below are best / median, in milliseconds:

| Benchmark | Original | Padding only | Plus bump shortcut |
|---|---:|---:|---:|
| sha | 120.5 / 122.6 | 113.6 / 116.4 | 108.7 / 112.9 |
| strbuild | 87.5 / 92.9 | 87.5 / 90.3 | 83.3 / 92.4 |
| byteloop | 90.9 / 91.8 | 90.2 / 92.1 | 90.2 / 92.1 |
| pingpong | 194.9 / 199.2 | 195.1 / 197.2 | 191.7 / 195.1 |
| xpingpong | 354.1 / 364.0 | 349.4 / 363.2 | 344.9 / 358.3 |

SHA's median paired change is -4.9% for padding, another -3.7% for the
bump shortcut, and -8.7% combined; its aggregate median falls 7.9%.
Strbuild's paired combined change is -3.1%, but its aggregate median is
almost unchanged, so that result is less stable. Byteloop is unchanged
within noise (+0.4% paired); pingpong and xpingpong have small paired
changes (-2.6% and -0.9%) that do not establish an isolated scheduler or
message-copy improvement.

[Raw samples and provenance](../bench/2026-10-27-alloc-fast.json) include
runtime/compiler/binary hashes, sizes, execution order, CPU snapshots and
the Base coverage across all three validation runs. No global performance
baseline is replaced.
