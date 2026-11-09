# Callable census and shared typed summaries

Implemented locally, 9 November 2026. Analysis only: no specialization,
defunctionalization, representation change or optimizer consumer is enabled.
This is the first census/flow-analysis slice of the
[static-functions design](2026-11-09-STATIC-FUNCTIONS-AND-DEFUNCTIONALIZATION.md).

## Using it

```sh
./fpr compile --system=posix --callables examples/logbook.fpr /tmp/logbook.s
./fpr compile --system=posix --callables=json examples/logbook.fpr /tmp/logbook.s 2>/tmp/logbook-callables.log
```

`--callables` (also `--callables=summary`) prints a concise census to stderr.
`--callables=json` emits one JSON line identified by `callableVersion: 1`, followed
by the ordinary compiler diagnostics. Per-unit `apply` lines report the existing
emission counters: generic dispatch instructions, known partial-application
creation markers and static PAP descriptors. Both cold and warm unit-cache paths
report them. These are static emission counts, not executed calls or allocated
bytes; runtime-internal application/allocation is outside their scope.

The flag currently belongs to `compile`, not the build/run driver. It requires
native compilation and rejects `--check-only` and `--editor-json`. Default
compilation does not run the analysis or print this report. The flag is not part
of codegen cache identity, and no codegen revision is changed for this feature.

The typed snapshot is taken after checked specialization, inlining, collection
optimization and TRMC, before region placement and erasure. Its census includes
all owned templates in the linked snapshot, including ones not reached from the
selected roots. Do not equate this with final executable reachability or claim
that every candidate becomes a PAP in emitted code.

## Shared API

`Core.Typed.Callable` owns the reusable analysis. It consumes the existing
`Target`, `Slot` and `Template` identities/schemas from the checked callback
catalog. It does not invent string-based local identities or replace the
existing callback-demand/recursive-stability analysis, which answers different
questions. `Compiler.CallableReport` adapts the linked artifacts into that catalog
and renders the result; it contains no separate inference rules.

Each summary retains:

- The checked `CodeContract`, capture binders/schemes/shapes and parameter binders.
- Abstract input values by capture/ordinary-argument slot, and the returned value.
- Possible members identified by code target and already supplied ordinary
  argument count. Remaining physical arity comes from the checked template,
  not by counting arrows in a source type.
- Dependencies on known targets and whether the entry was reached by the analysis.
- Explicit unknown causes. Ownership shapes are preserved as evidence, but an
  arrow's shape is not a proof about its environment's capture multiplicity.

Abstract values contain member sets, unknown reasons and supported product
fields. They support local aliases, branches, direct/code/join calls, partial
application, saturation/over-application, captures, parameters/returns, tuples,
closed record construction/projection, pattern bindings and match alternatives.
Calls and returns solve together by monotone iteration over recursive cycles.
Context-insensitive joins intentionally lose correlations between different
invocations; they may retain more candidates than an individual call can use.

The current linked root artifact's exported entries are treated as open entry
points. Their parameters are unknown inputs, rather than assumptions that only
visible callers exist. Escaped callable members acquire unknown remaining
arguments. Other targets acquire input evidence from calls and captures. Imported
functions keep qualified identities; two same-named exports are not merged.

Unproductive recursive returns have no callable evidence, not a proof of an
empty runtime family. A known branch does not erase an unknown branch. Foreign
or primitive calls without a checked body, unsupported constructor/container
flow, missing code and projections, and local recursive-binding cases report
unknown. Tuple/record fields have explicit structure; unsupported nominal/list
flow is not flattened into a falsely compatible family. Effects and runtime
callbacks at unknown boundaries are conservatively treated as escaping. Without
an alias analysis, opaque calls and mutable field stores invalidate product-field
evidence across the reached snapshot, including products captured in another
owner. The summary exposes `productFlowInvalidated`; this deliberately loses
precision rather than retaining stale known fields. It is not a general effect
or ownership proof.

## Bounds and invalidation

Default limits are 32 whole-program iteration rounds, 64 members/reasons per
value and product depth 4. Truncation inserts an unknown reason. Hitting the round
limit marks every published summary/site value with `iteration-budget`;
fixed-point completion is not a claim that unknowns disappeared. These are
structural/work bounds, not a wall-clock timeout.

