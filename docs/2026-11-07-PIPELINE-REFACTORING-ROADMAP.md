# Pipeline refactoring: preserve evidence, consolidate optimization

Date: 7 November 2026. Status: proposed implementation roadmap. Baseline:
`6761b28`. This document adds no compiler behavior and does not mark the phases
below complete.

The objective is a pipeline in which checked type, representation, ownership,
effect and resource information survives until its last consumer. Optimization
passes should share analyses and explicit contracts rather than discard facts,
reconstruct them, or recognize the same feature independently at several levels.

This is an architectural implementation plan for the
[resource contracts, WCET and QOS roadmap](2026-11-07-RESOURCE-CONTRACTS-WCET-AND-QOS-ROADMAP.md).
It expands the two changes in
[check placement and typed lowering](2026-11-07-CHECK-PLACEMENT-AND-TYPED-LOWERING.md).
The resource roadmap still owns user-facing contracts and target qualification;
this document owns the internal architecture and removal of duplicate machinery.

## Baseline and intended architecture

Today, typed closure conversion, monomorphization, specialization, inlining and
fusion precede erasure. Erased Core then has additional inlining, fusion,
normalization, worker construction and representation inference before native
SSA. Native lowering receives rich signatures for private workers, while other
boundaries largely use tagged values. The November 7 investigation identifies
about 5,200 lines of erased-side machinery whose inputs overlap information
already available in the typed program. That is an investigation scope, not a
promise to delete every line.

The target is:

```text
Source
  -> checked typed Core and checked function interfaces
  -> typed specialization, inlining and collection optimization
  -> explicit representation and ownership plan
  -> typed SSA with semantic operations and runtime obligations
  -> shared analyses, simplification and loop optimization
  -> runtime-obligation placement and concrete lowering
  -> target selection, registers, frames and linked-image analysis
```

Keep a high-level typed IR and a lower-level SSA IR. They serve different
purposes; one universal IR or one universal optimizer is not required. Reuse
`Core.Typed.Syntax` and `Codegen.IR` where possible. Preserve the unit cache,
public ABI and native backends. Whole-program knowledge does not require
whole-program emission.

Portable facts cross stages through stable identities and checked translations.
Machine costs are derived after the transformations that determine them; an
early source estimate is never relabeled as a final stack or cycle certificate.

## Semantic rules to settle before migration

1. **Types and trust are distinct.** A declared type is not evidence that an
   unchecked receive or foreign value has the matching runtime representation.
   Record validation provenance; retain checks where that evidence is absent.
2. **Preconditions and fast-path guards differ.** A false value precondition
   raises its defined failure. A failed optimization guard selects the original
   path. An unproved finite resource contract refuses compilation/admission.
3. **Effects need a precise vocabulary.** Distinguish total computation,
   potentially trapping computation, immutable reads, mutable memory effects,
   allocation/reclamation, external operations and scheduling events. Track
   alias/lifetime dependencies as well as effect categories.
4. **Ordering rules are explicit.** Specify first-trap and observable-effect
   order, including the existing fusion overflow-order relaxation in
   `Core.FusionPolicy`. Resolve that policy once; no pass silently broadens it.
5. **Scheduling obligations survive optimization.** Define the current tick
   policy, including existing bounded-body batching, and which transformations
   must preserve exact yield traces versus a separately specified scheduling
   contract. Equal total tick counts alone do not prove equivalent yielding.
6. **Failure behavior belongs to placement legality.** Moving allocation or
   stack checks may change failure timing. Resource reservations must preserve
   the selected semantics and lifetime/accounting rules, not just final output.
7. **Profiles remain explicit.** Hosted Base/QOS, builtin, ARC and RV32 have
   different runtime policies. A shared optimizer takes a policy; it must not
   infer ownership, fuel or stack behavior from the instruction set alone.

## Phase P0 - Semantic inventory and reference baselines

**Deliver:** a pass inventory with input/output IR, facts consumed/produced,
effects permitted, fallback behavior and cache identity. Establish a representative
corpus: fib, byte scan, filter/map/fold, materialized/shared lists, Option/product
loops, persistent trees, imported wrappers, higher-order calls and actor messages.

Record outputs, failure/effect traces, allocation counts, code size, spills,
native segments, compiler allocation/time and timing distributions. Use existing
evaluators and target oracles, documenting their unsupported operations and
shared implementation assumptions. Audit C/GHC reference work and optimization
before treating ratios as acceptance targets; distinguish scalar/vectorized and
checked/unchecked references.

**Replace/delete:** nothing yet. Establish one semantic policy document and
reference fixtures instead of letting each new pass define its own policy.

