# Vector a: implementation audit and intended contract

Date: 2026-10-03. Scope: native FP-RISC and Sol, vector representation, callback lowering, fusion, SIMD, and the foundation for matrices and bulk-compute examples.

This audits the working checkout at `c60e562`, including the uncommitted specialization implementation described in [SPECIALIZATION-IMPLEMENTED](2026-10-03-SPECIALIZATION-IMPLEMENTED.md). It is a source review with targeted execution and assembly inspection, not a claim that the full cross-target suite was rerun. Recommendations below are a target contract and delivery plan, not implemented features.

## Assessment

`Vector a` has a useful foundation: element typing, linear ownership, contiguous scalar/field storage, selected direct column kernels, some map fusion, and selected RVV integer loops. Sol has a separate column representation and typed callback JIT. Ordinary vector syntax can already produce efficient code in supported cases.

It is not yet the uniform primary compute structure envisioned here. Native representation and kernel limits depend on record width, callback shape, capture count, element type, and target. Type-changing operations can leave the fast path silently. Composition can defeat SIMD. Sol and native do not share a pipeline optimizer. The existing matrix library is concretely `Vector Int`, not `Matrix a`.

There is also a correctness defect: native map fusion can reorder effects. Fixing that must precede extending fusion. Ownership of the intermediate vector does not imply that callback effects or failures are unobservable.

The intended user experience is: write ordinary typed records and ordinary `Vec.map`, `Vec.filter`, folds, and pipelines; get correct execution for every supported element type and record width; get column kernels, fusion, and SIMD automatically when legal. Users should not need layout strings, hand-written field loops, or arithmetic-specific replacement primitives to make ordinary compute code efficient.

## Findings and priorities

| Priority | Finding | Consequence |
| --- | --- | --- |
| P0 | Map fusion has no effect-order eligibility check | Two maps can produce a different observable trace after optimization |
| P1 | Native header has eight column slots and machine-word kind bitmaps | Wide records fall back to boxes; increasing one constant does not generalize the ABI |
| P1 | Record-map specialization caps outputs at four fields and callback parameters at eight | Small changes to record shape can introduce row allocation and generic application |
| P1 | Inferred float layouts cover scalars and flat tuples, not general float records | Some valid typed constructors/maps are refused instead of deriving a layout |
| P1 | Type-changing map lowering becomes `Vec.mapAs`, outside the native kernel matcher | Automatic output typing can remove an otherwise plausible fast path |
| P1 | Captures, record predicates, and record accumulators have incomplete native kernel coverage | Ordinary callback styles have allocation/performance cliffs |
| P2 | Fusion is narrow and runs after ordinary inlining | General map/filter/fold pipelines remain multiple passes; fused helpers can miss RVV |
| P2 | Native target coverage differs substantially | A64 column loops are scalar, x64 column specialization is disabled, RVV is optional and narrow |
| P2 | Sol uses separate storage/JIT planning and lacks native pipeline fusion | Equivalent programs have different optimization coverage |
| P2 | Matrix library is monomorphic and often constructs/intermediates through lists | It does not yet demonstrate a generic dense compute foundation |
| P2 | Optimization reporting misses important fallbacks | A successful compile does not establish which kernel actually ran |

## Current implementation

### Element typing and ownership

[Infer.hs](../compiler/Infer.hs) gives the core vector operations element-aware types. Native `Vector 1 a` remains a linear carrier: element typing does not remove ownership. Reads thread the successor vector; native get/set indices are zero-based in [vec.c](../runtime/vec.c). The older typed-vector document's one-based get/set description should not be used as the current contract.

Constructors and type-changing maps need a concrete output representation today. Inference derives float layouts for scalar F64/F32 and flat tuples of two through eight supported fields. General float records and nested float products do not receive equivalent layout derivation. Unresolved output layouts are refused. `Vec.mapSame` provides a same-element native path when an existing representation can be preserved; it does not solve general representation-polymorphic construction.

`Vec.dup` copies storage. Actor transfer uses deep copying. The current contract is single ownership, not implicit shared buffers or copy-on-write. A generic API must preserve this resource discipline even while hiding layout decisions.

### Native storage is partly automatic, structurally bounded

[vec_layout.h](../runtime/vec_layout.h) defines:

