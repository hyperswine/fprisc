# Pipeline pass inventory

Date: 7 November 2026. Phase P0 of the
[pipeline refactoring roadmap](2026-11-07-PIPELINE-REFACTORING-ROADMAP.md).
Baseline: `d308c1b` (`6761b28` plus the two documentation commits). Status:
inventory only — this document changes no compiler behavior and marks no phase
complete.

Semantic rules a pass must keep are in the
[semantic policy](2026-11-07-PIPELINE-SEMANTIC-POLICY.md); rule numbers below
(`R1`…`R7`) refer to it.

## How this inventory was derived

The order is the order the driver actually calls the passes in, read from
`compiler/Compile.hs` (front end, unit emission, linked pass sequence) and
`compiler/Codegen.hs` (`emitProductProgramWithImports`), and each row's
description is the module header of the pass named, not a design intent. Stage
ids (`typed.listfusion`, `codegen.placement`, …) are the ids
`tests/pipeline/corpus.json` uses for `positive_for`.

## The path a native checked function takes

```text
source units ─ Modules/Frontend.Paths ─ Frontend.Lexer/Parser ─ Frontend.Normalize (aritySpill)
             ─ Struct (expandStructs) ─ Precond (applyPreconds)
             ─ Infer (inferTopsChecked + Infer.Evidence) ─ Safety ─ Frontend.Linearity
             ─ Frontend.Desugar.Typed (prepareChecked)  → checked typed Core
checked typed Core ─ Core.Typed.Close ─ [linked: listFusion, specialize, inline,
                     specialize, caseKnown, vectorRead, normalize, fuse, trmc]
             ─ Compiler.Native.Core (owned products, layout, closing)
             ─ Compiler.Native.Regions (receive-turn regions)
             ─ Compiler.Native.Core.compileSelection → erased Core  [compatibility boundary]
erased Core ─ NativeImports.prepareEmissionWithImports
             ─ Core.Opt.Pipeline: FuseVectors, MakeWorkers, NormalizeForReuse,
               ReuseConstructors, PairReturns
             ─ Codegen.Lower (LoopForm, placeTicks, StringRead/VectorRead helpers)
             ─ Codegen.Simplify ─ Interval/LoopOptimize/Pressure
             ─ target selection ─ Liveness ─ Allocate ─ Frame ─ Bounds
             ─ Codegen.Stack / Codegen.Heap admission ─ emit text
```

Two facts worth stating plainly, because the roadmap's target differs from
them: the erased pipeline still runs on every emitted unit (`Core.Opt.Pipeline`
is called from `emitProductProgramWithImports`), and the erased Core it runs on
is produced by the compatibility boundary `Compiler.Native.Core`, after the
typed passes have already finished.

## A. Front end — source to checked typed Core

| stage | module | in → out | consumes | produces | effects | refusal | identity |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `frontend.modules` | `Modules.hs`, `Frontend.Paths` | files → unit list + hashes | project files, `use` graph | unit hashes, path checks | none | path-literal errors, `exitFailure` | unit hash `u-<12>`, prelude hash `p<8>` |
| `frontend.parse` | `Frontend.Lexer`, `Frontend.Parser` | text → `[STop]` | — | surface AST + spans | none | parse errors with spans | source digest in the unit hash |
| `frontend.normalize` | `Frontend.Normalize` (`aritySpill`) | surface AST → surface AST | arity | spilled-tuple binds, notes | none | none (note only) | unit hash |
| `frontend.structs` | `Struct.hs` (`expandStructs`) | surface AST → flat AST | sig/struct tables across units | `Numeric.+`-style globals, record values | none | sig/struct errors | unit hash |
| `frontend.precond` | `Precond.hs` | surface AST → AST + obligations | signature predicates, clause guards, case discrimination | `PreStatus` per obligation, inserted checks | inserts `RuntimeCheck` calls with blame; `/` stays a `BuiltinTrap` | out-of-fragment predicate = signature error | `contractHash` (`-c<12>`) |
| `frontend.infer` | `Infer`, `Infer.Session`, `Infer.Evidence`, `Infer.Trace` | AST → typed scheme + evidence capture | globals, imports, evidence | schemes, holes, linearity sigs, `ExprFact`/`BinderFact` | none | type errors, typed holes, missing evidence capture | unit hash |
| `frontend.safety` | `Safety.hs` | inferred program → accepted program | `approvedLibraries` allow-list, recursion declarations | safe/unsafe verdict; `unsafe` taint | none | refused public function in a safe program | unit hash |
| `frontend.linearity` | `Frontend.Linearity` | tops → linearity result | declared linear types | linearity diagnostics | none | linearity error | unit hash |
| `frontend.desugar` | `Frontend.Desugar.Typed` (`prepareChecked`), `Frontend.Desugar.Checked` (facade) | inferred source → checked typed Core | inference + evidence | `Core.Typed.Syntax` program, `CheckedPlans`, declines | none (layout/compat belongs to native) | `Left reason` = hard error | unit hash |