**Exit:** each hot overhead and proposed transformation has an owning stage,
an observable-behavior contract and a meaningful positive/negative fixture.

**P0 complete (8 November).** The exit criterion holds: every overhead and
proposed change has an owning stage, a behaviour contract and positive/negative
fixtures (inventory, "Owning stage"), and all 19 corpus contracts pass on
`d308c1b`. The [reference audit](2026-11-08-PIPELINE-REFERENCE-AUDIT.md)
checks every C/GHC reference (same answers, SIMD, checked vs unchecked,
optimized out, fused) and names which ratio may be an acceptance target. RV64
compile facts are recorded in `bench/pipeline-baseline-rv64.json`; RV64
execution, the Pi 4B and the Tang Nano stay unverified, reported and never
passed. The semantic policy's four open decisions were settled the same day
(policy, "Decisions (8 November 2026)"): one narrow fusion relaxation, a
scheduling contract rather than an exact yield trace, resource failure
reported earlier only within limits, and validation as an explicit SSA
operation. `tests/pipeline/check_policy_decisions.py` runs D1 and D2.

**P0 artifacts (as first written on 7 November).** The
[pass inventory](2026-11-07-PIPELINE-PASS-INVENTORY.md) covers the stage order,
per-pass input/output IR, facts, effects, refusal and cache identity, the
owning-stage map required by the exit criterion, and the live consumers of each
module P2-P6 retires. The [semantic policy](2026-11-07-PIPELINE-SEMANTIC-POLICY.md)
is the single policy document the phase asks for, with its undecided items
listed rather than assumed. `tests/pipeline/corpus.json` holds the 19-entry
corpus over the categories above, each with its observable-behaviour contract
and the negative fixtures that must keep refusing; `tools/pipeline-baseline.py`
records and checks behaviour, allocation counts, code size, spills, native
segments, compiler allocation/time and timing, and the drift it does not
explain is printed rather than hidden. C and GHC reference ratios are still
unaudited, so no ratio is an acceptance target yet, and no target beyond the
recording host has been recorded.

## Phase P1 - Shared facts, summaries and invalidation

**Deliver:** checked function summaries and a demand-driven analysis manager.
Use interned type/layout identities and compact evidence references rather than
copying large types or proofs onto every instruction.

| Analysis domain | Shared consumers |
| --- | --- |
| Value ranges and relational bounds | Preconditions, arithmetic checks, indexing, iteration counts |
| Sizes and verified result relationships | Collection optimization, allocation equations, WCET |
| Escape, aliasing, uniqueness and lifetimes | Scalar replacement, reuse, regions, message boundaries |
| Call targets, effects and blocking | Specialization, fusion, scheduling and resource composition |
| Representation and calling conventions | Layout, loads/stores, adapters and physical accounting |
| Control flow, loop structure and execution bounds | Motion, vectorization, placement and timing |

These remain cooperating analyses with separate transfer functions. Define how
facts are joined, how recursion reaches a conservative fixed point, and when an
analysis returns unknown or hits its budget. Every transformation reports facts
preserved, remapped or invalidated. Debug validation deliberately exercises stale
evidence and requires rejection or recomputation.

Function summaries include parameter domains, result-size facts, effects,
resource equations, boundary trust and provenance. Serialize relevant summaries
with versioned unit metadata and dependency hashes. Changes invalidate dependent
proofs. Imported assumptions are distinguishable from checked facts.

**Replace/delete:** ad hoc summary formats and duplicated discovery only after
their consumers use the shared interfaces. Keep specialized solvers behind those
interfaces; do not rewrite all analyses into one solver.

**Exit:** direct/imported/partial/escaped calls retain contracts; edits invalidate
warm-cache evidence; structured diagnostics identify the failing dependency.
This is shared work with resource milestones R1 and R4, not a second summary system.

## Phase P2 - Preserve typed evidence through lowering

**Deliver:** a checked bridge from typed Core to SSA carrying concrete signatures,
nominal identities, value origins, domains, validated-representation facts,
ownership and source locations. Extend SSA metadata/types only where a consumer
needs them. Preserve physical application/saturation and argument evaluation order.

First carry evidence alongside the existing path and check agreement. Then lower
checked functions directly. Keep erasure as an explicit compatibility projection
for remaining consumers; it must not remain the optimization authority for native
checked functions. Inventory Sol/bytecode, reporting and other consumers before
removing the projection itself.

**Replace/delete:** turn `KernelKinds.hs` reconstruction into an agreement checker,
then remove it after every supported native path consumes carried kinds. Stop
reinferring signatures in lowering. Retain boundary validators for untrusted values.

