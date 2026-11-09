# Typed local closures and vector lowering

Implementation checkpoint, 9 November 2026. This extends P2 after slice 3g;
it does not complete P2 or retire erased Mono.

## Changes

`Core.Typed.Callback` already redirects safe known local closures. Its local
closure rule now also accepts closed lists of safe values captured by an
already evaluated, non-linear binder. A saturated application becomes a direct
code call with those captures. The binding disappears only when no uses remain;
an escaping closure retains its object. Partial applications, unknown callback
environments, open types, nominal containers and linear captures retain their
existing restrictions. This is a scoped extension, not migration of all 167
single-use closure cases identified in the previous attribution sweep.

`Codegen.LowerTyped` now plans vector builders and layout literals directly.
Pair-free reads in tuple pattern bindings and pattern guards snapshot the
original handle, perform the read/check, then match the value and handle in
order. Discarding the value does not discard its bounds check. Standalone
pair-free reads and invalid index arities are refused. The census admits vectors,
including polymorphic signatures, to the typed-lowering class. Runtime builder
names and vector read operations use the existing shared authorities.

Codegen revision 205 separates caches from the previous compiler. Shared native
emission, erased comparison and the existing explicit exemptions remain.

## Validation

- All 43 compiler unit suites pass, including new captured-list/escaping-closure
  cases and vector builder, layout, read-plan, arity and standalone-read cases.
- Typed-vector and specialization regression scripts pass.
- Typed-lowering corpus passes on host and RV64: 23 programs, 29 units;
  580 class functions, 527 emitted typed, zero refusals on each target. The
  remaining exemptions include 19 worker, 1 optimized and 33 placed functions.
- Compile budget remains failed: hello allocation +12.4%, std-live +12.8%,
  pos1 +6.7% against the recorded baseline. The limit remains 10%; this is not
  evidence that the incremental change itself costs those percentages.
- The complete saved/new vector-read comparison stops in the saved revision-204
  compiler on RV32, with a typed-lowering disagreement in `logPutTo`. That full
  eight-target check is not a pass.
- A temporary seven-target variant of the same saved/new vector-read harness
  passes: 16 native executions, 80 trap checks and 56 emission configurations,
  covering peek and inline on/off and one/four harts. Emission targets are a64,
  a64mac, qa64mac, x64, x64mac, qx64 and rv64; execution is host-native. The
  repository eight-target harness was not weakened.
- A QOS guishell check could not resolve `std/fs.fpr` in this checkout. No new
  QOS application qualification or physical-board timing evidence is claimed.

## Remaining work and roadmap relationship

The [pipeline checkpoint](2026-11-09-PIPELINE-REFACTORING-CHECKPOINT.md) and
[slice 3 attribution](2026-11-08-P2-TYPED-LOWERING-SLICE-3.md) remain the baseline
for the larger migration. Re-run the full attribution sweep before claiming
closure-exemption reductions. Imported compatibility clones, later-introduced
closure bindings, normalization/let sinking, worker/ownership/region exemptions
and foreign code-label cases still prevent deleting the erased path. Preserve
those optimizations until equivalent checked transformations are demonstrated.

The [resource inference/editor intent](2026-11-09-RESOURCE-INFERENCE-AND-EDITOR-INTENT.md)
needs summaries attached to these preserved typed identities. Direct closure
calls expose their actual callees; vector operations retain explicit layouts and
checks. Neither change by itself infers time/space summaries or supplies a
simple-risc cycle model. Those remain governed by the
[resource/WCET roadmap](2026-11-07-RESOURCE-CONTRACTS-WCET-AND-QOS-ROADMAP.md),
including target qualification and QOS admission assumptions.
