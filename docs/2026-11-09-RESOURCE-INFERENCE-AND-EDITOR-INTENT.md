# Resource inference and editor integration

Date: 9 November 2026. Original intent baseline: `f2351e2`. The initial native
resource-report and hover slice is now implemented locally; see the
[implementation record](2026-11-09-RESOURCE-EDITOR-IMPLEMENTATION.md) for scope,
validation and remaining work. The broader intent below remains the target.

## Intended experience

Every supported function can expose inferred resource information alongside its
type, without requiring the programmer to write a bound first. A declared bound
remains an interface promise checked against the implementation. The goal is the
tightest sound upper bound the supported analysis can establish, not a guarantee
of finding the mathematical least upper bound for arbitrary programs.

The editor should distinguish inferred implementation bounds, published contracts,
assumptions and unknown dependencies. Unknown means the compiler lacks a proof;
it does not mean the function necessarily diverges or consumes infinite resources.

Proposed hover, using a bound the current analyzer already derives:

```text
lsum : List Int -> Int

Inferred resources:
  Work:        <= 6 * (length(l) + 1) abstract operations
  Allocation:  0 requested bytes
  Stack:       not inferred
  Target time: unavailable
```

For higher-order functions, retain symbolic callback dependencies:

```text
twice : (a -> a) -> a -> a
  work  <= 2 * work(f) + 2
  alloc <= 2 * alloc(f)
```

These are resource summaries of checked functions. Implement them as a cooperating
analysis, not by forcing resource arithmetic into ordinary type unification.

## Units and claims

| Quantity | Meaning and reporting rule |
| --- | --- |
| Work | Portable abstract operations in the current cost model; never label as cycles |
| Allocation | Cumulative requested cell bytes; distinguish from physical allocator capacity |
| Live heap | Peak retained storage under an explicitly stated lifetime model; omit unsupported claims |
| Stack | Separate target/native analysis; zero allocation does not imply constant stack |
| Complexity | Optional asymptotic upper-bound summary derived from a proved expression; not a tight Theta claim |
| Cycles/time | Only from qualified target/runtime evidence associated with the applicable executable/configuration |

Preserve parameter domains, size relations and callback argument dependencies.
Report multiple size variables rather than collapsing them into an unexplained
`n`. An `O(n)` work result is valid only under the displayed assumptions about
callback cost and element size. Initially show symbolic equations; defer general
asymptotic classification until its supported expression rules are tested.

The current ns-per-operation manifest supplies an assumption-based estimate. If
displayed later, label it as such; it is not a hardware WCET certificate.
Execution time and QOS response time are separate quantities.

## What exists and what needs integration

`compiler/Cost.hs` already computes work, allocation and conservative live
equations, including supported verified recursion and callback costs.
`compiler/Resource/ResultSize.hs` supplies independently checked size facts.
`compiler/Compile.hs` checks declared contracts and prints `--cost` reports.
Unsupported recurrences, sizes and primitive costs remain explicit unknowns.

`compiler/Compiler/Editor.hs` provides the structured `--editor-json` route.
`lsp/server/server.js` already displays inferred top-level types after successful
saved-file checks and suppresses stale information after source/dependency edits.
Use that route, rather than scraping human-readable cost output or compiling on
each hover. Native inference results must not be presented as Sol VM costs.

## Implementation slices

### I1. A reusable resource-analysis result

Extract orchestration from the reporting path into a reusable analysis entry.
Return structured equations, units, domains, declared/effective/inferred bounds,
proof status, unknown dependencies and source identities. Reuse Cost and verified
size rules; do not create a second estimator inside the LSP.

Preserve the existing distinction between inferred implementation cost and the
declared contract callers compose against. Do not promise private optimized
layouts through a public contract. Initially expose the source-level model with
that scope explicit; final-code evidence can be added separately.

Acceptance: editor and CLI report equivalent equations for supported cases;
unknowns remain visible; existing finite-contract refusals remain enforced.

### I2. Versioned editor report

Add resource entries keyed by resolved declaration identity and source range to
the editor JSON. Identify source/dependency versions and analysis scope. Include
explicit statuses for proved, unknown, not requested, cancelled and budget-limited
analysis; absence must never be interpreted as zero.

Request analysis for useful top-level roots and their dependencies, without
native code generation. Cache results against source dependencies, compiler and
analysis policy. Imports must resolve to the actual declaration, not a coincident
bare name. Older report versions remain usable for ordinary type hovers.

Acceptance: no assembly/link step needed; imported and local top-level summaries
are correctly attributed; invalid or stale evidence is suppressed. Required
contract checks cannot be skipped merely because optional editor inference times out.

### I3. Hover presentation and responsiveness

Append a compact resource section after the type and documentation. Show unknown
causes such as `work(print)` or an unsupported growing-accumulator recurrence.
Show declared and inferred bounds separately when both exist. Ordinary type
diagnostics should remain usable if optional analysis exceeds its budget.

Compute on the existing check lifecycle, never synchronously per hover. Reuse
dependency invalidation and cancellation; discard results from superseded checks.
Start with saved-file top-level native FP-RISC functions. Local expressions,
unsaved-buffer inference, call-site instantiated bounds and Sol-specific costs
are later slices, not implied by initial hover support.

Acceptance: real LSP tests cover higher-order equations, declared bounds, opaque
calls, shadowing, imported names, dirty roots/dependencies, cancellation, older
compilers and native/Sol separation. Record check latency and memory against
existing editor checks before selecting default analysis budgets.

### I4. Broader inference and target evidence

Add recurrence and callback-size coverage through resource-roadmap R2/R3. Use
verified input maxima to produce closed admission bounds. Add peak-live and
stack summaries only when their model and target are supported. Later expose
linked-image timing receipts separately from portable source summaries.

Acceptance: tighter bounds have supporting proofs and refusal cases, not merely
better benchmark agreement. Changed layout, runtime, compiler, target or image
invalidates the dependent machine evidence.

## Relationship to the existing plans

- [Resource/WCET/QOS roadmap](2026-11-07-RESOURCE-CONTRACTS-WCET-AND-QOS-ROADMAP.md):
  this is the first user-facing consumer for R1 summaries/diagnostics; R2/R3
  improve inference; T1-T4 and Q1-Q3 remain necessary for hardware and scheduling.
- [Pipeline refactoring](2026-11-07-PIPELINE-REFACTORING-ROADMAP.md): I1/I2 can be
  the concrete consumer that introduces P1 summaries. P2 evidence preservation
  and later representation planning improve precision. Initial hover support
  does not need to wait for full P2-P7 completion.
- [Pipeline semantic policy](2026-11-07-PIPELINE-SEMANTIC-POLICY.md): inferred
  facts carry provenance and domains; runtime value checks, optimization guards
  and compile-time resource refusals retain distinct meanings.

No new surface syntax, runtime enforcement, hardware guarantee or automatic
contract rewriting is authorized by displaying inferred bounds. This document
records intent; implementation and promotion require the gates above.
