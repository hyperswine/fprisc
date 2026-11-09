# Pipeline semantic policy

Date: 7 November 2026. Status: proposed, P0 of the
[pipeline refactoring roadmap](2026-11-07-PIPELINE-REFACTORING-ROADMAP.md).
Baseline: `d308c1b`. This document adds no compiler behavior.

This is the single place the pipeline's semantic rules are written down. A pass
either cites a rule here, or proposes an amendment to it. No pass defines a
private relaxation of evaluation order, effects, representation trust or
scheduling; today several do so implicitly, and each of those is named below.

The [pass inventory](2026-11-07-PIPELINE-PASS-INVENTORY.md) records what each
stage consumes and produces; this document records what it is allowed to assume
while doing so. Terms used there and here:

| Term | Meaning |
| --- | --- |
| fact | A statement about the program a pass may read, with a producer and an invalidation rule |
| evidence | A fact that records *why* it is known (checked, validated, imported contract, assumed) |
| obligation | A runtime duty a function owes: scheduling, stack, allocation, value contract, safe access |
| relaxation | A place where the pipeline deliberately does not preserve an order or a check |
| refusal | A compile error or a reported fallback; never a silently different program |

## Rule 1 — Types and trust are distinct

**Statement.** A declared type is not evidence that an unchecked receive,
foreign value or imported payload has the matching runtime representation. A
pass may rely on a representation only when provenance says it was checked or
validated; otherwise it must retain the check, or refuse.

**Enforcement today.** `Infer.Evidence` (`compiler/Infer/Evidence.hs`) records
binder and expression facts — identity, role, scheme, `LShape`, reference
resolution, scope — and the driver treats a missing capture as a fatal error
(`compiler/Compile.hs`, `inferenceEvidence`). `Frontend.Desugar.Typed`
(`prepareChecked`) turns that into checked typed Core; `Core.Typed.Erase` is
the only compatibility projection, and `Codegen.Lower` refuses forms it cannot
represent instead of assuming a layout. Imported units carry explicit
declarations and arities (`Compiler.Native.Imports`, `Core.CacheIdentity`'s
`CallArities`), and boundaries are bridged by generated adapters
(`Codegen.Calling`, `Codegen.Export.Plan`) rather than by shared guesses.

**Not enforced yet.** SSA values carry no machine-readable validation
provenance. "It came from checked Core" is an implicit argument, not a fact a
pass can query, and `KernelKinds` re-derives the raw-word signature
independently in lowering. P2's bridge must make provenance explicit.

**Required provenance.** Every carried fact names one of: `Checked` (produced
by typed Core), `Validated(at)` (a boundary check dominates the use),
`ImportedContract(unit, hash)` (a versioned declaration from another artifact),
`Unvalidated`. `Core.Typed.Layout`, `Core.Typed.Carrier` and
`Compiler.Native.Representation` decisions are only usable as `Checked` when
attached to the closed program that produced them.

## Rule 2 — Preconditions and optimization guards differ

**Statement.** A false *precondition* raises its defined failure. A false
*optimization guard* selects the original path. Neither is ever discharged by
assumption.

**Enforcement today.** `Precond.hs` classifies every contract obligation as
`Discharged` (proved from local facts), `RuntimeCheck` (call-site check with
blame) or `BuiltinTrap` (the operation's own trap; `/` with a possibly-zero
divisor), and the driver prints the summary line
`precond: N obligations: a discharged, b runtime-checked, c builtin traps`.
The predicate grammar is deliberately small and out-of-fragment contracts are
compile errors on the signature, not silent fallbacks. Optimization guards are
the other kind: `Core.Typed.FusionSafety`, `Core.Typed.Callback.Trim`,
`Core.Typed.CaseKnown` (declines rather than copies alternatives),
`Codegen.LoopOptimize` (speculates only total register operations into an
existing unique preheader) and `Codegen.Interval` all decline to the original
program.

**Rule.** Discharging a precondition requires a proof whose facts are recorded
under Rule 1. Dropping a guard requires proving it always true. Refusing an
unproved *resource* contract (Rule 6) is a compile/admission refusal, never a
guard failure.

## Rule 3 — Effects need a precise vocabulary

**Statement.** Passes reason about effect classes, not about "pure" and
"impure". The pipeline uses these classes:

