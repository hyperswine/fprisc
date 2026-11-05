# Finite Base field-worker expansion

The results below qualify the initial codegen-191 compiler. The subsequent
[shape-prefilter refinement](2026-11-05-FIELD-SHAPE-PREFILTER.md) preserves
emitted code and reduces the recorded high-arity compile time; it has a separate
compiler identity and validation record.

Codegen 191 replaces the field pass's fixed round, helper-count and Core-body
cutoffs with structural progress and finite forwarding closure. It also
combines private guard chains during expansion, retaining their entry fuel.
The purpose is to remove remaining product allocations without accumulating
unnecessary fallback bodies or changing the public tagged contract.

## Admission and termination

The previous limits were four expansion rounds, three forwarding rounds,
128 field helpers, an 8,192-node source scan and a 1,024-node cloned body.
Field expansion now uses the finite set of parameter projection paths in each
function. The analysis follows lexical aliases and projection-bound lets.
Duplicating an existing branch does not invent a new path; an unknown call or
join supplies no projection evidence.

Each round records an explicit source-to-worker relationship. Every source
has at most one child. A child's projection-path rank cannot increase, and
the sum across the new frontier must strictly decrease. Only that new frontier
can expand in the next round. A round without this proof is discarded intact
and produces a diagnostic note. Forwarding closure monotonically adds names
from the current finite program, so it needs no separate depth/count cutoff.

These are termination conditions, not substitutes for semantic admission.
Checked nominal/closed-product evidence, compatible constructor calls,
projection bounds, binder/capture checks, whole-value escapes and the original
guarded fallback contract still apply. The physical 64-argument limit remains.
The unchanged compiler-cost gates and applicable final target-image limits
remain resource checks. This pass does not impose a new percentage code cap.

## Combining guard chains

A private entry can disappear only when its recorded lineage identifies the
parent that calls it and that call is its sole reference. Its guard and
projection-only arguments join the parent's guard; the parent's original body
remains the failure path. The field-expansion contract establishes that this
body is equivalent to the child's fallback under the parent's successful
guard. Shared, recursive and escaping private entries retain their own bodies.
Substitution is simultaneous, so retained parameter names cannot capture each
other's argument expressions.

Every removed entry contributes an explicit entry-fuel tick, conditional on
its parent's guard succeeding. A wrong outer value therefore avoids inner
entry ticks, while a valid outer value with a wrong inner payload still gets
the same ticks before its fallback. Combining guards happens after each
accepted round, so later rounds do not scan the discarded fallback chain.
Public arities, dynamic values and module calling conventions remain tagged.

## Qualification

The native regression covers five/eight/sixteen nested wrappers, eight through
sixty-four independent wrapper arguments, 129 independent helpers, and large
helper bodies above both former body thresholds. Each has an explicit payload
control and field-worker rollback, with isolated allocation counts plus normal
region execution on one/four runtime workers. Semantic cases check argument
order, effects, integer endpoints, overflow at both limits, division by zero
and an invalid nested actor payload. Independent IR tests specify fallback
answers and conditional fuel counts, and ensure a shared intermediate stays
available.

The saved codegen-188 compiler and codegen 191 each pass 77 recorded
allocation/semantic rows. At 1,000 iterations (except the independent-helper
case, which calls each helper once), constructor requests are:

| Shape | Saved compiler | Current compiler | Explicit payload control |
| --- | ---: | ---: | ---: |
| Five / eight / sixteen nested wrappers | 1,000 / 4,000 / 12,000 | 0 | 0 |
| Eight / sixteen / thirty-two / sixty-four arguments | 4,000 / 12,000 / 28,000 / 60,000 | 0 | 0 |
| Eight-result helper | 4,000 | 0 | 0 |
| 129 independent helpers | 1 | 0 | 0 |
| Bodies with 256 / 2,048 additions | 1,000 / 1,000 | 0 | 0 |

