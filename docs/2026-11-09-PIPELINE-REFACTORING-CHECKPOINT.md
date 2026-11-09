# Pipeline refactoring checkpoint

Date: 9 November 2026. Original read-only assessment at `f2351e2`.
Follow-up: the [P0/P1 implementation record](2026-11-09-RESOURCE-EDITOR-IMPLEMENTATION.md)
resolves the two P0 discrepancies below and adds the first P1 resource/editor
consumer. The original assessment below remains historical.
Evidence below distinguishes implementation inspection from recorded test runs;
this checkpoint does not rerun the complete corpus or physical hardware.

## Phase status

| Phase | Assessment |
| --- | --- |
| P0 inventory/baselines | Marked complete in the roadmap on 8 November; inventory, semantic decisions, 19-entry corpus, host baseline, RV64 compile baseline and reference audit exist. Review caveats below remain. |
| P1 shared facts/summaries | No general shared summary/analysis manager established by the inspected changes. Deliberately scheduled with its first consumer. Resource editor inference is a useful candidate. |
| P2 typed lowering | Substantial implementation through closure slice 3g, but migration and deletion gates are incomplete. |
| P3 representation planner | Existing workers/layout/carrier machinery remains; no consolidated replacement established by these changes. |
| P4 high-level consolidation | Still open; the latest diagnostic identifies concrete erased specialization that must migrate. |
| P5 effects/SSA optimization | Existing optimizations remain; no completion of the new shared architecture established. |
| P6 obligation placement | The earlier bounded-body tick placement is present. General composed-work/stack/region/fuel framework remains open. |
| P7 timing/admission integration | Existing scoped admission tools remain; no new complete source-to-machine WCET chain established. |

## What P2 has accomplished

The [signature bridge](2026-11-08-P2-SIGNATURE-BRIDGE.md) moves supported worker
and named vector callback signature authority to checked evidence, retaining
KernelKinds agreement checks and explicit handling of unsupported cases.
KernelKinds has not been deleted.

[Typed lowering](2026-11-08-P2-TYPED-LOWERING-SLICE-1.md) now supplies the emitted
function for its admitted class when it agrees with the existing lowered form.
The class has widened through monomorphic/polymorphic signatures, primitives,
products, records, guards, strings, lists and closures. Worker, reuse, placed,
ARC and transformed functions can still retain the old path. Application
dispatch also reuses existing Lower machinery; a broad admitted class is not
proof that every erased dependency has disappeared.

The [3g record](2026-11-08-P2-TYPED-LOWERING-SLICE-3.md) reports:

- 151-program sweep, 766 units; 34,223 class functions, 32,370 emitted typed
  (94.6% of that class), with zero refusals/disagreements.
- Identical generated code with typed lowering disabled on all 145 compiling
  sweep programs. The remaining programs are not thereby counted as passing.
- Corpus: 575 class functions, 523 typed; QOS guishell: 2,634 and 2,525.
- All 43 unit suites and the listed baseline/bridge/policy/options/stdcheck
  checks recorded as passing.
- Compiler allocation budget still red: +12.4%, +12.7%, +6.7% for the three
  tracked workloads. This blocks claiming an entirely qualified migration.

Do not divide these counts by the separately collected initial census. The
record explicitly withdrew that misleading coverage calculation. These changes
primarily preserve behavior/code while changing authority; they are not measured
runtime speedups.

## The latest finding changes the next useful work

The 258 `optimized` exemptions now have an attribution report. Most are erased
`Mono` transformations of let-bound closures: 167 single-use closure bindings
become direct calls, and 24 unused bindings plus one reused binding are handled
by the same rule. Another 28 are let sinking; 16 involve imported compatibility
clones; the remaining cases include other reshaping and one unclassified case.

Blindly removing the erased path would restore closure allocation and generic
application for cases that currently call directly. Move the closure specialization
and imported-clone logic into the typed pipeline before region placement, and
normalize there, rather than duplicating these transformations inside LowerTyped.
Vectors and code-label cases outside the current class also remain to migrate.

## P0 caveats still visible in the inspected files

The reference audit now exists, the GHC repetition/tuple issues have been
investigated, and semantic decisions are recorded. These address significant
parts of the earlier review. However, completion wording should not hide the
remaining discrepancies:

- Semantic-policy Rule 3 still says total operations, including floating-point
  arithmetic, may be reassociated freely. Totality does not imply associativity;
  amend that rule before using it to authorize algebraic rewrites.
- The baseline tool's documentation promises same-compiler metric drift fails,
  but the inspected exit path fails only behavioral failures and prints drift.
  Align the intended gate and implementation before relying on it for promotion.
- Host and RV64 compile evidence are not new Pi/Tang physical qualification.

These are review findings, not changes made by this checkpoint.

## Recommended next sequence

1. Correct the semantic-policy rule and settle the baseline drift gate.
2. Bring let-bound closure specialization, imported clones and required
   normalization into typed passes; remove their exemptions without code regressions.
3. Complete vector/remaining lowering coverage and reduce dual-path compiler cost;
   retire old consumers only after the agreement and budget gates are satisfied.
4. Introduce P1 summaries with a real consumer: the
   [resource inference/editor intent](2026-11-09-RESOURCE-INFERENCE-AND-EDITOR-INTENT.md)
   or P5 range-driven simplification.
5. Continue P6 composed work across calls/returns independently, reporting unknown
   runtime work explicitly. Do not treat instruction counts as hardware cycles.

The current progress is meaningful: checked information increasingly decides
emission. The remaining architectural milestone is eliminating duplicate
authority without losing optimizations or exceeding the compiler budget.

## Follow-up implementation

The [typed closures and vectors record](2026-11-09-TYPED-CLOSURES-AND-VECTORS.md)
records the scoped local-list-capture rule and vector lowering extension, with
validation and remaining migration limits. Earlier counts above are historical;
they are not a new full-sweep result for that extension.