`Frontend.Desugar.Checked` is a compatibility facade; new code consumes the
owned products from `Frontend.Desugar.Typed` directly.

## B. Checked typed passes (pre-erasure)

Sequenced by `Compiler.Native.Linked` from `Compile.hs`'s `linkedResult`; each
is a `checkedStage` that turns a `Left` into a labelled compile error, so none
of these has a silent fallback. All of them preserve checked types, clone
identity and provenance (R1).

| stage | module | in → out | consumes | produces | effects | refusal | identity |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `typed.verify` | `Core.Typed.Verify` | closed program → () | block/type/definition invariants | compile error | none | hard error | — |
| `typed.close` | `Core.Typed.Close` (`closeProgram`) | typed program → `ClosedProgram` | layouts, callback mode, imports | closed functions, owned contracts, origins, code library | none | `Left String` | unit source hash + `ccore4-` identity |
| `typed.listfusion` | `Core.Typed.ListFusion` (`fuseListLinkedWithHelpers`) | closed program → closed program | catalog templates (shape-verified), `Core.FusionPolicy`, helper exposure | fused chains, `FusionNote`s | may reorder Int `+ - *` under the R4 relaxation; never `/` | declines per candidate | unit source hash |
| `typed.specialize` | `Core.Typed.Specialize`, `Core.Typed.Callback.*` | closed program → closed program | callback catalog, calling schemes | clones with checked schemes, declines | none | declines per target; `UnknownTarget` remarks observed | clone names carry source identity |
| `typed.inline` | `Core.Typed.Inline` (`inlineClosedWithDecisions`), budgets 3/24/64 | closed program → closed program | contract sizes, helper pipelines | inlined bodies; callee entry tick comes with it | brings a callee's tick across a call (R5) | budget/`decline` | remark stream `typed-inline-attempt` |
| `typed.caseknown` | `Core.Typed.CaseKnown` | closed program → closed program | scrutinee known-constructor facts | moved alternatives, bound fields | keeps evaluation and trap order | declines when two leaves would select the same alternative | remark stream |
| `typed.vectorread` | `Core.Typed.VectorRead` (`planReads`) | closed program → closed program | immediately destructured read pairs, handle-reuse proof | direct reads | none beyond the read itself | declines anything else | remark stream |
| `typed.normalize` | `Core.Typed.Normalize` | Base entries → Base entries | literal/local-alias facts | sunk bindings | strict order of effectful bindings kept | none | unit source hash |
| `typed.fusion` | `Core.Typed.Fusion`, `Core.Typed.FusionSafety` | closed program → closed program | `Core.FusionPolicy`, safety evidence | fused callback loops | same R4 relaxation | declines per candidate | remark stream |
| `typed.trmc` | `Core.Typed.Trmc`, `Core.Typed.TrmcProof` | closed program → closed program | fresh-cell worker protocol, catalog | mutation confined to the proven protocol | introduces in-place writes (R3 mutable class) | declines | remark stream |
| `typed.monomorphize` | `Core.Typed.Monomorphize` | typed program → typed program | complete checked types, `typeKey` | type-keyed clones; entries kept for the tagged fallback | none | keeps original entries | clone identity = source entry + type |
| `typed.layout` | `Core.Typed.Layout`, `Core.Typed.Carrier`, `Core.Typed.BaseTransport`, `Core.Typed.Parametric` | typed program → layouts + transport decisions | closed product params, type instances | layout/transport plan attached to the product | none | unsupported shape keeps a general representation | `productParameterKey` in `ccore4-` |
| `typed.erase` | `Core.Typed.Erase` | typed function → erased `Core` | typed nodes/patterns | erased Core (compatibility projection) | none | — | — |