The report includes status, limits, root identities and a deterministic snapshot
fingerprint over the typed templates, roots and policy. The fingerprint is
FNV-1a-64 over UTF-8 diagnostic serialization: an advisory snapshot identifier,
not a security hash or a persisted proof-cache format. Type/schema strings in
JSON are diagnostic representations; the Haskell API retains the typed objects.

Analysis runs afresh on the checked snapshot even when emitted units are cached.
A changed import therefore cannot reuse an old report. No persistent callable
summary cache or general cross-pass evidence manager is added in this slice.
A future consumer must request analysis for its current checked snapshot; it must
not reuse this result after transformations without remapping/recomputation.

## Census interpretation

| Category | Meaning at this checked stage |
| --- | --- |
| ClosureConstruction | A surviving `ClosureValue` and its known code target/capture schema |
| FunctionReference | A reference to a known function with ordinary parameters; candidate static descriptor, often eliminated by later/direct lowering |
| PartialApplication | A known target has fewer supplied ordinary arguments than its checked physical arity |
| ResidualApplication | An application through a non-global head remains; its flow may nevertheless have known candidates |
| DirectApplication | A known global/code/join application; over-application may also involve a returned callable |
| BoundaryApplication | A global application lacks a checked body here; includes primitives as well as foreign/runtime boundaries |
| ContainerStorage | Callable or unknown values occur in supported products or an unsupported container flow |

Mixed known/unknown heads retain their unknowns regardless of category. Counts
are traversal-site counts, not mutually exclusive runtime costs. Each detailed
site has an owner identity, stable analysis path, checked result type, origin,
argument count and abstract value. Source locations are explicitly owner-definition
anchors. Raw expression-origin offsets are retained but are not falsely resolved
against the caller's file after inlining. Generated owners without an anchor say
`unlocated`.

## Runtime boundary inventory

The report exposes calls without checked bodies, but does not analyze C runtime
internals. Source inspection confirms these remaining ABI consumers:

| Consumer | Why a future no-PAP mode must address it |
| --- | --- |
| `runtime/fpr.h`, `runtime/runtime.c` | PAP/static descriptor layout, `fpr_applyN`, object traversal/copy/reclamation |
| `runtime/actors.c` | Spawn, heap/inbox and app entry paths explicitly recognize `T_PAP` |
| `runtime/vec.c` | Generic callback application; fold handles temporary PAP ownership |
| `runtime/mod.c` | Row function extraction and arity inspection read the PAP descriptor |
| `Codegen.Lower` | Residual applications still emit generic dispatch |

This inventory is not yet the design's complete identity/equality/serialization
semantic audit or a runtime call-graph proof. Unknown boundaries remain visible;
no strict no-PAP flag is implemented.

## Validation

- All 44 compiler unit suites passed. Focused final reruns cover callable-flow
  analysis and option parsing after report-format refinements.
- Callable unit tests cover branch unions, qualified identities, argument/return
  propagation, partial prefixes, saturation and over-application, returned
  closures, function-valued captures, record projection, recursive fixed points,
  unproductive cycles, mixed known/unknown branches, target/round/structure limits,
  retained linear capture shapes and deterministic fresh-snapshot results.
- `tests/check_callables.py` compares byte-identical root/unit assembly and equal
  unit-cache identities with diagnostics off/on, on the host and RV32, with
  inlining on/off and cold/warm caches. It also checks fresh snapshots after an
  import edit with restored modification time, distinct imported identities,
  summary/JSON output and invalid option combinations.
- The default compile-budget check remains green: hello 1.47 GB, std-live
  30.68 GB, pos1 63.58 GB allocated, approximately unchanged from the baseline.
  No new baseline was recorded.
- A logbook snapshot reached a fixed point in 22 rounds: 2,972 owned templates,
  15,897 census sites, including 219 closure constructions, 23 partial application
  sites and 283 residual applications. These are whole-snapshot candidate counts,
  not root-only or executed counts. Its detailed report is multi-megabyte;
  use the concise default for routine inspection.

No new physical-device, QOS admission, runtime speedup or complete PAP-elimination
guarantee follows from these checks.

## Next consumer

Use this census to select a small closed callable family for the first
`--defunctionalize` rewrite, and use the captured schemas to design explicit
callable ownership/multiplicity evidence. Before either changes code, validate
family type compatibility, allocation/failure behavior and source contracts.
General ownership proof, precise recursive nominal/container flow, persistent
unit metadata and runtime-boundary migration remain open.