```c
#define VMAXCOLS 8
/* vec_t contains: */
uw len, eltid, elvar, ncols, kinds, fkinds;
col_t *cols[VMAXCOLS];
```

Each column is a contiguous machine-word span with growing capacity. First-push layout selection in [vec.c](../runtime/vec.c), `fix_layout`, chooses raw integers, boxes, or field columns for supported products of two through eight fields. Wider products become boxed rows. Nested fields remain referenced values rather than recursively flattened columns. Empty and single-field products do not follow the same product-column path.

`kinds` and `fkinds` are machine-word bitmaps. They introduce a second width ceiling independent of the eight pointer slots, including a different ceiling on RV32. `newAs` accepts short literal layout specifications; its float flags do not constitute a rich per-field width/type descriptor. Columns use `uw` cells, so native F32 storage should not be described as a guaranteed compact four-byte column.

The layout is an ABI, not a local container detail. [Codegen.hs](../compiler/Codegen.hs) mirrors header offsets; [runtime.c](../runtime/runtime.c) copies vector headers and columns during transfer. QOS graphics code, including sibling `qos/hal/unix/gfx.c`, mirrors/accesses vector storage. Descriptor changes must migrate copying, freeing, pooled allocation, generated accesses, foreign consumers, and runtime/module compatibility together.

### Native callback kernels have several independent limits

`vecSpec`, `arithClosure`, `soaDualMap`, and `soaDualMap0` in [Codegen.hs](../compiler/Codegen.hs) recognize selected scalar arithmetic and record-map shapes. They do not provide arbitrary typed callback lowering.

- Record-map outputs are limited to four fields. The generated callback parameter shape is limited to eight parameters.
- A supported captured record is different from an arbitrary capture environment. Multiple captured scalar parameters can fall back.
- Record predicates do not have the record-map column specialization route. They can reconstruct a row and apply the predicate for every element.
- Record-input folds with a scalar accumulator have selected support; record accumulators fall back.
- Inferred type-changing maps become `Vec.mapAs`, which is not included in the ordinary native map specialization matcher.

Generic map in [vec.c](../runtime/vec.c) builds an output vector, obtains each row, and calls `fpr_apply`. Generic filter compacts columns in place but still reconstructs/applies each row where needed. Generic fold uses repeated application and can create/recycle intermediate PAPs. Buffer reuse is therefore not evidence of allocation-free callback execution.

The new Core specialization pass specializes Core-defined higher-order functions at known call sites. C-defined vector primitives are outside that universe. It helps surrounding code, but does not by itself remove these generic vector callback paths.

### Composition and SIMD

Native `fuseVecFix` runs during emission, after the main inlining pipeline. It collapses selected adjacent map expressions and immediately adjacent single-use let pipelines, with bounded fixpoint iterations. Both sides carrying captures are outside its current composition shape. Selected capture-free scalar integer map/fold cases fuse while retaining the mapped vector required by the fold result.

It is not a general map/filter/fold optimizer. There is no general masked-filter pipeline. A synthesized map composite can contain helper calls that ordinary inlining no longer revisits. Those calls matter: the RVV straight-line matcher can accept an individual arithmetic map but reject its composed helper.

| Execution path | Current evidence and limit |
| --- | --- |
| Native A64 | Direct scalar column loops for selected callbacks; no general NEON lowering of these callback kernels |
| Native x64 | Column specialization disabled by `spec = not x64` in [Compile.hs](../compiler/Compile.hs); generic execution and fusion remain |
| Native RV64 | Selected integer arithmetic maps and integer sum reductions use RVV with `--rvv`; not a blanket float/record SIMD path |
| C numeric primitives | Host compiler can emit SIMD for particular primitives; that does not prove ordinary callback pipelines use SIMD |
| Sol | Typed scalar JIT kernels over columns on supported hosts; no general SIMD/pipeline-fusion guarantee |

Inspection found `Vec.map double` emitted RVV, while a fused `inc`/`double` composite did not. C assembly on the M4 included NEON instructions for selected numeric primitives, while 64-bit integer multiply in the inspected affine primitive remained scalar. QEMU can validate RVV semantics; it cannot establish target hardware throughput.

### Sol is ahead on descriptor width, separate on optimization