The typed sequence in `Compile.hs` today is: list fusion → callback
specialization → inlining (≤3 depth, 24/64 budgets) → specialization again →
case-of-known → vector reads → Base normalization (64-bit, reuse on, not
ARC/builtin) → vector fusion → TRMC. `typed.monomorphize` and `typed.erase` run
per artifact when Core is selected for emission, not in the linked sequence.

## C. Erased / compatibility projection

Runs inside `emitProductProgramWithImports` on the erased Core the
compatibility boundary published. These are the passes the roadmap retires
(P2–P5); today they are the optimization authority for units whose typed
evidence was dropped at `compileSelection`.

| stage | module | in → out | consumes | produces | effects | refusal | identity |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `erased.fusion` | `Core.Opt.Fusion` (`fuseCompatibilityWithImports`), `Core.Opt.Vector` | erased Core → erased Core | imports, `Core.Analysis.FusionSafety`, `Core.FusionPolicy` | fused pipelines | R4 relaxation | declines | `ccore4-` of the lowered input |
| `erased.workers` | `Workers.hs` (`workerizeWithProducts`) | erased Core → erased Core + `ScalarSignatures` | arities, product parameters, `Codegen.IR.arityCeiling` | private workers/wrappers, scalar signatures | none | keeps the public general entry | signatures enter `ccore4-` (checked layouts) |
| `erased.normalize` | `Core.Opt.Normalize` (`normIn`) | erased Core → erased Core | indexed-memory mode | normalized bodies for reuse | none | off unless reuse+normalize | flags `-licm`, `-noreuse` |
| `erased.reuse` | `Reuse.hs` | erased Core → erased Core | bounded uniqueness proofs, `poolResetters`, region hooks | pool reset sites, consuming entries | introduces reuse of fresh constructors (R3 allocation) | never for borrowing/last-use-only | resetter set in `ccore4-` |
| `erased.pairreturns` | `Core.Opt.PairReturns` | erased Core → erased Core | call-site product shapes, target width | private register-return twins | none | tagged entry retained | `-nopairret` |
| `erased.specialize` | `Mono.hs` (`specializeCompatibilityWithProducts`) | erased Core → erased Core | call targets, imported private names, HAL arities | specialized clones | none | budget falls back to the original call | `-nospec` |
| `erased.inline` | `Inline.hs` (`inlineSmall`, `inlineCompatibilityWithImports`, `vecPeekCompatibility`) | erased Core → erased Core | imports, `pureOutside`, callback targets | inlined compatibility bodies | brings ticks (R5) | declines | `-noinl`, `-novp` |
| `erased.arc` | `Arc.hs`, `Arc.Uniform`, `Arc.Products` (`lowerArcWithProductEvidence`, `lowerRawWithProductEvidence`) | typed+layout evidence → owned erased Core | ownership evidence, layouts, type-spec flag | consuming/borrowing calls, cleanup placement | ownership transfer, retained refs (R3 mutable class) | type-spec declines reported as remarks | `-arc<rev>` |
| `erased.representation` | `Representation.hs` via `Compiler.Native.Representation.prepareFor` | ARC/raw program → specialized representations | type shapes, instances | type/representation clones | none | `FPR_NO_TYPE_SPEC=1` disables cloning | `-notypespec` |
| `erased.regions` | `Compiler.Native.Regions`, `Core.Region.*` (`placePrograms`) | Core per artifact → regions + typed region programs | receive-turn option, loop/call region flags | region annotations, `reportTurns` | introduces region hooks (`$regionRoom`, `$regionMark`) | bypass for builtin/ARC | `-nort`, `-nolr`, `-nocr` |
| `erased.kernelkinds` | `KernelKinds.hs`, used inside `Codegen.Lower` | erased Core → raw-word signatures | callback ABI shapes | `Kind` per argument/result | none | conflicts decline to the tagged path | — |