| Class | Examples today | What a pass may assume |
| --- | --- | --- |
| Total | comparisons, Boolean operators, float arithmetic except division | may move, duplicate or delete when dependencies and observable results are preserved; totality alone does not permit reassociation |
| Trapping | `Int` `+` `-` `*` (overflow), `/` (divisor), indexing, allocation capacity | may move only where first-trap order is preserved, or under the Rule 4 relaxation |
| ImmutableRead | field/tag/string reads, `vec` element reads, hart/region reads | may move if no intervening write, allocation move or safepoint can invalidate the value |
| MutableEffect | writes reachable from a value, in-place TRMC cell writes | must keep order with every aliasing reader/writer |
| Allocation / reclamation | `$reuse.fresh`, bump windows, pool resets | changes failure timing (Rule 6) and invalidates reads of the pool |
| External | C/foreign calls, runtime entries (`$regionRoom`, `$loopLeave`) | opaque: no motion across, no duplication |
| Scheduling | entry and back-edge ticks, park/resume, receive, spawn | obligation placement only (Rule 5) |

**Arithmetic legality.** Floating-point reassociation, contraction and algebraic
identities require a separate proof preserving the specified rounding, NaN,
infinity and signed-zero behavior. Being non-trapping is not such a proof.
Integer rewrites must also preserve overflow/trap behavior.

**Enforcement today.** The vocabulary is implicit in three predicates that
agree on the trapping boundary: `Core.FusionPolicy.safePrimitives` /
`trapFreePrimitives`, `Codegen.LoopOptimize`'s "total register operations" and
`Codegen.Bounds`' safepoint boundaries. `Codegen.Simplify` keeps the rule that
it never touches a tick.

**Required.** An effect query on SSA operations with these classes, plus the
relations transformations actually need: alias, uniqueness, lifetime and
dominance. `Codegen.LoopOptimize` already demonstrates why a class alone is
insufficient — field, tag, string and hart reads are not "pure" enough to
speculate.

## Rule 4 — Ordering rules are explicit

**Statement.** Two orders are observable and are preserved unless a listed
relaxation says otherwise: **first trap** (which failure happens first) and
**effect order** (which observable effect happens first). `Codegen.Lower`
states the contract it implements: arguments evaluate left to right, each fully
before the next; a branch arm is its own block; a trap happens where its
operation is. `Core.Typed.CaseKnown` keeps evaluation and trap order while
moving alternatives. `Codegen.Placement` keeps the evaluator oracle and the
backends seeing the same ticks.

**The one listed relaxation.** Fusion may reorder `Int` `+` `-` `*`, so a
different `Int` overflow may be the one reported. It may not change whether
the program traps or what it printed first (Decision 1 below; the 7 November
wording "may trap later or not at all" was looser than what is enforced):
`Core.FusionPolicy.safePrimitives` is every unsigned/Int primitive except `/`,
and `trapFreePrimitives` names what cannot trap at all. Division is excluded
because its trap is the runtime's own.

**Rule.** The relaxation is a policy constant shared by the checked and
compatibility fusion passes; no pass widens it, and a pass that cannot prove
its ordering obligation declines. Widening it — to division, to allocation
capacity, to external calls — requires an amendment here plus a corpus fixture
that pins the new order (`tests/pipeline/corpus.json`).

## Rule 5 — Scheduling obligations survive optimization

**Statement.** Every transformation states whether it preserves the exact
yield trace or only a separately specified scheduling contract. Equal total
tick counts do not prove equivalent yielding.

**Enforcement today.** A function owes the scheduler one fuel tick per entry
and the stack one headroom check per frame; `Codegen.Lower` emits both at the
entry, an inlined callee brings its tick with it, and `Codegen.Placement` is
the only module that moves or removes such obligations. It runs inside
lowering, after `Codegen.LoopForm` and before the evaluator/simplifier
boundary, so the oracle and the backends agree. One decision lives there: the
batched tick. A recursive function (natural loop or direct self-call) keeps the
ticks that make every cycle tick — its entry's and the ones `LoopForm` leaves
on back edges — while inlined callees' ticks go when the body is bounded;
non-recursive functions keep every tick, so fuel still counts calls.
`FPR_NO_TICK_BATCH=1` rolls it back, and `polTickBatch` is part of cache
identity. `Codegen.Bounds` measures `native-insns-v1` between consecutive
safepoints.

**Required.** Passes that clone, inline, specialize, unroll or vectorize must
report which of the two they keep. The corpus records runtime `turns` and
`receives` counters so a scheduling change is visible even when output is not.

## Rule 6 — Failure behavior belongs to placement legality

**Statement.** Moving an allocation, stack or region check changes *when*
failure happens. Placement is legal only if the selected semantics, lifetime
and accounting rules are preserved — not merely the final output.