[Sol/Val.hs](../compiler/Sol/Val.hs) stores columns in a dynamic list, with raw integer/double and boxed column kinds. Product representation selection traverses the fields; it does not share native's fixed eight-column header limit. This is useful prior art, not proof that every wide-record JIT kernel scales without register constraints.

`vecScheme` in [Sol/VM.hs](../compiler/Sol/VM.hs) dispatches map/filter/fold through the typed JIT for supported shapes, with a minimum length threshold of 64. [HandJIT.hs](../compiler/Sol/HandJIT.hs) lowers typed callback operations through its kernel IR and host code generators. It supports useful record predicates and record-to-scalar operations, including supported captured scalar values; unsupported cases use interpreted application.

Sol does not run native `fuseVecFix`. Individually compiled kernels do not establish whole-pipeline fusion. The desired convergence is a shared typed operation/kernel plan, with profile-specific execution and numeric semantics, rather than assuming the two current implementations already agree on optimization coverage.

## Correctness reproduction: effect order

The following built and ran natively on the audited checkout:

```fpr
unsafe base.
first x = _ = print "first {x}"; x.
second x = _ = print "second {x}"; x.
main =
 v = Vec.fromList [1, 2];
 a = Vec.map first v;
 b = Vec.map second a;
 Vec.free b.
```

Observed output:

```text
first 1
second 1
first 2
second 2
```

Sequential materializing map semantics require the first map to finish before the second: `first 1`, `first 2`, `second 1`, `second 2`. Fusion eligibility currently checks callback shapes without excluding these effects. The comments in `Codegen.hs` and the ownership-only soundness argument in [VEC.md](2026-08-25-VEC.md) are insufficient and should be corrected with the implementation.

A regression must assert the whole trace, not only vector contents. Include panic/precondition order as well as printing, sends, and mutation. Even a pure callback can fail: changing traversal order can change which failure becomes observable. Filtering must not suppress a preceding operation that source semantics would have evaluated. Ownership, effect eligibility, and failure preservation are separate obligations.

## Measured performance evidence

Targeted native tests executed during this investigation: `tests/fuse.fpr`, `tests/vecfuse2.fpr`, `tests/recfold.fpr`, and `tests/fvec2.fpr`. Their exercised assertions passed. Assembly was inspected for A64, x64, RV64, and RV64 with RVV. A record-filter/type-changing-map probe compiled and showed generic filter and mapAs routes. These are targeted witnesses, not complete arbitrary-type or arbitrary-width coverage.

A temporary M4 benchmark processed five million integers, seven runs per variant. Input construction and final freeing were outside the timed region. Both variants produced sum `25000000000000`. Two maps fused; the following let-bound fold was a separate traversal.

| Program shape | Best | Median | Actor allocation gauge delta |
| --- | ---: | ---: | ---: |
| `map inc (map double v)`, then fold | 41.676 ms | 41.835 ms | 48 bytes |
| `map (affine 2 1) v`, then fold | 53.160 ms | 53.988 ms | 67,109,184 bytes |

The second callback captures two scalars and missed the native column kernel. Its compilation did not report that fallback. The allocation gauge counts newly allocated actor-pool bytes; recycled blocks need not increment it. It is not peak live memory, total memory traffic, or an exact count of all object creation. The numbers illustrate a callback-shape cliff, not a universal speed claim or a comparison against an optimized C baseline.

The audit's effect-order reproduction was rerun with:

```sh
XDG_CACHE_HOME=/tmp/fpr-vector-audit ./fpr build /tmp/vector-audit-effects.fpr -o /tmp/vector-audit-effects
/tmp/vector-audit-effects
```

The source is reproduced above so this evidence does not depend on retaining temporary files. A durable benchmark/regression suite is a delivery requirement below.

## Intended user-facing contract

