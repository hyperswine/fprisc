# Guarded String scan range proof

This implements the string-scan follow-up to the early-loop experiment. It is
opt-in with both `FPR_TYPED_IR_EARLY_LOOPS=1` and
`FPR_TYPED_IR_STRING_SCAN=1`. The new flag participates in the shared unit and
executable cache identity; codegen revision is 141. Default compilation is
unchanged. Loop invariant motion remains an independent option.

## Contract and proof

`Codegen.StringScan.versionScan` runs after the existing interval simplifier.
It admits one natural loop with an entry preheader, a pure header testing
`i >= n`, an invariant string and bound, and a concrete managed String byte
read at `i`. Every incoming loop edge must carry exactly `i + 1`, computed
in the region dominated by the `i < n` body edge. The body edge must have a
single predecessor, and the exit and body destinations must differ.
Functions larger than 24 blocks or 160 instructions are left unchanged.

The dispatch checks that the first iteration is active, `i >= 0`, the value
is a String, and `n <= strlen(s)`. Any miss enters the original checked CFG
with its original arguments. A zero-trip call never inspects the String.
The fast copy preserves the original operation order and all fuel ticks.
It removes repeated type and bounds branches and immutable length reloads.
Single-predecessor straight-line blocks are merged afterward so the removed
guards do not leave a chain of unconditional jumps.
It retains the String value as the byte address source in each iteration,
rather than carrying an unrooted interior pointer across safepoints.

Induction: the dispatch establishes a nonnegative initial index. Within the
body, `i < n <= strlen(s)` proves the byte is in bounds. Since `n` fits the
signed Int domain, `i < n` also proves `i + 1 <= maxInt`; adding one cannot
wrap or make the next index negative. All backedges are checked. The proof
never assumes that arbitrary callers pass zero or the actual string length.

Accumulator arithmetic stays checked. Inclusive bounds, non-unit strides,
changing limits/strings, unsupported loop shapes and non-managed/32-bit
profiles retain their existing checks. The existing interval pass may
independently discharge the guarded index increment; range versioning also
works with that pass disabled and leaves its checked increment in place.

## Validation

- `tests/StringScan.hs`: 2,500 evaluator cases compare exact results, trap
  messages and event sequences; independent sum, zero-trip and overflow
  assertions exclude vacuous evaluator agreement. Additional cases check
  multiple backedges, refusal boundaries, option composition and idempotence.
- `tests/check_string_scan.py`: native bounds/trap/output comparisons with
  inlining on/off and one/four harts, switching range mode off/on/off within
  one cache. The traced native fixture disables region wrapping and asserts
  that its scan actually has both versions. A64 and x64/Rosetta execution
  agree exactly. Includes negative indices, oversized limits, empty and invalid
  strings, nonzero starts, accumulator overflow, and maxInt counter boundaries.
- Emission checks cover A64, x64 and RV64 fast copies; RV32 stays unchanged.
  RV64/RV32 coverage here is emission only.

## Benchmark method

`tools/bench-string-scan.py` builds all fixtures before measuring, uses two
warmups and 15 paired runs with a seeded balanced order, checks exact output
on every execution, and records compiler/source hashes, allocation, binary
size and native function headers. Both modes use early loops; invariant
motion is off. A saved pre-change compiler independently checks each output.
The original workloads are lengthened, with short and partial scans added
to expose entry-guard overhead and nonzero-start behavior.

Results are recorded in `bench/2026-10-31-string-scan.json`. This document
does not claim hosted CI, physical RISC-V execution, or a speedup outside the
measured workloads.


## Local results (final revision 141)

| Workload | Off median ms | On median ms | Median paired runtime reduction | Faster pairs |
|---|---:|---:|---:|---:|
| byteloop-long | 935.12 | 689.33 | 24.74% | 15/15 |
| sha-long | 977.10 | 970.42 | 0.38% | 8/15 |
| helpers-long | 1071.06 | 1050.44 | 0.11% | 8/15 |
| floatcmp-long | 581.36 | 606.51 | -0.62% | 7/15 |
| short-scan | 133.10 | 107.08 | 17.55% | 15/15 |
| partial-scan | 967.97 | 657.61 | 31.72% | 15/15 |

The reduction column is the median of the 15 within-pair reductions, not a
ratio of the two marginal medians. All three scan workloads won every pair.
SHA, helpers and float comparison produced byte-identical root assembly and
unchanged executable sizes; their sub-1% paired changes are treated as noise.
This is a consistent improvement for the admitted scans, not a general native
compiler speedup.

Compile allocation increases 1.85–2.93% across these fixtures. The scan
executables grow from 538,088 to 554,600 bytes (+3.07%); the controls are
unchanged. `sumB` retains its 48-byte frame and has no spills, reloads or stores
in either mode. The tiny scan is eight bytes, not a zero- or one-byte workload.

The first exploratory version retained jump chains after deleting guards. It
improved the long scan only 3.61% and slowed the tiny scan 10.50%. Straight-line
cleanup is part of the final implementation and all reported final tests and
timings were repeated after it. The saved pre-change compiler validates output
only; the timings isolate the new pass within the final compiler.

The new pass remains opt-in. Next useful work is a profitability policy for
very short/zero-trip calls and a cheap applicability screen to reduce compile
cost on functions without String reads. General caller-fact propagation and
register-pressure improvements remain separate work.

The local validation record is
[`docs/evidence/2026-10-31-string-scan-validation.json`](evidence/2026-10-31-string-scan-validation.json).
It includes seven focused Haskell suites plus the typed-IR runner's scalar
vector suite, 160 native exact-output/trap comparisons, and typed-IR,
byte-string lifetime, interval, early-loop/fuel and registry regressions.
This is focused validation of revision 141, not a rerun of the complete Base
suite previously recorded for the early-loop slice.