**Exit:** all supported native profiles lower from checked evidence; no silently
untyped fallback; precondition, malformed boundary, partial-application and target
width tests pass. Initial migration should retain code shape where possible so
representation changes are reviewed separately.

## Phase P3 - One representation and ownership planner

**Deliver:** a plan for scalar values, scalar products, concrete heap objects,
closures, tagged boundary values, call conventions and explicit adapters.
Choose private representations from types plus escape/ownership evidence and
target register constraints. Keep generic/public entries where the ABI requires
them. Plan recursive groups consistently; unsupported groups retain a correct
general representation with an explicit reason.

Migrate in slices: scalar workers; unary wrappers; products and return values;
closures/captures; container payloads; builtin/ARC layouts. Use the existing
imported-wrapper and persistent-container successes as preservation gates.
Allocation, conversion, ownership and stack consumers read the same plan as
emission. Public source contracts continue to describe the public representation.

**Replace/delete:** migrate `Workers.hs`, `KernelKinds.hs` remnants and overlapping
`Representation.hs` inference into checked planning. Consolidate
`Core.Typed.Layout`, carrier/transport decisions and native representation
adapters without deleting their necessary boundary rules. Remove old modules
only when there are no production consumers and the new plan covers their profiles.

**Gate on every slice, not only at exit:** QOS pairs with a pinned fprisc and
carries frozen std units, and the most recent pin trials were no-go. A P3 slice
changes calling conventions, so before it is promoted the QOS check-all must be
green at a stated pin pair (fprisc commit, qos commit), recorded in the merge
record. A slice that cannot be paired is not promoted; it waits, it is not
excused.

**Exit:** producer/consumer pairs share an unboxed convention without independent
heuristics; crossing public/foreign/actor/arena boundaries generates correct
adapters; allocation and layout reports agree with emitted storage. Refused
specializations remain executable via the general path.

## Phase P4 - Consolidate high-level optimization and collection lowering

**Deliver:** one typed implementation of inlining, monomorphization, callback
specialization and normalization. Run interacting transformations to a bounded,
measured fixed point, with change tracking rather than repeatedly traversing the
whole program. Preserve complete checked clone identity and provenance.

An internal iteration representation for recognized collection operations
(state, step, termination, element production, predicates, accumulators,
effects, trap policy and materialization requirements) is **not part of P4**.
It is a new IR and a research risk of its own: stream fusion under another
name. The catalog-template fusion in `Core.Typed.ListFusion` and
`Core.Typed.Fusion` already covers the direct map/filter/range/fold cases, and
P4's job is to make that the only implementation. The iteration form gets its
own dated proposal, admitted only when it names a concrete case the catalog
cannot express and a corpus fixture for it; until then "equivalent source
spellings converge" is measured against the catalog, and a spelling the catalog
misses is a catalog entry first. Shared outputs and effectful callbacks keep
requiring materialization or refusal of fusion either way.

**Replace/delete:** remove erased `Inline.hs`, `Core/Opt/Fusion.hs`,
`Core/Opt/Normalize.hs`, `Core/VectorRead.hs` and `Mono.hs` from checked native
paths, then delete only after compatibility consumers migrate. Retain catalog
identity checks and semantic safety rules as front-end admission.

**Exit:** existing direct/let/helper/imported fusion cases retain allocation
results; shared/effectful cases retain correct behavior. Equivalent source
spellings converge to the same catalog fusion plan. Typed specialization retains
generic fallbacks and compiler/image budgets. Fusion is not declared complete
merely because one benchmark no longer allocates.

## Phase P5 - Precise effects and SSA optimization

**Deliver:** operation effects and ordering dependencies usable by common
simplification, value numbering, motion and dead-code elimination. Avoid one
global effect chain that prevents independent work from optimizing.

Implement, in order: literal-check folding; reuse of identical successfully
executed dominating checked operations; range-driven bounds/overflow discharge;
guarded invariant motion; unboxed loop-carried values; vector eligibility.
Reuse existing interval and control-flow algorithms behind shared analysis APIs.

**Replace/delete:** replace blanket restrictions such as treating every trapping
operation as unshareable with explicit legality queries. Consolidate overlapping
logic in `Codegen.Simplify`, `Interval`, `LoopOptimize` and string/vector paths;
retain target-specific selection and genuinely distinct analyses.

**Exit:** signed extrema, negative division, zero-trip loops, competing traps,
intervening output, mutable aliases and unsupported received values preserve
their contracts. Record register pressure and spills: fewer operations must not
silently become more memory traffic. The fixed-cost proposal's emitted-code
examples become structural regression fixtures, not hand-assembly promises.