1. **Element semantics are uniform.** Construction, indexing, updating, mapping, filtering, folding, zipping, gathering, and composition work for supported builtin types and their supported products. Type-changing maps derive their output layout. Unsupported numeric operations receive ordinary type errors; representation limitations should not masquerade as type limitations.
2. **Record width is not a language restriction.** Any finite record shape supported by the type system is representable, subject to checked allocation/resource limits. Width must not silently force whole-row boxes merely because it exceeds a header, bitmap, or register budget. Empty, singleton, wide, and mixed products need deliberate representations.
3. **Layout is a compiler/runtime responsibility.** Users supply types and functions, not `i/d/s/b` strings. Representation-polymorphic helpers carry inferred layout evidence or receive specialization automatically. Internal explicit-layout APIs can remain for foreign interfaces without becoming the ordinary compute API.
4. **Ordinary callbacks are the fast-path input.** Named clauses, guards, projections, pipelines, and captured values should lower to kernels when their operations are supported. Manual `Vec.axpb`-style substitutions must not be required for routine arithmetic. Opaque operations retain a correct scalar/boxed fallback.
5. **Composition preserves behavior.** Default optimization preserves effect order, failures, ownership, and each profile's numeric contract. Floating reductions do not silently reassociate; SIMD must respect those rules. Relaxed arithmetic, if offered, is explicit.
6. **Resource behavior is explainable.** Same-layout maps can reuse owned storage where legal. Type changes and filters have checked capacity/lifetime rules. Report work, allocation, and peak live storage separately. Hidden callback allocation and intermediate buffers are measurable.
7. **Hardware changes implementation, not valid programs.** Scalar kernels remain available. SIMD selection uses target/CPU capabilities and correct tail handling. A lack of SIMD is not a runtime refusal for an otherwise valid operation.
8. **Optimization is inspectable.** A structured report identifies layout, kernel, fusion decisions, capture handling, fallbacks, and relevant runtime guards. Normal programming stays simple; performance tests can assert an expected kernel and detect cliffs.

This promises a scalable scalar column path for suitable record computations, not that every string operation, opaque function, or record field can become a SIMD instruction.

## Representation and lowering required

Replace the fixed native header with a descriptor and dynamically sized column directory. Each field needs explicit kind, physical width, alignment, field path, and ownership/trace/drop behavior. Descriptor identity and element identity must remain coherent for empty vectors and type-changing maps. Avoid width-limited masks; check size arithmetic before allocating metadata or data.

Flatten finite nested products where useful and semantically safe; preserve references for recursive, variant, or opaque values where necessary. A wide mixed record can retain column storage with referenced columns. Unit/zero-field elements need a length without fabricated data. Bool packing is a separate physical-layout decision with explicit access and masking rules.

Kernel entry points should take a descriptor, column bases, length/index, and a capture environment. Load fields actually used by the callback. Do not pass every field as a machine argument or demand that all columns fit in registers at once. Field liveness, register allocation, spilling, and chunking should determine code shape. Cap specialization/code growth and use a correct scalar kernel when profitable specialization is unavailable.

Use a typed kernel plan for maps, projections, predicates, zipped inputs, and reductions. Preserve output-layout evidence through specialization and type-changing lowering. Normalize synthesized composites before scalar/SIMD selection. Native AOT and Sol JIT can consume the same legal operation plan without forcing identical storage objects or numeric behavior.

Migration must include the runtime copier/free paths, arena/pool lifetimes, codegen offsets, foreign graphics/GPU consumers, cached compiled units, and ABI/version checks. Test old/new incompatibility explicitly rather than loading a vector under the wrong header interpretation.

## Matrix a and other derived structures

The current [matrix.sol](../sol/lib/matrix.sol) declares `Matrix 1 = Type (Mat Int Int (Vector Int))`. Its `mMap` and `mFold` reuse vectors, but constructors, row/column access, transpose/gather paths, and the list-oriented multiplication interface often materialize lists. The VM's `Vec.mmul` has a raw-double path and a generic numeric path; the preamble's written vector signature is narrower than that runtime behavior. This needs a coherent typed numeric contract, not simply a renamed type.

The target shape is conceptually:

```text
Matrix 1 a = Type (Mat Int Int (Vector a))
```

This is proposed API notation, not a checked implementation. A dense matrix stores `rows * columns` elements in one vector; matrix dimensions do not become record-field columns. `Matrix Record` has the vector's field columns across its cells. Generic construction, map, indexed map, transpose, zip, and folds should use the same layout/ownership/kernel machinery. Map may change `a` to `b`.

Multiplication requires an appropriate numeric element type or explicitly supplied algebra. Arbitrary strings, records, and booleans do not acquire multiplication just because they fit in a vector. Dense numeric multiplication needs its own blocked/tiled kernel; elementwise fusion alone does not produce a good GEMM.

