# P0 corrections and the first P1 resource/editor consumer

Implemented locally, 9 November 2026. This delivers the first resource-summary
consumer for P1; it does not complete P1's general analysis manager or P2.

## P0 corrections

Semantic-policy Rule 3 no longer licenses floating-point reassociation from
non-trapping/total behavior. Reassociation, contraction and algebraic identities
need independent legality evidence, including rounding, NaNs and signed zero.

The baseline checker now fails gated metric drift on the same compiler binary
and host: configured scalar metrics beyond tolerance, zero-to-nonzero changes,
and changed recorded per-function facts. A changed compiler or host reports those
changes for review without gating them. Behavior, native coverage and finite
segment requirements still fail independently of compiler identity. Timing and
remark-stream changes remain informational. `check_baseline_gate.py` tests both
the comparison and actual command exit path; `make pipeline-baseline-check`
runs it before the corpus check. Existing baselines were not rewritten.

## Shared analysis and report

`Resource.Analysis.analyze` extracts declaration/coefficient handling, independently
verified result-size evidence and demand-driven cost orchestration from Compile.
Both CLI checks/reports and optional editor inference consume its typed results:
declarations, declaration errors, verified sizes, inferred equations and the
published equations callers compose against. Existing Cost transfer functions,
recursion handling and unknowns remain authoritative.

Editor analysis requests the current module's top-level roots and their transitive
dependencies, plus required contracts. It does not request unrelated imported
functions merely because they have types. Required contract checks finish before
optional inference and cannot be skipped by its budget. No assembly/link step or
hover-time compilation is introduced.

The editor envelope is version 2, with resource schema 1 and model
`native-source-v1`. Each resource entry carries its resolved declaration name,
source file and definition/signature anchor, parameter names, input predicates,
provenance, inferred/effective/declared work and allocation bounds. Bounds include
units, a structured expression, display text, proof/unknown status and unknown
dependencies. Integer constants use decimal strings to avoid JavaScript rounding.
Parametric callback costs remain symbolic, e.g. `2·work f + 2`; a proved symbolic
expression is a bound under its parameter/callback dependencies, not a closed
admission budget. A termination measure is not presented as an input precondition.

Work means abstract source-model operations. Allocation means cumulative requested
cell bytes. Peak live heap is not published by this first hover; stack is not
inferred and target time is unavailable. These are not final-code timing receipts,
physical allocator capacities, Sol VM costs or QOS scheduling guarantees.

The LSP appends these facts to native declaration hovers, including imported
references and declarations with signatures. Unknown dependencies stay visible;
declared promises appear separately from inferred implementation bounds. Sol and
builtin profiles do not publish this native resource analysis.

## Freshness, compatibility and budgets

The existing compiler-check cache owns report reuse. Actual consumed-source
fingerprints, compiler identity, arguments/environment and toolchain controls
remain its dependencies; manifests supplied to the native compiler are now also
included in editor inputs. Root/import edits, dirty buffers and toolchain changes
invalidate summaries with types. Cancelled/superseded jobs are discarded by the
existing checker; they publish no stale resource result.

The optional inference budget defaults to 1000 ms. For experiments,
`FPR_EDITOR_RESOURCE_BUDGET_MS` accepts 0 through 10000 (values are clamped; an
invalid value uses the default). Zero disables optional analysis. A timeout
publishes `budget-limited`, no resource rows, and ordinary types; the hover says
bounds are unavailable. The budget is a best-effort inference timeout, not a
wall-clock limit on checking, GC or JSON transmission. Whole-check cancellation
remains independent. Other report states are `complete`, `not-requested` and
`check-failed`; absence never denotes zero cost.

Version-1 compiler reports still supply types. Unknown resource schema/model
versions are ignored while preserving ordinary diagnostics/types. Invalid known
resource records are rejected. The updated compiler and LSP must be distributed
together for version-2 resource hovers.

## Validation and measurements

Passed locally:

- Compiler build and TypedProgram unit suite (including resource-cost/size rules).
- Full `npm test` LSP suite; focused reruns cover the final signature/definition
  matching and metadata changes.
- Resource editor tests: CLI equation parity, measured recursion, higher-order
  callbacks, allocation, unknown primitives, declarations, input domains,
  budget expiry, failed/unused contracts with a zero optional budget, native/Sol
  separation and schema compatibility.
- Real LSP resource hovers, dirty root/dependency suppression and shadowing;
  metadata tests cover warm-cache reuse and edits with restored modification times.
  Existing scheduling tests cover cancellation and superseded results.
- Resource-domain regression suite and the P0 baseline gate regression.

`tests/check_cost.py` reaches its existing `todo.view` equation-shape expectation
and fails there. A saved pre-change revision-204 compiler and the new compiler
produce byte-identical check-only cost reports for `examples/todo.fpr`; the saved
compiler also does not match that expectation. This suite is not claimed passing.

Three-run local medians using check-only/editor JSON and GHC `+RTS -s`:

| Source | Optional budget | Wall seconds | Allocated MB | Peak live MB | Resource status |
| --- | ---: | ---: | ---: | ---: | --- |
| cost_ho | 0 ms | 0.130 | 259 | 5.95 | budget-limited |
| cost_ho | 1000 ms | 0.261 | 435 | 8.21 | complete |
| todo | 0 ms | 3.457 | 6086 | 86.15 | budget-limited |
| todo | 1000 ms | 5.214 | 8110 | 86.15 | complete |

These measure complete saved-file checks, including report generation, on this
host; they are not compiler-budget qualification or universal latency guarantees.
The larger allocation overhead remains an optimization target. Warm LSP checks
reuse valid reports; hover requests themselves do not repeat analysis.

## Remaining P1 scope

This is the first vertical slice described by the
[resource/editor intent](2026-11-09-RESOURCE-INFERENCE-AND-EDITOR-INTENT.md).
It does not add persistent versioned compiler-unit summary metadata, a general
cross-pass preservation/remapping/invalidation manager, all six P1 analysis
domains, or a complete dependency explanation graph. It also does not add
unsaved-expression inference, call-site specialization in hovers, broader
recurrence proofs or hardware timing. Those remain in the
[pipeline roadmap](2026-11-07-PIPELINE-REFACTORING-ROADMAP.md) and
[resource/WCET roadmap](2026-11-07-RESOURCE-CONTRACTS-WCET-AND-QOS-ROADMAP.md).