**Enforcement today.** Stack headroom per frame entry (`StackPolicy`:
`StackCheckEveryEntry`, `StackStatic`, `StackCheckShallow`), allocation
capacity at bump refills and pool resets, region room via the runtime hook
`$regionRoom`, and the admission side: `Codegen.Stack.admit`,
`Codegen.Heap.admit` (`Demand`/`Equation`, separate counts and bytes, an
unknown boundary never gets a zero cost) and `Codegen.Bounds`. Refusal is
reported: a missing board or toolchain is unverified, never a passing gate.

**Required.** A placement change needs a fixture at the boundary it moves:
zero/one/many iterations, fuel around exhaustion, early exit, stack growth and
failed refill, cancellation. `tests/pipeline/corpus.json` pins a defined
failure (division) as a behaviour contract; the tick, stack and admission
negatives stay in `tests/check_tick_batch.py`, `tests/check_native_stack.py`,
`tests/check_admission.py` and `tests/check_resource_admission.py`.

## Rule 7 — Profiles remain explicit

**Statement.** A shared optimizer takes a policy. It never infers ownership,
fuel or stack behavior from the instruction set or the word size.

**Enforcement today.** `Codegen.Policy` defines
`Profile = HostedBase | Builtin | Builtin32 | BuiltinArc | QosApp | Rv32` and a
`Policy` record (fuel, tick batching, stack policy, float inline, loop motion,
early loops, string scan, vector fast, …). `Codegen.Lower`, `Codegen.Simplify`,
`Codegen.LoopOptimize` and `Codegen.Placement` take it as an argument;
`emitProductProgramWithImports` derives the erased pipeline's
`OptimizationOptions` from the target and profile rather than from a default.
Option spellings that select a different pipeline enter unit cache identity
(`Compiler.Options.optimizationFlags`, `vectorOptionFlags`,
`nativeOptionFlags`).

**Rule.** A new policy bit is added to `Policy`, threaded to its consumers, and
enters cache identity in the same change. A profile never becomes an implicit
default inside a pass, and no pass may branch on `tgtW` to decide ownership.

## Obligation classes

| Class | Decided by | Proof is | Refusal is |
| --- | --- | --- | --- |
| Scheduling (ticks, park, receive, spawn) | `Codegen.Placement` + `Codegen.LoopForm` | every cycle ticks; bounded work between ticks | not applicable — placement is mandatory |
| Stack capacity | `Codegen.Stack` after allocation and frame layout | symbolic demand covered by the frame/linked image | a reported admission refusal |
| Allocation capacity | `Codegen.Heap` equations + bump/region room | requested bytes bounded by the region/pool | reported refusal |
| Value contract | `Precond` obligations | predicate proved from local facts | runtime check with blame, or signature error |
| Safe access | bounds facts (Rule 3, trapping class) | interval facts at the operation | the access's own trap |

## Conformance checklist for a new pass

1. Name the rule(s) it can violate, and the ordering it keeps (Rule 4).
2. State its input and output IR and every fact it consumes, with provenance (Rule 1).
3. Classify each operation it introduces or moves by effect class (Rule 3).
4. Say which obligations it can move and which it must leave to `Codegen.Placement` (Rules 5, 6).
5. Take a `Policy`; add any new bit to cache identity in the same change (Rule 7).
6. Land a positive fixture and a negative control in `tests/pipeline/corpus.json`
   or in a `tests/check_*.py`, with the observable behaviour it promises.

## Decisions (8 November 2026)

These were the four open decisions of 7 November, settled by the project
owner. `tests/pipeline/check_policy_decisions.py` runs the executable ones.
Changing one is an amendment here, with its fixture.

### Decision 1 — One fusion relaxation for every profile, and it is narrow

**Decided.** The relaxation stays one constant for every profile. Its content
is narrowed to what `tests/reliability/list_fusion_random.py` already enforces:
a fused pipeline traps **if and only if** the unfused program traps, with the
same exit status and the same output up to the trap. Only *which* `Int`
overflow is reported may differ. Fusion never adds a trap, never removes one,
and never changes a non-trapping result. `/`, allocation capacity and external
calls are outside it.

**Why.** A per-profile split adds a policy bit, a cache-identity entry and a
second behaviour to test, and the same source would fail differently on a
desktop than in a QOS app. Since whether a program fails is already identical,
a defined-failure or admission contract that cares whether a program can fail
holds in every profile. Strict order everywhere would refuse almost all `Int`
fusion (`x + 1` can overflow) unless intervals prove otherwise.

**Revisit when** a contract needs to name exactly which trap is reported. That
is an amendment adding a `Policy` bit for the profiles concerned.

