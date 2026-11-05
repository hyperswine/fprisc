# Type specialization on `builtin` (C2) and interval/sharing upgrades

The [4 November continuation](2026-11-04-ZERO-OVERHEAD-COMPLETION.md#c2-admission-milestone-arcrev-9)
replaces this snapshot's Core-node cloning caps with recursive-graph and
selected-target image admission, and tightens checked boundary/result evidence.
Type-derived field graphs, scalar/aggregate tagged export conversions and
generic tagged fallback are implemented there. Hidden-field storage and checked
extraction are also implemented; deterministic unboxed storage selection remains
unfinished.

Date: 3 November 2026. Kind: implementation record. Applies to: `compiler/Representation.hs`, `compiler/Arc.hs`, `compiler/Compile.hs`, `compiler/Compiler/Options.hs`, `compiler/Codegen/Interval.hs`, and `compiler/Codegen/Simplify.hs`.

## Summary

This change completes two items from the zero-overhead and native performance roadmaps:

1. **C2 on `builtin` (`FPR_NO_TYPE_SPEC=1` / `-notypespec`, `arcRev = 7`)**:
   - **Per-instance data representations (`Data Int Int`)**: Constructor allocations (`CMk`) and tag tests (`CTagEq`) allocate fresh data instances unified through `dataSubs` whenever two `Data tid` values meet. Disjoint containers of the same nominal `tid` (such as `List Int` alongside `List Word`, or `List IPair` alongside `List WPair`) keep distinct per-instance field kinds without colliding on a single global `(tid, variant, fieldIndex)` table. Every occurrence of a nullary constructor allocates its own instance, so a `Nil` shared by two containers of one nominal type can no longer make them meet; values that genuinely meet (a shared binding, the two arms of a branch, `==`) still unify their instances and reject incompatible element kinds.
   - **Budgeted representation-polymorphic function cloning (`typeSpecBudget = 4096` Core nodes)**: Top-down representation inference from program roots (`main`, `machineInterrupt`, and pinned C exports) clones non-pinned functions on demand (`<fn>$typespec$<key>`) when a call site's resolved argument representations conflict with the base function's inferred representation signature. A checked declaration only blocks cloning when *every parameter* has a known representation (then all call sites agree and the uniform entry serves them); a concrete result never blocks it, which is what made `len : List a -> Int` and the constructors clonable. Budget overruns or pinned export conflicts record structured notes emitted under `--remarks`.
   - **Known-constructor elimination (`A1`) on `builtin`**: `Linked.caseKnownLinked` now runs on `builtin` (both manual and `--arc`) when `cgCaseKnown && cgTypeSpec` is active.
   - **Nominal type ids are kept.** A synthetic per-instance id (`List Word` as `0x77000002`) is *not* introduced: every walker in `runtime/runtime.c` recognises a list by `TID(x) == T_LIST` (33 sites — drop, deep copy, `==`, print, iteration), so a per-instance id is a runtime-object revision, i.e. C1 piece 2 alongside the layout table. Instance separation lives in the compiler's field table and reaches the runtime through `$arc.setLayout`, which already records each cell's field kinds.
2. **Caller/induction facts in `Codegen.Interval` and cross-block pure sharing in `Codegen.Simplify`**:
   - **Arithmetic step difference constraints**: Completed `OArith` / `OArithU` `Add` and `Sub` instructions with a constant operand contribute exact difference constraints (`v - x <= k` and `x - v <= -k`) to strictly dominated blocks and subsequent instructions in the same block (walked top-down so no instruction can circularly justify its own overflow check), chained transitively through `diffUB`.
   - **Non-negative producer bounds**: `OStrLen` (`>= 0`) and `OBit BAnd` with a non-negative constant mask (`in 0..mask`) supply direct lower and upper bounds to `lbWith` and `ubWith`.
   - **Acyclic join-block fact intersection**: Bounds that hold on every incoming edge of a multi-predecessor acyclic join block are intersected (`max` of upper difference bounds) and propagated to the join block and its dominator subtree.
   - **Natural-loop monotone induction bounds**: Loop headers (`h /= fnEntry`) whose back-edge steps are provably non-decreasing (`r >= u`) or non-increasing (`r <= u`) establish relational lower/upper bounds (`u >= a0` or `u <= a0`) from the loop's entry arguments across the loop body.
   - **Dominance-aware cross-block pure sharing (`sharePureAcrossBlocks`)**: Non-constant pure operations (`OUntag`, `OTag`, `OField`, `OTruth`, `OBoolOf`, `ONot`, `OIsInt`, `OTagTest`, `OVariantTest`, `OAddress`, `OIndex`, `OIndexByte`, `OArithU`, `OBit`, `OCmp`) are shared from strictly dominating blocks whenever no register-clobbering call lies on any path between the dominating definition and any use of the duplicate instruction.

## Verification

- `tests/ExportPlans.hs`: verifies representation-polymorphic `identity` cloning on `Managed` and `RawWord`, disjoint `List Int` and `List Word` instances specializing without merging (nominal tids kept, Word fields `RawWord`), refusal when the two instances meet in one branch, and `FPR_NO_TYPE_SPEC=1` rollback.
- `tests/Interval.hs`: verifies arithmetic step chains (`stepChain`), acyclic join intersection (`joinIntersect`), natural-loop induction lower bounds + cross-block `OUntag` sharing (`loopInduct`), and `OStrLen` / `BAnd` producer bounds (`producerBounds`).
- `tests/CompilerOptions.hs`: verifies `FPR_NO_TYPE_SPEC=1` (`-notypespec`) cache-key distinction.
- `tests/check_raw.py` and `tests/check_pair_raw.py`: verify QEMU RV64 execution of representation-polymorphic functions and disjoint raw/managed lists under C2, and refusal under `FPR_NO_TYPE_SPEC=1`.
