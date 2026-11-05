# Checked Base product parameters

Codegen 187 adds a checked-layout consumer to Base's guarded field-worker
pass. A nonrecursive helper can receive the fields of a freshly constructed
product directly, even when the helper is too large for ordinary inlining.
This removes an allocation at a real call boundary. It does not require eager
whole-program type cloning.

## Representation and boundary contract

The immediate shape comes from checked constructor declarations or a closed
tuple/record type: nominal type ID, constructor variant and ordered field count.
Generic fields remain ordinary tagged Base values, including strings and
lists. Open record rows and multi-variant types do not acquire a canonical
product plan. A missing or inconsistent constructor layout prevents a plan.
No raw payload interpretation is inferred from an observed caller.

Physical parameter identities travel with this evidence. Region-generated
entries with different binders/arity are excluded; compatibility specialization
explicitly transports the original entries' alpha-renamed binders. It does not
inherit evidence into callback clones or borrowed imported definitions. Module
cache identities include the relevant checked plans, even when erased
projections are otherwise identical.

The original entry keeps its arity and tagged argument contract. It checks the
nominal tag before projecting fields and calling a private worker; a mismatch
executes its original body. This matters in Base: a message can carry a value
whose runtime type differs from the receiver's source-level expectation.
Public module calls and dynamic function values keep their general convention.
Private helpers remain owned by the artifact that contains their definitions.

The new nonrecursive admission requires a compatible local constructor call,
at least one field projection, valid projection indices, and the existing
capture/whole-use, expanded-arity, clone-size and vector-callback checks. It
uses the existing worker budgets, separately from C2's checked type-instance
policy. Existing recursive/forwarding workers retain their guarded fallback
path when no canonical checked plan is available.

Strict argument and field order, overflow checks, effectful unused fields and
fuel calls remain. Fresh let-bound products bind their fields at the original
construction point before intervening effects. Escapes requiring the original
object remain boxed. `FPR_NO_FIELD_WORKERS=1` rolls this path back;
`FPR_NO_TUPLE_SCALARS=1` disables the new nonrecursive admission. Disabling
constructor inlining can leave constructor calls boxed, as before.

## Evidence

The source matrix uses ordinary inlining and deliberately large helpers that
remain calls. At 1,000 iterations:

| Workload | Saved codegen 186 | Codegen 187 | Explicit payload |
| --- | ---: | ---: | ---: |
| One-field Int helper | 1,000 | 0 | 0 |
| 2/4/8-field tuple helper | 1,000 | 0 | — |
| Closed record helper | 1,000 | 0 | — |
| Generic String helper | 1,000 | 0 | — |
| Generic list helper | 1,002 | 2 | — |
| Helper loop inside its owning imported module | 1,000 | 0 | — |

These are constructor requests with region adapters disabled only for count
isolation. The same source cases also run under normal region placement with
one/four runtime workers. The two surviving list cells are the payload itself.
The public cross-module fixture remains at two requests in both compilers.
A wrong-type actor message reaches the original fallback and returns `99`.

The regression matrix compares default, boxed, tuple-disabled and no-inline
execution for exact effects, failure text, division by zero, successful Int
endpoints and overflow at both limits. Independent machine-IR evaluation checks
valid and mismatched nominal/variant/scalar arguments. Compiler tests check
closed/generic evidence, open-row/sum refusal, stale binder refusal, explicit
renaming and cache identity sensitivity.

[Saved compiler results](../bench/2026-11-05-base-products-before.json) and
[current results](../bench/2026-11-05-base-products.json) retain compiler and
fixture hashes. Final throughput, scheduling and budget qualification is
recorded with the [validation manifest](../bench/2026-11-05-base-products-validation.json).

## Native throughput

At **20 million helper calls**, normal-region instrumentation reports
**20,009,766 → zero** constructor requests. Separate uninstrumented native
arm64 executables use ordinary inlining, warmup and thirteen alternating
samples. No other qualification or compilation ran during the timed samples.

| Form | Median time |
| --- | ---: |
| Saved codegen 186 | 198.05 ms |
| Checked helper worker | 187.47 ms |
| Explicit payload helper | 187.26 ms |
| Current compiler, field-worker rollback | 198.00 ms |

The new path wins **13/13** paired comparisons against the saved compiler,
with a **5.34%** median time reduction. Its measured median is **0.11%** above
the explicit helper. This arithmetic-heavy fixture demonstrates consistent
allocation removal and near-explicit throughput for this call shape; it is not
a general performance or zero-cost guarantee for every abstraction.
The [throughput record](../bench/2026-11-05-base-products-throughput.json)
includes every sample, source/compiler/runtime hashes and separate cost ledgers.

## Final qualification

All **41 Haskell suites and 15 qualification groups pass**. The saved/current
native matrices each contain 101 checked rows. Existing worker, wide-arity,
module, reset-barrier, open-row and materializing-pipeline regressions pass.
The ARC isolation check now rejects Base field/scalar workers specifically:
its older blanket `$worker.` assertion also rejected the already-implemented
ARC product workers under the saved codegen 186 compiler.

The unchanged compile-allocation ceilings pass at **1.60/32.76/67.40 GB** for
hello/std-live/pos1; std-live peaks at **502 MB**. The
[16–256-helper C2 gate](../bench/2026-11-05-base-products-cost.json) retains
exact assembled code/function parity and **1.000–1.001x** compiler allocation
against explicit monomorphic twins. No baseline or budget was increased.

The [scheduling qualification](../bench/2026-11-05-base-products-scheduling.json)
adds default/boxed nonrecursive helper workloads to the existing contention
matrix: **99 configurations and 76,032 plain-runtime responses**. Every
required competitor demonstrates fuel exhaustion and completed dispatches in
the instrumented runs. Plain runs observed a global maximum of **318 us**,
with zero observations above the 1 ms reporting threshold; the helper subset's
observed maxima were 169 us enabled and 203 us boxed. These are samples,
not deadline guarantees or a controlled latency-speedup claim. The deliberately
unbounded C control is detected, killed and reaped by the 3-second watchdog on
one/four runtime workers. The suite is registered in Base and host-extra CI;
this milestone's evidence is local execution, not a remote CI or board result.

## Scope remaining

This is canonical immediate-shape evidence and allocation removal for guarded
Base calls. Fields still use Base's tagged value representation. Broader Base
raw scalar/aggregate storage, recursive or variant layouts, arbitrary
cross-module private ABIs and general-application static arenas remain open.
The scheduling qualification is host evidence, not a physical-target latency
bound or WCET certificate.

The [codegen 188 extension](2026-11-05-BASE-PRODUCT-TREES.md) transports these
checked facts through multiple and nested worker steps. It keeps the existing
four-round limit and public tagged fallback contract.