**Fixtures.** Corpus entry `fusion_overflow_order`: fused, the sum overflows
first; unfused, the map does; both print `before` and trap with
`Int overflow`. `check_policy_decisions.py` (D1) builds it both ways. The
random differential (`LFR_STRICT=1` makes the relaxation fail) covers the
general case.

### Decision 2 — A scheduling contract, not an exact yield trace

**Decided.** No profile promises an exact yield trace. Every profile promises
the scheduling contract:

1. every cycle (natural loop or recursion) passes a tick;
2. every native function has a finite bound on instructions between
   consecutive safepoints, computed by `Codegen.Bounds` (`native-insns-v1`
   `segmax`).

A transformation may move, batch or remove ticks only while both still hold.

**No pipeline constant K.** The bound is a measured per-function number, not a
policy limit (the no-arbitrary-bounds rule, [bounds register](2026-09-19-BOUNDS.md)). The baseline records it for
every function. An `UNBOUNDED` function fails `tools/pipeline-baseline.py`
and `check_policy_decisions.py` (D2), and growth is drift that a phase exit
must explain. A budget comes from where it is needed: QOS response-time
admission (resource roadmap Q-phase) derives the bound it can accept from the
deadline it must meet, and refuses what exceeds it. Work inside runtime and C
calls (`ccalls`, stack growth) is not in `segmax`. It is bounded separately by
the resource contracts and not assumed here.

**Why.** No profile asserts an exact trace today, actors already interleave
nondeterministically across harts, and an exact trace would forbid the landed
tick batching as well as inlining, unrolling and vectorization. A bound between
safepoints is the quantity QOS admission consumes. Reproducible tick placement
remains available with `FPR_NO_TICK_BATCH=1`.

**Fixtures.** All 13,108 functions recorded on 8 November (host and RV64) have
a finite `segmax`. `tests/check_tick_batch.py` and `tests/Placement.hs` pin
"every cycle ticks".

### Decision 3 — Resource failure may be reported earlier, within limits

**Decided.** A region-room, pool-refill or allocation-capacity check may be
moved earlier, or merged into one reservation, past computation that can trap.
The result may be that the allocation failure is reported instead of the
trap. All of these must hold:

1. it moves past no observable effect: no output, send, receive, foreign or
   runtime call with effects, spawn or tick lies between the new and the
   original position, so no output is lost and no message is sent that would
   not have been;
2. it reserves only allocations that happen on every path from the new
   position (or the maximum over paths, refilled on the others), so no
   program that succeeded before can fail;
3. it never reserves more than the original program would have used at that
   point.

Moving a check later than its allocation is never allowed.

**Why.** Strict ordering would forbid hoisting or merging past any `Int`
arithmetic, which is most of P6's allocation-path work. Unlimited freedom
could lose printed output or fail programs that used to succeed. Within these
limits, the only observable change is which failure is reported, the same
kind of difference Decision 1 allows. An admitted program has a proven memory
bound, so its reservation cannot fail. The rule matters only for hosted
programs without one.

**Fixtures.** None executable yet: no merged reservation exists. P6's first
slice that hoists or merges a capacity check must add a corpus entry that
prints before the moved check and traps between the new and old positions,
showing the output is kept, plus a conditional-allocation case that must not
fail.

### Decision 4 — Validation is an explicit SSA operation

**Decided.** `Validated(at)` is carried by an explicit operation that consumes
a value and produces a new SSA value of the validated representation (a
refinement, like a pi node), dominated by the check that justifies it. Uses
that rely on the validation use the new name, so dominance gives the fact's
scope. `ImportedContract(unit, hash)` facts become function-entry facts of the
same form. The fact is invalidated only where the validated object can change:

- reuse or reclamation of its storage (`$reuse.fresh`, region or pool reset);
- in-place writes to it (TRMC cell writes);
- safepoints, on a profile where an object can move or be reused across one.

FP-RISC values are immutable, so nothing else invalidates it.

**Why.** A side table keyed by SSA value must be carried by every pass that
copies or rewrites values. One forgotten case leaves a stale fact, the class of
bug the 4 November typed-case fix was (a `receive`d value trusted by its static
type). An explicit operation is left alone by passes that do not understand it,
and `Codegen.Verify` can check it. Recomputing on demand cannot express facts
that come from outside the function.

**Fixtures.** Today `tests/check_typed_case.py`'s received-value cases (tuple,
`Int` and list values that must fall through) are the negative control. P2's
bridge adds the operation, its verifier rule and a stale-fact negative: a
validated value reused after a reset must be re-checked.
