# Digest schedules: vector lookbacks

Date: 2026-10-27. Replaces the repeated list indexing identified in the
[allocation profile](2026-10-27-ALLOCATION-MEASUREMENT.md).

`std/digest` now builds each SHA-256 and SHA-1 message schedule in a linear
`Vector Int`, oldest word first. The four lookbacks in each expansion step
use zero-based `Vec.get` and thread the returned vector. `Vec.toList`
consumes the completed schedule for the existing compression rounds. The
public state, incremental, byte/hex and streamed-file interfaces are
unchanged. This removes both indexed list walks and the old schedule's
reverse-list construction; the measurements cover the combined change.

## Measurement

Apple M4, native AArch64, the same saved stage-1 compiler from `1db2556`
(codegen 135), the same runtime and build arguments, one active hart.
The benchmark hashes 1 MiB of `a`. Each binary received one untimed warmup,
then 20 alternating paired runs. Every run matched the existing expected
SHA-256 output, exited zero and had empty stderr. This task ran no builds
or other tests alongside the timings; existing host activity remained.

| Runtime | Best | Median |
|---|---:|---:|
| List schedule | 106.8 ms | 112.8 ms |
| Vector schedule | 66.6 ms | 69.2 ms |

The median paired reduction is **39.0%** (aggregate median reduction
38.7%). This is a local measurement, not a cross-machine guarantee.
[Raw pairs, source/compiler/binary hashes and CPU snapshots](../bench/2026-10-27-digest-vectors.json)
are retained; the global performance baseline is unchanged.

## Correctness

`tests/check_digest_vectors.py` compares SHA-256 and SHA-1 against Python's
`hashlib` for binary data at 18 padding, block and 64 KiB boundaries. It
also checks incremental updates with an empty middle update, and a binary
file crossing the 64 KiB streaming-read boundary. Exact outputs pass on
one and four harts. The check is registered in Base.