Check negative dimensions, dimension/product overflow, ragged input, incompatible shapes, and bounds. Specify empty and zero-dimensional matrices. Add direct generation/fill/range builders so bulk construction does not require a list. Views/strides are useful later, but must have explicit ownership or scoped borrowing; accidental aliases must not defeat linear buffer reuse. Tensor, image, mesh, and batched numeric wrappers should reuse these same primitives.

## Delivery order and acceptance gates

| Step | Deliverable | Required evidence |
| --- | --- | --- |
| 0 | Correct fusion eligibility and complete fallback reporting | Ordered effect/failure regression; optimized/reference comparison; every audited decline has an inspectable reason |
| 1 | Dynamic native descriptors and inferred layout evidence | Generated record widths 0, 1, 2, 4, 8, 9, 32, 65, 128 and more; mixed/nested/float products; copy/free/send/lifetime checks across supported word sizes |
| 2 | General scalar column kernels | Same/type-changing map, record filter, supported captures and accumulators; no per-row reconstruction/application for admitted kernels; x64 coverage |
| 3 | Legal pipeline optimization | Map/map, map/filter, filter/map, filter/filter, and supported fold pipelines; stable order, failure preservation, surviving vector/writeback behavior, allocation witnesses |
| 4 | Portable SIMD lowering | A64 NEON, supported x64 ISA, RVV; scalar differential tests, short lengths/tails, capability fallback, mixed columns; actual hardware timings |
| 5 | Generic Matrix and compute examples | Typed generic API, direct builders, shape failures, matrix/vector shared kernels, numeric matmul benchmarks, readable ideal examples |

Matrix typing and direct builders can start before SIMD. The ordered steps identify dependency/risk, not a requirement to postpone all matrix work until every backend has SIMD.

The test matrix must distinguish semantic support from kernel eligibility. Cover builtin integers/words/floats/bools/unit/strings, mixed records, nested products, empty inputs, large lengths, and generic helpers whose types are instantiated at a concrete call site. Confirm exact type availability and numeric behavior per profile rather than assuming native fixed-width arithmetic and Sol's numeric tower are identical.

Floating cases include NaN, infinity, signed zero, subnormals, and cancellation-sensitive reductions. Include out-of-bounds access, allocation-size overflow, callback precondition failure, and early failure order. Cross-target ABI tests should exercise RV32 as well as 64-bit hosts where supported; unavailable target/hardware legs remain explicitly unverified.

Performance gates should record elapsed time, elements/second, bytes moved where measurable, allocation, peak live storage, selected kernel, compiler flags, hardware, and output checksums. Include small vectors where setup dominates, large bandwidth-bound maps, compute-heavy callbacks, narrow/wide record projections, captured callbacks, and representative matrix workloads. Fuel/WCET accounting must continue to bound the transformed loops and setup; fusion/SIMD cannot simply erase charged work. No certified timing claim follows from host benchmark results.

## Examples that prove the vision

Use vectors for substantial bulk compute: many-particle updates, sampled signals, image fields, mesh attributes, regression/training batches, and dense matrices. Existing Sol physics, Mandelbrot, regression, SVM, and neural-network examples are useful starting points. Native `examples/ideal` currently does not demonstrate vector compute; add counterparts using ordinary named clauses, guards, preconditions, and pipelines once the relevant contracts work.

Keep lists where they suit small structural/control tasks. Replacing a two-body scalar benchmark's state with a tiny vector on every iteration would not demonstrate the bulk-compute goal. Prefer a many-body or large-particle example with an actual data-parallel dimension.

Each compute example should have a readable vector version, a trusted result/reference, an optimization report, and a realistic workload. The success criterion is that changing a record from four fields to nine, adding a captured scale/bias, or composing a filter preserves correct behavior and a sensible column execution path without rewriting the algorithm into manual operations.

## Relationship to earlier documents

[TYPED-VECTORS](2026-10-01-TYPED-VECTORS.md) establishes the element-type migration; this audit identifies remaining layout and operation gaps. [VEC](2026-08-25-VEC.md) describes early storage/fusion work; its ownership-only fusion argument is superseded by the effect-order finding here. [SPECIALIZATION](2026-10-03-SPECIALIZATION.md) and [SPECIALIZATION-IMPLEMENTED](2026-10-03-SPECIALIZATION-IMPLEMENTED.md) cover higher-order Core dispatch; vector primitive/kernel specialization remains a separate required layer.