See the [saved](../bench/2026-11-05-finite-field-workers-before.json) and
[current](../bench/2026-11-05-finite-field-workers.json) records. Normal region
execution also passes; counters are measured separately from throughput.

At twenty million calls with sixteen wrapped arguments, the
[native arm64 benchmark](../bench/2026-11-05-finite-field-workers-throughput.json)
reduces allocations from **240,116,960 to zero**. Median time falls from
**600.60 to 267.81 ms**, versus **268.03 ms** for the explicit helper, with
**13/13** paired wins: **55.41%** less elapsed time. The current and explicit
medians are effectively equal in this sample. No other qualification or
compilation ran during these measurements.

## Compiler and code cost

All **41 Haskell suites** pass. The unchanged absolute compiler-allocation
gates pass at **1.61 / 32.80 / 67.51 GB** for hello / std-live / pos1.
The existing C2 specialization scaling gate retains exact assembled-code and
function-count parity through 256 helpers, at approximately 1.000–1.001x
compiler allocation against explicit twins.

Field-worker scaling has a different public contract: each original tagged
entry remains alongside its private payload entry. The
[helper-count experiment](../bench/2026-11-05-finite-field-workers-helper-cost.json)
therefore grows by two functions per helper, versus one for the explicit
payload program. At 256 helpers the old compiler skipped half the workers;
complete coverage increases root text from **686,608 to 885,980 bytes** and
compiler allocation from **15.75 to 18.68 GB**. This is linear function growth,
not code-size parity with the smaller explicit public interface.

Combining guards during expansion substantially improves the
[high-arity case](../bench/2026-11-05-finite-field-workers-parameter-cost.json),
but does not finish its compiler-cost work. At 64 arguments, root code falls
from **69,788 to 26,184 bytes**, with one final private worker instead of four.
Cold compiler allocation nevertheless rises **3.67 → 6.82 GB**, and time rises
**3.10 → 16.04 s**. The explicit payload source uses 1.70 GB and 0.78 s.
This is a recorded optimization hotspot, despite passing the ordinary absolute
gate. The superseded uncoalesced experiment used 41.25 GB and 154.70 s for
this case; per-round compaction prevents scanning its growing fallback chain.

## Scheduling evidence and unresolved latency

The [host scheduling matrix](../bench/2026-11-05-finite-field-workers-scheduling.json)
covers **153 configurations and 117,504 plain-runtime responses**, with separate
instrumented fuel, placement and progress checks. New cases exercise eight
nested wrappers and sixteen live arguments through the public guard, including
spill slots across conditional fuel ticks. All logical checks pass.

The matrix records **four responses above the observational 1 ms threshold**,
all in message copying with four harts and one remote competitor; the maximum
is **7,969 us**. A
[focused alternating saved/current comparison](../bench/2026-11-05-finite-field-workers-copy-latency.json)
then records 13,312 responses per compiler. Both have a 139 us median, but
the saved compiler has no observations over 1 ms (maximum 427 us), while the
current compiler has twelve (maximum 11,781 us). These outliers are retained.
The comparison does not establish their cause. A successful harness exit
means answers and measurement contracts passed, not that a latency target
was met. Scheduling qualification remains open.

A [fresh binary comparison](../bench/2026-11-05-finite-field-workers-copy-code.json)
finds identical addresses and sizes for all eight file-backed sections. The
only instruction difference is the module loader's compiler-revision check
(188 versus 191); the only other section differences are interface-version
strings. This workload does not load modules. The compared binaries are fresh
builds, not the original timed executables. This is evidence against attributing
the timing difference to changed copy-workload instructions; it does not
identify the cause of the outliers or turn host sampling into a time bound.

The [validation manifest](../bench/2026-11-05-finite-field-workers-validation.json)
binds the compiler and inputs to these results. Native host measurements do
not establish physical-board latency or general static-arena admission.
Broader Base storage remains separate work. Recursive and mixed types staying
boxed is part of the agreed representation policy, not an implicit requirement
to unbox every recursive structure.
