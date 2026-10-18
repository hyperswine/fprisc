# Runtime allocation: first measured reduction

Date: 2026-10-18. Kind: measurement and implementation report. Applies to
FP-RISC `d398f63` plus this page's byte-string runtime change, on branch
`codex/runtime-copy-20261018`. The Liveboard source is QOS `796198d`.

The first optimization shares the 256 possible immutable one-byte Strings.
`chr` keeps its type/range checks and returns a static value instead of
allocating. In the measured 100-session Liveboard workload this reduced
median allocation requests by 35%, allocated bytes by 24%, and peak RSS by
26%. This is a first milestone in the compiler/runtime efficiency work;
general graph-copy sharing, additional unboxing and allocation reuse are
still candidates, not implemented by this patch.

## Why start here

The initial hypothesis was that actor message copies amplified session
memory. Existing `FPR_COST_PROBE` counters showed a different balance:
the first 100-session baseline requested 66,387,174,032 bytes of allocations,
but only 296,042,560 copied bytes. Copying accounted for less than 1% of
cumulative allocated bytes in this run. The arena held about 100 MiB at
the snapshot; cumulative allocated bytes are not retained/live bytes.

A five-second macOS CPU sample showed busy stacks in
`std/encoding.fpr:hexGo`, `std/view.fpr:localStage`/`localRule`, `strcat`,
`fpr_alloc`, and `fpr_g_chr_call1`. Typed local CSS uses hexadecimal names
and repeatedly encodes/decodes declarations while rendering. `hexGo` is
linear in the input length, but previously allocated two one-byte Strings
and two list nodes per source byte. It still allocates the list nodes.
The sample identifies hot stacks, not a precise byte total per call site.

## Implementation and semantics

`runtime/runtime.c` holds a read-only 256-entry table with the same header,
length and byte layout as `str_t`. A compile-time assertion checks the
payload offset. Its size is 6 KiB on 64-bit targets and 4 KiB on RV32.
There is no heap cache, lazy initialization, lock or eviction policy.
In the measured Mach-O server binaries the total file size increased by
32 bytes (layout/linker padding absorbed most of the table); that is not
a general guarantee about image size.

The finite byte domain includes NUL and 255. Invalid types and values
outside 0..255 still fail with the same messages. `String` has value
semantics; sharing its immutable representation changes no string result
or permitted program observation. `SString` and Vector ownership are
unchanged. The compiler's existing conservative `chr` allocation bound
remains an upper bound. No layout, function signature or ABI changes.

A table linked into a mortal QOS process image is not immortal. The
existing foreign-image static-data copy path must copy the byte before
that image can disappear. Both a poisoned fake image test and a real QOS
process unload test cover this boundary.

## Paired results

Three sequential runs per variant, alternating order, on native macOS
arm64. Both frozen binaries used four workers, `FPR_HEAP_MB=2048`, and
`FPR_COST_PROBE=1`. Clients joined at 1, 10, 50 and 100 sessions. At each
checkpoint the existing Mem action returned the profiling snapshot.
Every one of the 100 clients then had to observe a shared `Bump 989789`.
All six runs passed that functional check.

Medians at 100 sessions:

| Metric | Before | After | Reduction |
|---|---:|---:|---:|
| Allocation requests | 1,016,465,256 | 659,329,588 | 35.14% |
| Cumulative allocated bytes | 66,807,821,536 | 50,517,177,056 | 24.38% |
| Peak RSS | 975.9 MiB | 718.7 MiB | 26.35% |
| Arena reserved at snapshot | 99.5 MiB | 99.1 MiB | 0.38% |
| Cumulative session admission time | 5.208 s | 4.806 s | 7.70% |

Peak RSS ranges were 917.4–1005.7 MiB before and 694.7–747.8 MiB after.
The steady arena reservation barely changed. The gain is reduced allocation
churn and transient resident memory, not a demonstrated reduction of each
session's retained state. Allocator/page behavior contributes to RSS;
neither RSS nor arena reservation is a logical-live-object census.