## D. Lowering and target selection

| stage | module | in → out | consumes | produces | effects | refusal | identity |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `lower` | `Codegen.Lower` (`lowerFn`, `lowerProgram`) | erased Core → typed SSA CFG | `KernelKinds` signatures, `ScalarSignatures`, product markers, HAL arities | `Program` of verified functions | emits entry tick + stack check; a trap stays where its operation is | refuses the form and names it; a native-only driver turns that into a compile error | `g<rev>` + `ccore4-` |
| `codegen.loopform` | `Codegen.LoopForm` (`formSelfLoop`) | SSA blocks → natural loops | back-edge shapes | loops with back-edge ticks | adds back-edge ticks (R5) | — | — |
| `codegen.placement` | `Codegen.Placement` (`placeTicks`, `tickBodyBound`) | SSA loops/blocks → SSA with obligations placed | `polTickBatch`, body bound | final tick placement, removed redundant checks | moves/removes obligations (R5, R6) | — | `-notickbatch` |
| `codegen.vectorread` / `codegen.stringscan` | `Codegen.VectorRead`, `Codegen.StringRead`, `Codegen.StringScan` | SSA reads → read operations | read shapes, guards | direct/guarded reads | none | declines to the runtime call | `-novecfast`, `-nostrfast`, `-nosc` |
| `codegen.verify` | `Codegen.Verify` | function → verified function | block ids, single definition, op signatures, terminators | verified function | — | compiler error, never a fallback | — |
| `codegen.simplify` | `Codegen.Simplify` | verified function → verified function | `policyOptions`, pressure model | simplified function; never touches a tick | folds literal checks, removes dead definitions | compiler error on failure | `codegenRev` (`g204`) |
| `codegen.interval` | `Codegen.Interval` | function → bounds facts | dominating comparisons, steps, non-negative producers, loop induction | difference-bound facts | none | unknown is `unknown`, never zero | — |
| `codegen.loopoptimize` | `Codegen.LoopOptimize` (`moveInvariants`), `Codegen.Pressure` | function → function | interval facts, register budget, alias facts | hoisted invariants into existing unique preheaders | moves Trapping/ImmutableRead ops (R3, R4) | declines when pressure or alias blocks it | — |
| `codegen.liveness` | `Codegen.Liveness` | selected stream → live ranges | block parameters, parallel copies | live ranges | — | — | — |
| `codegen.allocate` | `Codegen.Allocate` (`Codegen.Place` for RV/other profiles) | stream → allocation | live ranges, register budget, fixed operands | registers/spill slots | — | — | — |
| `codegen.frame` | `Codegen.Frame`, target forms | frame refs → layout | frame objects, alignment | offsets, frame size | decides the stack demand that admission checks (R6) | — | — |
| `codegen.bounds` | `Codegen.Bounds` | final stream → segment bounds | safepoint boundaries | `native-insns-v1` segmax per function | — | reported, not silently zero | `native-insns-v1` |
| `codegen.stack` | `Codegen.Stack` (`analyse`, `admit`) | frames → stack facts | ABI edges, frames | bounds, report lines | admission decision (R6) | reported refusal | `-shallow`, stack report flag |
| `codegen.heap` | `Codegen.Heap` (`analyse`, `admit`) | final verified ARC IR → equations | demands, equations | count/byte upper bounds | admission decision (R6) | unknown boundary never zero | `--heap-budget` |
| `codegen.kernel` | `Codegen.Kernel`, `Codegen.Kernel.Plan` | column kernels → typed CFGs | kernel requests from fusion/vectors | kernel functions | guarded memory ops only | declines | — |
| `codegen.calling` | `Codegen.Calling`, `Codegen.Call`, `Codegen.Protocol`, `Codegen.Export.Plan` | signatures → conventions | arities, address escape, ownership | calling conventions, adapters, PAP entries | boundary calls (R1) | refuses unsupported arity | interface revisions `a64InterfaceRev` etc. |
| `target.select` | `Codegen.Target.RV/A64/X64`, `Codegen.Opcode.*` | SSA → target ops | register budget, forms, width | selected stream | selection may fall back per function (reported) | reported fallback; an invalid selection is a compile error | selection revisions in the unit tag |

