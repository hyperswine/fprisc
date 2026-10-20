# Wider tuple and record accumulator workers

Kind: implementation and physical-target validation record.
Applies to the `codex/wide-workers-20261020` changes on FP-RISC
`01772b4`, code-generation revision 52. Extends
[the two-field worker pass](2026-10-18-PRIVATE-WORKERS.md).

## Behavior

A recursive function with one fixed-width tuple or record accumulator can now
carry its fields as separate private arguments. For example, a loop over
`(sum, count, low, high)` uses a worker with four field parameters. A final
explicit tuple/record result is still constructed once. Public arities,
function values and module entry points retain the general ABI.

The expanded worker can have up to 64 total arguments: eight argument registers
and 56 existing per-hart spill cells. A loop with one counter therefore supports
up to 63 accumulator fields. Wider expansions retain the general implementation.
This pass splits one outer product per function; nested products remain values.
Fields retain their ordinary `V` representation unless the separate scalar
worker pass also qualifies. That scalar pass still has its existing eight-argument
admission limit.

Record projections can test multiple shapes that share a field name, with
different field offsets in each shape. Shape inference now prefers a unique
constructor reconstructed by a saturated recursive call. The public wrapper
checks that shape before splitting fields. Only branches excluded by that known
shape are removed from the worker; the general entry retains its original
fallback, including behavior for other shapes. Mixed constructor widths and
reachable out-of-range projections decline optimization.

Direct call rewriting requires a saturated statically known function and a
matching literal constructor of the proven width. It preserves field and
argument evaluation order. Unknown calls and whole-value escapes retain general
behavior. Shadowed recursive names/parameters decline selection. Public wrappers
also permit entry through ordinary function values and separately built modules.
Vector callbacks and their reachable helpers remain excluded. The existing
RV32, Builtin, ARC and Sol policy is unchanged.

Admission examines at most 8,192 Core nodes per candidate function, allowing
record shape dispatch chains, and limits both the shape-narrowed body and the
actual expanded worker body to 1,024 nodes. The latter includes expansion of
whole-accumulator forwarding. At most 128 field workers are added per unit.
Code-generation revision 52 invalidates prior unit caches; native ABI version
and runtime interfaces are unchanged.

## Validation

`tests/check_wide_workers.py` generates deterministic fixtures with 3, 4, 8,
16, 63 and 64 fields for both tuples and records. The records deliberately share
field names so their shape dispatch and differing offsets are exercised.

The native matrix covers both inliner settings, all four independent field/scalar
worker settings, an off/on/off cache cycle, and one/four runtime harts. It checks
results, allocations, function-value calls, managed String field rotation,
actor-message ownership, 10,000 non-tail frames, ordered effects, and a panic in
a late constructor field that must suppress subsequent effects. Emission checks
cover RV64, A64, x64 and RV32, private descriptor exclusion and finite fuel
segments. A separately built optimized shared module is called by a host built
with both worker passes disabled. A Builtin ARC fixture verifies fallback.

`tests/Workers.hs` additionally checks exact parameter ordering, distinct field
names, public arity, conflicting widths, invalid projections, lexical shadowing,
whole-value escapes, vector exclusions, the 64-argument boundary and expansion
of forwarding within the clone-size budget. Existing worker, specialization,
register allocation, wide-parameter and vector-kind suites cover surrounding
behavior. The complete Base suite is not part of this validation.

Physical tests run Linux ARM64 binaries on the Raspberry Pi 4 at `192.168.0.233`
and Linux RV64 binaries on the STAR64 at `192.168.0.215`, with strict pinned SSH
host identities. Each tests workers off, field workers only, and both workers on,
with one and four runtime harts. Executables are checksummed after upload and
removed after testing. Tests run alongside the existing QOS installation; this
is compiler/runtime coverage rather than a QOS application redeployment.

## Measurements

On macOS ARM64, Pi 4 and STAR64, each supported 10,000-iteration tuple and record
case (3, 4, 8, 16 and 63 fields) drops from **10,002 allocations to one** final
result allocation. For eight fields that is **960,192 bytes down to 96 bytes**;
for 63 fields, **5,281,056 bytes down to 528 bytes**. The 64-field-plus-counter
case exceeds the 64-argument worker ceiling and correctly stays at 10,002
allocations. These are allocation totals, not resident memory measurements.

Final physical-target medians, milliseconds:

| Board | Fixture | Workers off | Workers on | Speedup |
|---|---|---:|---:|---:|
| Pi 4 | tuple3 | 258.10 | 60.67 | 4.25x |
| Pi 4 | record3 | 320.99 | 60.79 | 5.28x |
| Pi 4 | tuple8 | 428.98 | 109.70 | 3.91x |
| Pi 4 | record8 | 762.14 | 109.31 | 6.97x |
| Pi 4 | tuple16 | 643.94 | 218.36 | 2.95x |
| Pi 4 | record16 | 1105.21 | 218.06 | 5.07x |
| STAR64 | tuple3 | 187.10 | 50.47 | 3.71x |
| STAR64 | record3 | 226.48 | 51.67 | 4.38x |
| STAR64 | tuple8 | 335.13 | 93.87 | 3.57x |
| STAR64 | record8 | 483.42 | 94.20 | 5.13x |
| STAR64 | tuple16 | 537.18 | 161.60 | 3.32x |
| STAR64 | record16 | 711.13 | 161.40 | 4.41x |

Each board passed 174 correctness/error subprocess checks (58 per optimizer mode),
plus 60 uninstrumented timing executions. Both one- and four-hart runs passed.
Final native suites and board tests were rerun after adding the expanded-clone
budget guard; executable hashes identify the final artifacts.


The timing witnesses run one million iterations, one runtime hart, allocation
counters disabled, five alternating off/on samples per case. They compare both
workers disabled against both enabled. Each result is checked. They run with
normal board services active and are microbenchmarks, not a claim about whole
QOS GUI speed. Records benefit from eliminating both reconstruction and repeated
shape dispatch. Allocation counters come from separate 10,000-iteration builds.

Raw sample arrays, allocation ledgers, source and executable hashes, and test
status are in [the evidence file](evidence/2026-10-20-wide-accumulator-workers.json).
Local build and physical execution logs are retained under
`qos/.qos/validation/allocation-20261018/wide-workers-20261020`.