The snapshots occur during concurrent work, so copy counts and total work
vary with scheduling. Counters are cumulative and their per-worker reads
are not an atomic global heap snapshot. Admission time covers opening
clients and receiving their first frames, excluding the explicit settling
waits and the final fanout check. These timings are instrumented: they do
not establish an uninstrumented production speedup.

All per-run 100-session counters and executable SHA-256 hashes are saved
in [the measurement data](../bench/2026-10-18-byte-strings.json).
Raw intermediate snapshots, binaries and the CPU sample remain under
ignored `build/session-*` directories in this worktree.

## Verification

- `python3 tests/check_byte_strings.py`: all 256 values; direct/generic
  calls; zero primitive allocation requests; concatenation, slicing,
  hexadecimal and Base64 round trips; direct pooled values sent/kept across
  actor death; negative/overflow/type failures; fake-image poisoning and
  unload. One and four workers passed.
- `python3 tools/runtime-costs.py --quick --runs 1`: existing allocation,
  message-copy and receive-turn contracts passed.
- `python3 tests/check_viewcache.py`: complete cached/fresh/stateless
  Logbook and pagination/session tests passed. Its outdated expected
  `Live.serveProjectedBody` source spelling was updated to `UI.body`.
- `python3 tests/check_rv64_linux.py`: Unix/QOS/module lowering and cache
  isolation passed. This invocation does not execute Linux binaries.
- RV32 freestanding compilation of `runtime/runtime.c` passed; no RV32
  execution or FPGA programming was performed.
- QOS `tools/native-integrity-check.py` on an isolated archive of QOS HEAD:
  ABI/integrity rejection and real vector-process execution passed in RV64
  QEMU, with legacy/modern virtio and one/two harts.
- A second run of that QOS harness substituted
  `tests/base/byteproc.fpr` for `vectorproc.fpr`. The kernel checked byte
  255 after `Sys.images 0` reached zero and printed
  `process=[byteproc: 255] images=0 allocations=1 HOLDS`. All four QEMU
  configurations passed. This specifically tests the actual byte table in
  a relocated, subsequently unloaded process image.
- QOS Portable rebuilt against this runtime hosted `byteproc.qa` on macOS
  with one and four workers. Both exited successfully and returned byte 255.

QOS test sources/builds were isolated under `build/qos-runtime-check`;
the sibling QOS checkout and its dependency lock were not modified by this
work. The full Base suite, FreeBSD, STAR64 and Pi deployment were not run.
This does not establish that the earlier 1,000-session FreeBSD OOM is fixed.

## Reproduce the session probe

From this FP-RISC checkout:

```sh
python3 tools/session-memory.py --qos ../qos \
  --sessions 1 10 50 100 --output /tmp/session-pool
```

Use a fresh output directory. `--sample` adds a five-second macOS CPU
sample. `--binary /absolute/path/to/liveboard-probe` reuses a matching
previously built probe for interleaved comparisons. The output records
binary/source hashes, the current checkout's runtime patch and counters.
With a prebuilt binary, that patch describes the current checkout, not
necessarily the binary's build provenance; retain its original build and
source records. The baseline here was built before changing the runtime,
at `d398f63`, with the same benchmark hook and Liveboard source.

## Next priorities

1. Attribute the remaining ordinary allocations. Avoid repeated typed-CSS
   encoding/decoding and temporary list materialization; assess a linear
   builder or an equivalent compiler rewrite. `localStage` also repeatedly
   concatenates suffixes. Preserve output order and error behavior.
2. Measure retained actor/session state separately from cumulative work.
   This patch did not reduce the approximately 100 MiB arena reservation.
3. Revisit immutable DAG sharing in transfer/keep only when its measured
   benefit warrants it. Keep fallible inbox/entry admission bounded and
   preserve resource ownership and foreign-image lifetimes.
4. Extend unboxed specialization and dead-allocation reuse on representative
   workloads. Existing specialization/fusion already covers selected cases;
   do not weaken effect, failure-order or value-semantics guarantees.
