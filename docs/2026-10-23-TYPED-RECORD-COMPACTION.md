# Typed record compaction: hoisted bases and bounded strips

The typed record filter used to look up the column directory and column base
again for each copied field of every surviving row. Its predicate already
had hoisted bases for the fields it read, but compaction did not reuse them.

The native kernel now caches a prefix of the descriptor's proven columns,
up to 16, and copies that prefix with those bases. The prefix length is
`min(16, highest predicate column + 1)`: the existing width guard proves
those columns exist. Cached indices and predicate indices share one base
map, so an already-hoisted pointer is loaded only once at setup. Empty
vectors bypass the directory exactly as before.

The prefix's stores retain column order and copy raw words: unused boxed,
F64 and F32 fields are preserved without interpreting their bits. A filter
still preserves row order and every column. There is no new allocation,
vector layout field, ownership transfer or runtime entry point.

## Fuel and dynamic width

A counted safepoint charges the prefix's column ticks before the strip.
There is no callback or checked arithmetic inside the strip, and its cap
bounds the native segment. The remaining dynamic-width loop retains one
safepoint per copied column. Checked predicate operations still execute in
source order before any row is moved. Tail columns beyond the cached prefix
still load their bases dynamically; this increment does not claim complete
hoisting of an arbitrarily wide descriptor.

The first attempt retained one fuel fast path for each unrolled store.
Its 31-pair measurement did not justify promotion: the discard-heavy case
was neutral and the broader record workload regressed by 2.6%. The final
counted strip avoids those repeated fast paths. Both sets of measurements
are retained, including the discarded source patch.

Codegen revision **80** separates the final output from both the previous
default (78) and the discarded first attempt (79).

## Paired measurements

Native AArch64, this Mac, 31 pairs against the preserved `bcd523d` compiler.
Every executable is built before timing; no compiler/test sweep ran during
the pairs. Host background activity and frequency remain uncontrolled.
These measurements establish these workloads on this host, not other
architectures, boards, or a general speedup.

| Workload | Baseline median | Final median | Median paired ratio | 95% bootstrap interval |
|---|---:|---:|---:|---:|
| Discard 90%, predicate sums all nine fields; filter only | 12.490 ms | 12.345 ms | 0.9813 | 0.9647–1.0126 |
| Discard 90%, predicate reads field `f8`; filter only | 6.058 ms | 4.038 ms | 0.6709 | 0.6573–0.7005 |
| Existing record map/captured-map/filter/fold workload | 8.940 ms | 8.317 ms | 0.9318 | 0.9253–0.9379 |

The all-field predicate case is within timing noise. The sparse predicate
case improves by 32.9%, and the broader record workload by 6.8%; both are
faster in all 31 pairs. The new discard workloads fill one million rows
before timing, keep exactly 100,000, and verify the answer after timing
with a fold over every field. Setup and verification are excluded from the
internal clock. Both compiler variants use the same source, runtime and
settings; the new workloads require strict native compilation.

## Correctness and coverage

The independent record oracle covers 9, 64 and 300 columns, lengths 0–99,
1,500 map/filter/fold cases on each of x64, QOS-x64, RV32 and RV64,
source-order overflow, guard fallback,
and caller-register/hart-cell clobbers at yields. Its wide sparse-predicate
case now uses distinct opaque words for unread fields, including signed
zero, NaNs, extrema and pointer-like bits. The logical field `z299` is
physical column 222 under canonical sorted-name order; identical old column
data had hidden that oracle assumption. The strengthened check verifies
all 300 copied columns, including cached and dynamic columns.

The full kernel gate also covers 500 mixed Int/F64 record cases, F32,
scalar/fused/write-back kernels and one/four-hart execution on the real
hosted runtime. The Base sweep runs this gate on native AArch64, independent
x64/QOS-x64 code under Rosetta, and RV32/RV64 under QEMU. Rosetta is an
execution oracle here, not native x64 performance evidence.

The complete Base sweep passed **118 jobs in 445 seconds**, with the existing
SoftFloat runtime explicitly supplied for the RV32 software execution legs.

QOS's actual strict native admission gate still passes at 312 selected
instructions and 67 static runtime call sites per function: 1,669 functions,
27 assembly files, 7,763 total static runtime call sites. These remain
per-function regression metrics; they are not an elapsed-time certificate.

Logs, sample data, source/compiler hashes and discarded-attempt evidence
are in [the evidence folder](evidence/2026-10-23-record-compaction/).
The full migration goal remains open: arbitrary-width compaction costs,
fused SIMD pipelines, large hosted frames, remaining kernel refusals and
legacy-generator retirement still need their respective acceptance gates.
