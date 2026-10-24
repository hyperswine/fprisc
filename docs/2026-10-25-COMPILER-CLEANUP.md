# Compiler cleanup goal

Date: 2026-10-25. Kind: active implementation goal and acceptance register.
Applies to the Core cleanup rebased on main `0f6df38` and subsequent stages.
Requested explicitly by the user after the first Core pipeline slice.

Finish the architectural cleanup from the
[review](2026-10-25-ARCHITECTURE-REVIEW.md), in independently validated commits.
Preserve valid-program behavior and established diagnostics, native ABIs and
cache formats, or explicitly version and test any intentional changes.

## Work and completion criteria

| Item | Status | Acceptance |
|---|---|---|
| Separate Core/backend responsibilities | First slice implemented: Core.Syntax, Core.Opt passes and vector plans; Codegen driver 567 lines | Preserve emission and runtime behavior; keep new passes in their owners |
| Independent type vocabulary | Implemented as the prerequisite below | Infer compatibility exports, native/Base and Sol checks; no parser/inference dependency from Type.Syntax |
| Typed, uniquely named Core | Pending | Carry checked types and binder identity from inference; avoid reconstructing types after rewriting; checked handling of generated workers, joins and region helpers |
| Checked pipeline products and lint | Structural pass result implemented; type/scope lint pending | Each stage preserves or explicitly transforms its evidence; malformed scopes/types/worker contracts fail by name; differential evaluation |
| Frontend ownership | Pending beyond extracted Core syntax | Separate surface syntax, lexer/parser, desugaring and linearity with lexical/diagnostic/cache compatibility |
| Typed compiler options | Pending beyond local OptimizationOptions | Parse inputs once, pass explicit options, share canonical cache identity, remove only obsolete rollout paths with equivalent checks |
| Structured diagnostics/spans | Pending | Own source positions and diagnostics as data through inference/safety/rendering; preserve CLI and editor locations |
| Typed codegen contracts | Vector operations/float widths implemented; remaining kernel stages and ISA instruction vocabulary pending | Constructor-based operation/payload contracts and one renderer per target; verifier/emission/execution oracles |
| Validation ownership | Existing suites retained; focused Core checks added | Maintain invariant, golden/cache and evaluator/native differential checks without multiplying redundant builds |
| Obsolete architecture descriptions and names | Pending | Re-anchor semantic references in current IR/evaluator/runtime; document supported switches and current owners |

The reviewed allocator-quality/foreign-ABI enhancements and the region runtime
roadmap are separate work, not prerequisites for marking this cleanup complete.
The goal remains active until the table is resolved and required validation is
green. Finishing this first slice is not completion of the whole goal.

## Landed first slice

[Core pipeline ownership](2026-10-25-CORE-PIPELINE.md) records the original
127-job Base run and 128 emission comparisons. That validation preceded main's
new region work, so it is not proof of the integrated tree by itself.

## Next type boundary

`Type.Syntax` now owns the existing checked type vocabulary independently of
both surface and Core ASTs. `Infer` retains compatibility reexports. The next
step is to carry evidence out of inference, distinguish term binder identities
from display names, and define a checked typed-Core stage before migrating
Workers/Reuse/region analysis consumers. Do not infer an unannotated optimized
body again and call that preserved evidence.

## Integrated validation

The integrated compiler builds with `make fpr`. Full Base passed all **131
jobs in 420.47 seconds on six workers**, with no reused CI coverage. This run
includes the incoming region tests and the Core pipeline checks; its existing
platform/toolchain-dependent subchecks retain their explicit skips. The sources
and compiler binary stayed fixed throughout the run.

Sol argument handling and the shared-language fixture passed; measured self
and mutual tail calls each ran 3,000,000 iterations under the memory guard
(peak 86 MB), with the bytecode listing ending in TailCall rather than Ret.

Make question-mode checks prove a change confined to Core/Opt/Pipeline.hs or
Type/Syntax.hs invalidates fpr. A binary-only installed-tree presence check is
quiet without compiler sources; its existing machine/runtime files remain
available. The installed-tree guard was checked separately after Base; it does
not change the compiled compiler.

Local records: `/private/tmp/fpr-cleanup-integrated-build.log`,
`/private/tmp/fpr-cleanup-integrated-base.{log,json}` and
`/private/tmp/fpr-cleanup-sol-tail.log`. Hosted CI is requested by the push;
no physical board validation is claimed for this cleanup.