## E. Consumers of the erased projection

| consumer | module | what it reads | note |
| --- | --- | --- | --- |
| evaluation oracle | `Codegen.Eval` | lowered and simplified SSA | asserts simplification preserves evaluation (`typed-ir: eval`) |
| dumps / remarks | `Codegen.Dump`, `Compiler.Remarks`, `Diagnostic.Remark` | SSA, pass decisions | `--remarks=json`, remark version 1, includes input digests |
| Sol / bytecode | `Sol.*` | typed and erased programs | out of scope for the native migration, but a consumer to inventory before the projection is removed |
| reporting | `Compile.hs` summary lines | per-unit facts | the source `tools/pipeline-baseline.py` parses |

## Facts ledger

Who owns each fact today. "Gap" is what the roadmap's P1/P2 replace.

| fact | produced today | consumed today | invalidated by | gap |
| --- | --- | --- | --- | --- |
| value ranges, relational bounds | `Codegen.Interval` | `Codegen.Simplify`, checks | any store the model cannot name | interval facts do not exist before lowering; typed passes re-derive them |
| sizes and result relationships | `Resource.ResultSize`, `Workers.ScalarSignatures`, `Core.Opt.PairReturns` | allocation equations, admission | clone creation, inlining | three producers, no shared summary |
| escape, aliasing, uniqueness, lifetimes | `Reuse.hs` (erased), `Ownership.Shape`, `Arc` | reuse, TRMC, regions | any rewrite of the body | ownership is solved per pass, not carried |
| call targets, effects, blocking | `Mono`, `Core.Typed.Callback.*`, `Core.Analysis.Scope` | specialization, fusion, scheduling | new clones | no effect vocabulary (R3) |
| representation and calling conventions | `Workers`, `KernelKinds`, `Codegen.Calling`, `Compiler.Native.Representation` | layout, loads/stores, adapters, accounting | target change, new clone | `KernelKinds` re-derives what typed Core already knew (P2's target) |
| control flow, loop structure, execution bounds | `Codegen.LoopForm`, `LoopOptimize`, `Bounds` | motion, placement, timing | unrolling/vectorization | facts stop at the SSA boundary |

## Cache identity

A unit's identity is its file name
(`Compile.hs`, `emitUnit`): `u-<12 source hash>-p<8 prelude hash>-s<8 shapes hash>`
`-c<coreCacheIdentity>-<tag>.s`, where `tag` is

```text
g<codegenRev>           Codegen.hs's codegenRev: bumps on ANY emitted-code change
-tirbe<backend>         target + selection/interface revision + nativeOptionFlags
<optimizationFlags>     Compiler.Options: every pipeline switch, spelled as an absence flag
rt3pc5-c<12>            runtime revision + contractHash (precond/sig contract context)
-<tname>                interface revision per profile/target spelling
[-rvv] <vectorOptionFlags> [-builtin] [-arc<arcRev>]
```

`coreCacheIdentity` (`Core.CacheIdentity.coreCacheIdentityWithProducts`) hashes
the *reachable lowered input*: referenced definitions, external call arities,
pool resetters, elided stubs and checked product parameters. Remarks carry the
same idea for review: `remarkInputsVersion 1` with an FNV-1a digest per input
file.

Consequence for the refactor: a pass that adds an input must add it here, or
warm caches will serve code the new pass never saw. `tools/pipeline-baseline.py`
records the observed `ccore4-` identities per corpus entry, so a change in what
enters identity is visible as a diff.

## Owning stage for each proposed change (P0 exit criterion)

Every overhead the roadmap and the
[fixed-cost proposal](2026-11-06-FIXED-COSTS-PROPOSAL.md) name, with the stage
that owns it and the fixtures that pin its behaviour. Positive fixtures are
corpus entries (`tests/pipeline/corpus.json`); negative fixtures are the
existing checks that must keep refusing the unsafe case.

| change | owning stage | must preserve | positive fixture | negative fixture |
| --- | --- | --- | --- | --- |
| typed-only inlining / specialization / normalization (P4) | `typed.inline`, `typed.specialize` | clone identity, tick per call, R4 order | `helpers`, `specialization` | `tests/check_typed_inline.py`, `tests/check_typed_callbacks.py` |
| list/vector fusion (P4) | `typed.listfusion`, `typed.fusion` | allocation counts of direct cases; shared/effectful materialization | `list_map`, `list_filter`, `list_fold` | `tests/check_list_materialize.py`, `tests/check_list_fusion.py` |
| catalog convergence of spellings (P4; the iteration form is a separate proposal) | `typed.listfusion` | equivalent source spellings converge on one catalog plan | `list_length_rev`, `tree_sum` | `tests/check_list_helpers.py` |
| case-of-known (P5) | `typed.caseknown` | evaluation and trap order | `option_loop` | `tests/check_case_known.py`, `tests/check_typed_case.py` |
| literal check folding, dominated checked-operation reuse (P5) | `codegen.simplify` | first-trap order, effect order | `option_loop`, `fib` | `tests/check_interval.py`, `tests/check_fold_scalars.py` |
| range-driven bounds/overflow discharge (P5) | `codegen.interval` | trap where its operation is | `byteloop` | `tests/check_interval.py` |
| guarded invariant motion (P5) | `codegen.loopoptimize` | no motion of reads across writes/safepoints; pressure | `list_fold` | `tests/check_early_loops.py`, `tests/check_registers.py` |
| unboxed loop-carried values (P5) | `codegen.allocate` + `typed.layout` | spills must not silently become the cost | `tuple_loop`, `pair_ret` | `tests/check_tuple_scalars.py`, `tests/AllocIR.hs` |
| scalar/private workers (P3) | `erased.workers` → typed planning | public entry stays general; refused specializations still run | `fib`, `imported_wrappers` | `tests/check_workers.py`, `tests/check_scalar_wrappers.py` |
| product returns / register ABI (P3) | `erased.pairreturns`, `codegen.calling` | adapters at every boundary | `pair_ret` | `tests/check_product_returns.py`, `tests/check_nested_base_returns.py` |
| imported wrapper adapters (P3) | `typed.close`, `codegen.calling` | imported contract distinguishable from checked fact | `imported_wrappers` | `tests/check_imported_carriers.py` |
| TRMC + reuse (P4) | `typed.trmc`, `erased.reuse` | lifetime/accounting, no reuse across a resetter | `list_length_rev`, `strbuild` | `tests/check_trmc.py`, `tests/check_reuse.py` |
| tick placement and batching (P6) | `codegen.placement` | every cycle ticks; yield trace vs contract | `pingpong`, `xpingpong` | `tests/check_tick_batch.py`, `tests/Placement.hs` |
| stack capacity checks (P6) | `codegen.stack`, `codegen.frame` | failure timing, growth and refill paths | `xpingpong` | `tests/check_native_stack.py`, `tests/check_linked_stack.py` |
| allocation capacity and region room (P6) | `codegen.heap`, `erased.regions` | lifetime/accounting rules | `tree_sum`, `list_map` | `tests/check_heap_budget.py`, `tests/check_resource_admission.py` |
| defined failures (R2, R6) | `frontend.precond`, traps in `lower` | blame text, exit status, partial output | `defined_failure_divide` | `tests/check_resource_domains.py` |
| no silent untyped fallback (P2) | `lower` | every emitted unit lowers natively | all corpus entries (`coverage.complete`) | `tests/check_native_required.py`, `tests/check_typed_ir_coverage.py` |
| stale facts are refused (P1) | all analyses | invalidation or recomputation | — (baseline re-record) | `tests/check_viewcache.py`, `tests/check_native_insns_ratchet.py` |

## Duplicate authority: what P2–P6 removes, and its live consumers

| module | still live because | removal gate (roadmap) |
| --- | --- | --- |
| `KernelKinds.hs` | `Codegen.Lower` re-derives raw-word signatures from erased Core | P2: turn into an agreement checker, then remove when every native path consumes carried kinds |
| `Workers.hs` | erased worker/wrapper discovery | P3: checked representation plan covers scalar workers |
| `Representation.hs` | ARC/raw type and representation specialization | P3: migrate into checked planning |
| `Inline.hs`, `Mono.hs` (compatibility) | compatibility bodies and ARC units | P4: typed-only optimization for the first complete corpus |
| `Core.Opt.Fusion`, `Core.Opt.Normalize`, `Core.VectorRead` | erased fusion/normalization | P4 |
| `Codegen.Place` | conservative placement for profiles the allocator does not cover | P5/P6 (retain target-specific selection) |
| overlapping shallow-stack / entry / shrink-wrap / region-room switches | `Codegen.Policy` per-feature flags | P6: retire once the common framework covers them, after default qualification and a bounded rollback period |

## Corpus and baselines

`tests/pipeline/corpus.json` names 19 entries over the roadmap's categories:
recursion (`fib`), byte scan (`byteloop`, `string_scan`), filter/map/fold
(`list_map`, `list_filter`), materialized/shared lists (`list_fold`,
`list_length_rev`), Option and product loops (`option_loop`, `tuple_loop`,
`pair_ret`), persistent trees (`tree_sum`), imported wrappers
(`imported_wrappers`, a checked-in module pair), higher-order calls (`helpers`,
`specialization`), actor messages (`pingpong`, `xpingpong`), linear strings
(`strbuild`), vector reads (`vecread`) and a defined failure
(`defined_failure_divide`).

```sh
tools/pipeline-baseline.py --record       # write bench/pipeline-baseline.json (this host)
tools/pipeline-baseline.py --check        # behaviour must match; same-compiler metrics compared
tools/pipeline-baseline.py --check fib    # one entry
tools/pipeline-baseline.py --record --target=rv64   # RV64 compile facts only: bench/pipeline-baseline-rv64.json
tests/pipeline/reference_audit.py --record          # C/GHC reference audit: bench/pipeline-reference-audit.json
```

The baseline records, per entry: exact stdout digest, exit status and required
stderr fragments; runtime cost counters (allocation requests/bytes, copies,
turns, receives); generated assembly bytes and instruction lines; per-function
frame, spill, slot, loop and `native-insns-v1` segment facts; per-unit native
coverage and `ccore4-` core identities; cold-compile wall time and GHC heap
allocation; and the remark stream counted by pass, kind and outcome.

Behaviour is the contract: a mismatch always fails. Metrics are gated only when
the compiler binary is the one the baseline was recorded with (a new compiler
changes code by design, and the drift is printed for review). Timing is
recorded, never gated — `tools/bench.py` owns the timing ratchet. Targets that
are not the recording host are written down as unverified.

`--target` records a cross target's compile facts without running anything;
its file lists the target's behaviour as unverified. Which C or GHC ratio may
serve as an acceptance target is decided by the
[reference audit](2026-11-08-PIPELINE-REFERENCE-AUDIT.md) (8 November), not by
the raw `-O2` numbers.

## Reference to the roadmap's first reviewable changes

1. This inventory + fixtures + semantic policy: **this document**,
   [semantic policy](2026-11-07-PIPELINE-SEMANTIC-POLICY.md),
   `tests/pipeline/`, `tools/pipeline-baseline.py`, `bench/pipeline-baseline.json`,
   `bench/pipeline-baseline-rv64.json` and the
   [reference audit](2026-11-08-PIPELINE-REFERENCE-AUDIT.md). P0 is complete.
2. P2 full-signature bridge with `KernelKinds` as an agreement checker — next
   (the roadmap's amended order); it must add its inputs to the identity
   described above. Slice 1 landed 8 November
   ([record](2026-11-08-P2-SIGNATURE-BRIDGE.md)): checked kinds carried beside
   `KernelKinds` and compared, with no code change. Slice 2 (same day) made
   them the scalar worker authority and part of cache identity, with
   `KernelKinds` as the assertion, still with no code change. Slice 3 gave
   the field-pass workers their source's checked kinds: no unchecked worker
   remains in the corpus or sweep. Slice 4 admits components only the checked
   kinds can type (pass-through parameters), verified by
   `KernelKinds.verifyComponent`. Slice 5 gives named vector callbacks the
   same checked authority.
3. P6 composed-work report from `Codegen.Placement`, in parallel.
4. P1 checked summary schema with its first range/result-size consumer.