## Phase P6 - One framework for runtime obligations

**Deliver:** explicit obligations for scheduling, stack capacity, allocation
capacity, value contracts and safe accesses, with separate legality rules.
Use shared loop/call demand and dominance analyses to discharge or place them.
Lower the retained obligations into concrete runtime operations late enough to
avoid repeated checks introduced by inlining and specialization.

Proceed separately: proven redundant checks; bounded stack demand across calls;
region room; scheduling placement. Symbolic stack demands are resolved after
frame/spill layout, with a final check that placement still covers actual demand.
Runtime slow paths, stack relocation and allocation failure remain accounted.

Register fuel is a separate ABI change. Audit generated code, C, scheduler,
loader, foreign callbacks, migration and Sol JIT boundaries. Chunked fuel remains
blocked until its work/yield/trap boundary contract is proved; equal tick totals
or final output are insufficient. Do not combine it with the representation migration.

**Replace/delete:** grow `Codegen.Placement` beyond its landed tick slice, then
retire overlapping shallow-stack/entry/shrink-wrap/region-room policy switches
when the common framework covers them. Keep backend frame mechanics and ABI
wrappers. Remove old feature flags only after default qualification and a bounded
rollback period; do not accumulate permanent alternate pipelines.

**Exit:** zero/one/many iterations, fuel around exhaustion, early exits, stack
growth, failed refill, cancellation and multi-worker migration pass behavioral
checks. Report composed work between scheduling boundaries, including unknown
runtime calls. Requalify QOS/Pi behavior before promoting ABI or scheduling changes.

## Phase P7 - Resource admission and target timing integration

**Deliver:** a checked provenance chain from source contracts through iteration
and representation plans to selected instructions and the linked image.
Physical heap/stack accounting uses actual layouts, adapters, runtime and frames.
Loop facts map to final edges; transformations that invalidate mappings must
regenerate evidence or refuse timing admission.

The simple-risc timing model consumes final control flow, addresses and verified
execution bounds. It adds pipeline/cache/SDRAM/runtime assumptions; shared compiler
facts do not supply that hardware model. QOS admission composes turn execution,
blocking, dispatch and interference under its specific deployment contract.

**Replace/delete:** remove duplicate admission-side reconstruction where structured
compiler evidence suffices, but retain independent linked-image checks. Never
replace an independent check solely with the producer's unchecked assertion.

**Exit:** the resource roadmap's bounded callback has one traceable source-to-image
report; stale image/ABI/target evidence refuses; RV32 Tang and ARM64 QOS evidence
remain separately qualified. General persistent/concurrent admission follows
the resource roadmap, not the completion of this refactor alone.

## Dependency and delivery order

```text
P0 -> P2 -> P3 -> P4
 |     |
 |     +-> P1 (with its first consumer) -> P5
 |
 +-> P6 (placement growth, in parallel from P0)
P3/P4/P5/P6 -> P7
```

P2's bridge does not depend on P1: it needs the closed program's layouts and
`KernelKinds` turned into an agreement checker, nothing more. P1's summary
schema and analysis manager land with their first real consumer (P5's
range-driven folding, or P3's escape facts), never ahead of one. P6 operates on
SSA, whose shape P2 and P3 do not change, so the placement pass grows in
parallel from today; composed work between scheduling boundaries is what the
fixed-cost proposal and the resource roadmap both need next, and it must not
wait behind the representation migration. P5's local checked-operation
improvements can begin after P2 while P3/P4 migrate higher-level work. Existing
low-risk instruction selection fixes need not wait. Shared analyses are
introduced by their first real consumer; an unused framework before the
vertical slices work is a defect, not progress.

First reviewable changes:

1. P0 semantic/pass inventory and fixture identities (landed as the P0 artifacts above).
2. P2 full-signature bridge, with old reconstruction as an assertion.
3. P6 composed-work report from `Codegen.Placement`: the longest safepoint-free
   path through a slice across calls and returns, emitted per function beside
   `native-insns-v1`, with unknown runtime calls reported as unknown.
4. P1 checked summary schema plus its first range/result-size consumer, in the
   same change as P5's literal check folding.
5. P3 scalar representation plan, replacing one worker path end to end, with its
   QOS pairing gate.
6. P5 dominated checked-operation reuse.
7. P4 typed-only optimization for the first complete corpus, deleting its erased path.

Each change names the old production path it removes or the specific removal
gate it advances. Transition flags select old/new implementations for comparison;
they must enter cache identity. Do not combine multiple semantic or ABI changes
in one promotion. Broader representation, iteration and placement slices follow
only after their immediate predecessors have useful measurements.

## Relationship to the November 6-7 documents

| Document | Role after this roadmap |
| --- | --- |
| [Performance at e138e65](2026-11-06-PERFORMANCE-AT-E138E65.md) | Historical measured baseline and workload selection; refresh matched measurements, do not overwrite history |
| [Fixed costs proposal](2026-11-06-FIXED-COSTS-PROPOSAL.md) | Concrete code-quality targets: selection stays backend work; folding/motion feed P5; fuel/allocation placement feed P6; hand edits are experimental evidence only |
| [QOS A64 FP context](2026-11-06-QOSAPP-A64-FP-CONTEXT.md) | Mandatory ABI regression: preserve all required callee-saved context across park/resume/migration, including C-generated uses of FP registers |
| [Frameless entry](2026-11-07-FRAMELESS-ENTRY.md) | Reusable backend mechanism for P6; default-off, currently slower measured variant is not a completed performance improvement |
| [Check placement and typed lowering](2026-11-07-CHECK-PLACEMENT-AND-TYPED-LOWERING.md) | Landed tick migration remains the baseline; this roadmap supersedes the ordering of its unimplemented architectural slices and expands their deletion gates |
| [Resource/WCET/QOS roadmap](2026-11-07-RESOURCE-CONTRACTS-WCET-AND-QOS-ROADMAP.md) | R1/R4 share P1 summaries; R2/R3 use P4/P5 facts; T1 uses P3/P7 layouts; T2-T4 supply independent hardware timing; Q1-Q3 consume P6/P7 evidence |

The November 5 [zero-overhead completion record](2026-11-04-ZERO-OVERHEAD-COMPLETION.md)
remains a set of scoped achievements to preserve, not evidence that every
representation or fusion case is solved. Existing heap/stack and imported-wrapper
qualification must survive migration. No historical evidence automatically
qualifies the new compiler/runtime pair.

## Validation, completion and scope

Gate correctness separately from speed: values, defined failures, allowed effect
traces, ownership/lifetime behavior and the chosen scheduler semantics. Include
negative controls for stale facts, bad adapters, missed ticks and resource
undercounts. Preserve independent target oracles and linked-image checks.

`tools/pipeline-baseline.py` gates code and allocation metrics only when the
compiler binary is unchanged, by design; this refactor is nothing but compiler
changes, so during it the tool prints drift and gates nothing but behaviour.
The gate is therefore a review step: every phase exit, and every slice that
changes emitted code, carries in its merge record the tool's drift lines with
one explanation each (which pass, why the number moved, whether it was
intended). Unexplained drift blocks promotion. A re-recorded baseline names the
commit it was recorded at and the explanation it closes.

Publish warmed/interleaved performance medians and variability, compiler
allocation/time, emitted size, spills, allocation counts and segment bounds.
Separate process startup, steady-state work and instrumentation overhead.
Keep PR CI within the existing budget; use dedicated jobs for broad differential,
RTL and physical-device qualification. A missing tool or unavailable board is
reported as unverified, never a passing gate.

Architecture completion means checked native functions have one authoritative
typed optimization path, one representation plan, explicit fact invalidation,
shared analysis APIs and no production dependence on retired reconstruction.
It does not mean every program is unboxed, vectorized, statically bounded or
hard real-time. General programs keep correct explicit fallbacks.

This is a multi-month migration. Estimate each vertical slice after P0, and
re-estimate after the signature bridge and first representation replacement.
Prioritize removing duplicate authority and demonstrably improving hot code;
do not use lines deleted as the sole measure of success.

## Amendments, 7 November 2026 (review)

A review of the proposed roadmap against the landed placement slice and the
resource roadmap changed four things; the text above is already amended.

1. **P1 no longer gates P2.** The bridge needs layouts and `KernelKinds` as a
   checker, not an analysis manager. P1 lands with its first consumer.
2. **P6 runs in parallel from P0.** The placement pass is on SSA, which P2 and
   P3 leave in shape, and composed work between scheduling boundaries is the
   next input both the fixed-cost proposal and the resource roadmap need.
3. **The iteration form leaves P4** for a proposal of its own, gated on a case
   the catalog cannot express.
4. **Two gates added:** a QOS pairing gate on every P3 slice, and a line-by-line
   drift explanation at every phase exit, since the baseline tool gates no
   metric across compiler changes.

A note on the 5,200-line figure: it counted ARC, Representation and Regions as
investigation scope. The eight modules the inventory names for retirement
total about 2,900 lines. Neither number is a deletion target.
