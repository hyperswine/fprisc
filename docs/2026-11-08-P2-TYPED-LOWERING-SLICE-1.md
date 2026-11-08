# P2 typed lowering, slice 1: lower checked functions beside erasure

Plan, 8 November 2026. Phase P2 of the
[pipeline refactoring roadmap](2026-11-07-PIPELINE-REFACTORING-ROADMAP.md)
says: first carry typed evidence beside the existing path and check
agreement, then lower checked functions directly, keeping erasure as an
explicit compatibility projection. The
[signature bridge](2026-11-08-P2-SIGNATURE-BRIDGE.md) (slices 1 to 5, all on
main) did the first half for signatures: checked kinds decide scalar workers
and named vector callbacks, `KernelKinds` verifies instead of inferring, and
every disagreement is a compile error. This page plans the first slice of the
second half: a lowering that reads the typed program.

## Where P2 stands

| Fact | Today |
|---|---|
| `Codegen.Lower` input | erased `Core` after the erased pipeline (`Core.Opt.Pipeline`: fusion, workers, normalize, reuse, pair returns), itself after `Mono`, ownership and regions |
| Types in `Lower` | a signature map for private workers only (`TInt`/`TVal` per position); every other value is `TVal` |
| Checked kinds | carried in `ProductParameters` (7th field), authority for workers and named vector callbacks |
| `KernelKinds` | the verifier (`verifyComponent`) and the lenient solver for lambdas and record-map fields; cannot be deleted until nothing needs its check |
| Typed program at emission | in scope in `Compile.hs` (the Regions `Result` holds the `NativeCore`, whose `ClosedProgram` has every checked definition, its code functions, contracts, layouts and `TypeContext`), but not passed to `Codegen` |
| Typed evidence at the boundary | `Core.Typed.Erase.eraseFunctionAnnotated` and `Compiler.Native.Core.annotatedProgram`: an owner may attach checked facts to erased nodes; `Compiler.Native.Representation` is the one consumer |

The erased passes are still the optimization authority for native checked
functions, which the roadmap's P2 exit forbids. Moving them is P3 and P4
work; this slice does not touch them.

## What slice 1 delivers

A second lowering, `Codegen.LowerTyped`, from a typed `Core.Typed.Syntax.Function`
to the same `Codegen.IR.Fn` that `Codegen.Lower` produces, for a first class
of functions. It runs beside the erased lowering at the erasure boundary and
must produce the same SSA. Nothing emitted changes. The class, the agreement
check and its counts become a gate that later slices widen.

This is the same shape as bridge slice 1: carry, compare, stop the compile on
disagreement, change no code. Bridge slice 2 then made the carried facts the
authority; typed-lowering slice 2 will do the same for this class.

## Today's path, with the new step

```
typed closed program          Core.Typed.Pipeline (Close, Monomorphize, Specialize,
                               Callback, Inline, Fusion, Trmc)
  -> Compiler.Native.Regions  regions, interfaces (Core.Region.Interface)
  -> eraseDefinitionsWith     erased Core per definition      <- slice 1 compares HERE
  -> Mono, own (Arc), ready
  -> emitProductProgramWithImports
       Core.Opt.Pipeline      fusion, workers (+ checked kinds), normalize, reuse, pair returns
       nativeSelect           vecSpec (+ checked kinds), lowerProgram
       Codegen.Lower          erased Core -> Fn
  -> native IR passes, selection, frames, assembly
```

The comparison point is the erasure boundary, not `Lower`'s input, on
purpose. Between the two, `Mono`, `Inline`, workers and reuse rewrite bodies
(fib's public entry becomes a guard around its worker). Comparing at the
boundary isolates one question: does lowering the typed body give the SSA
that lowering its erasure gives? What the erased passes do to the body is a
separate question, answered when each pass moves (P3, P4).

## The slice

### Step 0: census

Before any lowering, classify every checked definition the build emits and
print one note per unit:

```
# typed lowering census: T1=<n> int-bool-with-calls=<n> products=<n> strings=<n> lists=<n> closures=<n> matches=<n> polymorphic=<n> other=<n>
```

A definition is counted once, in its first failing class from the left. The
counts are summed over the corpus (`tests/pipeline/corpus.json`) and the
145-program sweep, with the cold per-program method the bridge record fixed.
The numbers decide whether T1 below is the right first class; if T1 is
nearly empty, the class widens before step 1 and this page records why.

### Step 1: `Codegen.LowerTyped` for class T1 (widened to S1 = t1 + calls by the step 0 record below)

T1: first-order functions over `Int` and `Bool`.

- Every parameter and the result has checked type `Int` or `Bool`.
- The body uses only these `Node`s: `Var` (a `Local` binder, or a `Global`
  that is a scalar primitive from `Lower`'s operator set or another T1
  function), `IntValue`, `BoolValue`, `BoolTest`, `Apply` (saturated),
  `Let`, `If`, `Note`, `EntryTick`, `Fail`, and `Match CaseMatch` whose
  alternatives are integer or Boolean literal patterns, a binder or a
  wildcard, with Boolean guards. `CallRegion` is admitted and lowered as
  erasure lowers it.
- Nothing else: no constructors, tuples, records, lists, strings, lambdas,
  `CodeCall`, `JoinCall`, `MatchTail`, vector nodes, `LetRec`, `ResultPipe`,
  `Sequence`, `LetPattern`.

A function outside T1 is refused with a reason naming the form, the same
discipline `Lower` uses. The lowering mirrors `Lower`'s emission for these
forms (entry block, stack check and fuel tick per policy, the same operation
and block order), so that the two `Fn`s compare equal. `Int` operations emit
the checked operations `Lower` emits; `unsafe` marks WCET only and turns
nothing off. `Bool` is `TVal` in SSA as today (the Boolean singletons);
representation changes are not this slice's business.

T1 functions still call out of the class: `Apply` of a `Global` that is not
T1 (a list function, a string primitive) makes the function not T1. This
keeps slice 1 free of the general-apply and boxing adapters, which come with
the class widening in slice 3.

### Step 2: agreement at the boundary

In `Compile.hs`, where the Regions `Result` and the erased per-definition
Core are both in hand (the same place `annotatedProgram` reads them), for
every T1 definition of the unit:

1. lower its erased body with `Codegen.Lower.lowerFn` (empty worker map,
   the unit's policy, externals and HAL arities);
2. lower its typed `Function` with `Codegen.LowerTyped.lowerFn`;
3. compare the two `Fn`s. Both lowerings start from the same fresh state
   and emit in the same order, so exact equality is the target. If only
   value and block numbering differ, the comparison renumbers in traversal
   order first and the record says so.

A disagreement is a compile error naming the function and the first
differing block, as a bridge disagreement is. `FPR_NO_TYPED_LOWER=1` turns
the second lowering and the comparison off, the escape every slice keeps
until its differential has run on every target (the
[check-placement proposal](2026-11-07-CHECK-PLACEMENT-AND-TYPED-LOWERING.md)'s
rule). Each unit prints:

```
# typed lowering: agreed=<n> refused=<n> (T1 census <n>)
```

`refused` counts T1-by-signature functions the typed lowering refused by
body form; it must be 0 once the class is as defined, so the count is a
check on the class definition, not a tolerated state.

Nothing the typed lowering produces is emitted. Generated code is identical
by construction, and the code-identity comparison against
`bench/pipeline-baseline.json` confirms it.

### Step 3: gates

| Gate | Requirement |
|---|---|
| `make unit-tests` | a `LowerTyped` suite: each admitted node form, each refusal, and a forced disagreement caught as `ErrorCall` |
| `tests/check_typed_lowering.py` (new) | corpus, host and RV64: every T1 function agrees, `refused=0`, census printed; the fixture below is counted |
| `tools/pipeline-baseline.py --check` | 22 behaviour contracts hold, code identical on every earlier entry |
| Cold 145-program sweep, both compilers | identical asm size; agreement note on every unit; same compile failures |
| `tests/check_compile_budget.py` | the delta stated in the record; a second lowering of T1 bodies costs allocation, and the record says how much |
| QOS guishell | compiles, agreement note present |
| `make stdcheck` | unchanged |

Fixture: `tests/pipeline/typed_lower_t1.fpr`, a corpus entry with several T1
functions (a tail loop, a non-tail recursion, a `case` on integer literals
with a guard, a Boolean-returning function, a `Fail` arm, an `unsafe` loop
that overflows and must trap identically). The check requires its T1 count
and 100% agreement.

### Step 4: record

A section on this page, as the bridge record did: census numbers, agreement
counts, the compile-budget delta, and what refused and why. `docs/README.md`
and the pass inventory's status list get one line each.

## Step 0 record: the census (8 November)

`Compiler.Native.TypedCensus` classifies every checked definition a unit
emits (roots and their code functions, from `nativeDefinitions` of the
unit's Regions result, minus elided names) and `Compile.hs` prints one note
per compiled unit:

```
# typed lowering census: t1=.. calls=.. joins=.. products=.. strings=.. lists=.. closures=.. vectors=.. polymorphic=.. other=.. unit=<unit file or root>
```

Each definition is counted in the narrowest rung of a widening ladder that
admits it (the module header defines each rung). Two corrections to the
plan's class list came out of the first run:

- `if` arrives in the closed program as `MatchTail` (a match with a
  fallback arm), not `If`. Counting `MatchTail` as a closure put `fib` in
  "closures". It is control flow and is judged by its patterns, like
  `Match`.
- Join calls get their own rung (`joins`), after `calls`: the closed program
  makes join points explicit, and a typed lowering turns join code into
  blocks, which is separate work from closures.

The unit name lets shared units (prelude, std) be counted once. Method:
each program compiled cold, its own cache and output directory, 150
programs (examples, benchmarks, `tests/base`, the corpus); the same 6
programs fail to compile as before.

| Rung (cumulative, polymorphic and other excluded) | All 34,304 definitions, shared units once | Program code only (root units, 3,675) | Corpus, 22 entries (6,702) |
|---|---|---|---|
| t1 | 492 (1.4%) | 109 (3.0%) | 364 (5.4%) |
| + calls | 2.9% | 4.4% | 10.6% |
| + joins | 2.9% | 4.4% | 10.6% |
| + products | 37.8% | 31.3% | 40.8% |
| + strings | 50.3% | 43.9% | 49.2% |
| + lists | 56.9% | 51.8% | 52.9% |
| + closures | 69.4% | 79.7% | 58.2% |
| + vectors | 69.5% | 80.3% | 58.3% |
| polymorphic signature | 10,425 (30.4%) | 697 (19.0%) | 2,795 (41.7%) |
| other | 30 | 28 | 3 |

What the numbers say:

1. **T1 is small but not empty.** 492 definitions, including `fib`, every
   scalar loop in the corpus and the pass-through loops of
   `scalar_pass_through`. That is enough for an agreement gate, which is
   what slice 1 is for; it is not where the coverage is.
2. **`calls` doubles it for almost nothing.** A scalar function that calls
   any known function needs only the tagged call convention `Lower` already
   uses for erased `CVar` heads (`calleeOf`, `TVal` arguments and result).
   No adapter, no new SSA type.
3. **Products are the coverage.** Admitting constructors, tuples and
   records and their patterns takes the ladder from 2.9% to 37.8%. It is the
   first widening after slice 1.
4. **No scalar function uses a join call.** `joins` adds nothing at the
   scalar rungs; join points appear only together with products or later
   rungs, so they arrive with the products widening.
5. **A third of definitions keep a type variable after monomorphization.**
   These are generic functions compiled once over the uniform tagged
   representation (the prelude's list functions, for example). In SSA
   every variable position is `TVal`, as it is today, so they need no
   representation work; they need the same node coverage as everything
   else. They are counted separately so no later slice mistakes them for
   specialization failures.

**Decision:** slice 1's class is **t1 + calls** ("S1": scalar signature,
first-order, calls to any known function through the tagged convention),
1,003 definitions over the sweep. The census rungs stay in the note so each
later widening states its gain. The first widening (slice 3) is products,
with joins and the uniform polymorphic functions alongside.

Census cost: one walk over each emitted typed body per compiled unit; it
prints only and does not enter the cache identity (a cached unit prints no
note).

Compile budget (`tests/check_compile_budget.py`, darwin arm64), before
(8ad39ac) and after:

| Program | Before | After |
|---|---|---|
| hello | +10.0% | +10.2% |
| std-live | +10.3% | +10.4% |
| pos1 | +4.6% | +4.7% |

The gate was already over its 10% margin on `std-live` before the census
(the check-placement record noted the darwin budget sitting at the margin on
7 November). The census adds 0.1-0.2 points. Re-recording the darwin
baseline is the owner's decision and is not done here. Unit suites 42/42, `pipeline-baseline-check` 22 contracts and no code
drift, the bridge check and `check_compiler_options.py` unchanged.

## Step 1-3 record: the typed lowering agrees (8 November)

### What landed

- **`Codegen.Lower` shares its emission core.** It exports the emission
  state and helpers, `lowerEntry` (the entry sequence: parameters, entry
  block, headroom check, fuel tick) and `lowerGlobal` (a name no local binds).
  The erased path is unchanged; `lowerFn` is `lowerEntry` plus `lowerTail`.
- **`Codegen.LowerTyped`** lowers a checked `Function` in class S1. It first
  plans the whole body into a small tree, with one supply of scrutinee
  names. Each match is planned the way `Core.Typed.Erase` plans it:
  - the scrutinee is let-bound for `Match` and repeated for `MatchTail`;
  - patterns are tested in argument order;
  - each Boolean guard is a branch to the fallback;
  - the fallback is duplicated into every failing branch;
  - a last `True`/`False` arm whose sibling an earlier arm covers is not
    tested.

  Where erasure would build a lambda or a join, it refuses. The lowering
  then follows `Codegen.Lower` form for form, on the shared core. A
  primitive other than the integer operators is refused.
- **`Compiler.Native.TypedLowering.check`** runs per compiled unit, where
  `Compile.hs` printed the census. For each S1 definition it erases the
  owner alone (`eraseDefinitions`, now exported), lowers that erasure with
  `Codegen.Lower`, lowers the typed body with `Codegen.LowerTyped`, and
  compares the two `Fn`s for equality. The program both lowerings see is
  the boundary program plus the constructor stubs emission adds
  (`Compile.erasedConstructorStubs`): `True` and `False` arrive as global
  constructor names, not Bool literals, and without stubs they were
  misread as unknown primitives. It prints:

  ```
  # typed lowering: s1=.. agreed=.. refused=.. both_refused=.. erase_refused=.. unit=..
  ```

  A disagreement prints `typed lowering disagreement: <fn>: first differing
  block: ...` and stops the compile. `FPR_NO_TYPED_LOWER=1` keeps the census
  and skips the second lowering.
- **The census's S1 is exactly what `LowerTyped` accepts.**
  - The caller supplies the set of known functions (the program, its
    constructor stubs, the imports). Any other global is a primitive.
  - Primitives other than the integer operators, join calls, sequences,
    pattern bindings, call regions and pattern guards form one rung,
    `forms`, which replaces the earlier `joins`.
  - The step 0 totals were taken with the earlier rungs, so S1 there
    (1,003) and the counts below (760) are not the same measure.
- **Exact equality, no renumbering.** Both lowerings start from the same
  fresh state and emit in the same order.

### Evidence

| Check | Result |
|---|---|
| `make unit-tests` | 43/43; new `LowerTyped` suite: `fib`, a match tail with a literal arm, a guarded binder and a fallback, a Bool `case` with a covered last arm, a mutated erasure told apart, two refusals |
| Mutation in the compiler (integer operands lowered in swapped order) | `fib` stops the compile with its third block named; `FPR_NO_TYPED_LOWER=1` passes; restored compiler clean |
| `tests/check_typed_lowering.py`, corpus (23 entries), host and RV64 | s1=56 agreed=56 refused=0 on each target (shared units once); fixture `typed_lower_s1` 7 of 7 |
| Cold sweep, 151 programs | 766 distinct units, s1=760 agreed=760 refused=0 both_refused=0 erase_refused=0; same 6 compile failures |
| QOS guishell | s1=115 agreed=115 refused=0 |
| `make pipeline-baseline-check` (re-recorded, host + RV64) | 23 behaviour contracts hold, no metric drift |
| Bridge check, policy D1 and D2, `check_compiler_options.py`, `make stdcheck` | pass |

Compile budget (darwin arm64; the gate stays red by the owner's decision):

| Program | Before census (8ad39ac) | Census (6d06ebb) | Step 1 |
|---|---|---|---|
| hello | +10.0% | +10.2% | +10.5% |
| std-live | +10.3% | +10.4% | +10.6% |
| pos1 | +4.6% | +4.7% | +4.8% |

The second lowering of each S1 body and the per-owner erasure cost 0.1-0.3
points over the census.

### What is next

Slice 2: S1 functions are emitted from the typed lowering, and the erased
lowering of the same body becomes the assertion. The bridge pattern again.
Code must stay identical; the agreement above says it will at the boundary.
The open design point is the input: the emitted body comes after `Mono`,
ownership and the erased pipeline, not at the boundary. So slice 2 either
lowers the typed body for S1 functions that no erased pass rewrites, or
moves the comparison point. Its plan decides which, from the count of S1
functions each erased pass changes.

## What slice 1 does not do

- It does not change generated code, delete `KernelKinds`, or move any
  erased pass.
- It does not lower from `Lower`'s input; the erased pipeline's rewrites are
  compared when they move, not here.
- It does not trust static types to remove constructor tests on received
  values. `receive : Int -> a` is outside T1 by type, and when boundary
  values enter later classes the validation operation of semantic policy
  Decision 4 is where their facts come from, never the static type alone.
- It does not add new SSA types. `Int` is `TInt` only where `Lower` already
  makes it so (worker signatures); in T1 public functions every value is
  `TVal`, as today. Representation is P3.

## Risks and open points

- **T1 may be small.** Step 0 measures it. The likely widening is to admit
  calls to any known function with a tagged convention (`Callee ... TVal`),
  which `Lower` already handles for erased `CVar` heads; that brings
  `products` and `strings` bodies in without adapters. The census column
  order is chosen so this reads off directly.
- **Emission-order drift.** Mirroring `Lower` by hand is fragile; a shared
  emission core (the `L` monad, `emit`, `open`, `close`, `lowerBind`) is the
  fix, and `LowerTyped` should import it rather than copy it. If `Lower`'s
  internals need exporting for that, the slice does it; `Lower` is 797 lines
  and the shared part is the emission state, not the dispatch.
- **Compile budget.** Two lowerings per T1 body. The darwin budget sat at the
  10% margin before the check-placement slice; this slice states its delta
  and, if it crosses, re-records the baseline in the same commit with the
  number in the record (the budget tool's own rule).
- **Identity.** The agreement check is a check, not an optimization input,
  so it does not enter `coreCacheIdentityWithProducts`. A cached unit prints
  no note, the same caveat the bridge record gives for counting.

## After slice 1

| Slice | Work | Gate |
|---|---|---|
| 2 | T1 functions are emitted from the typed lowering; the erased lowering of the same body is the assertion | code identical; the bridge pattern again |
| 3 | class widens: calls to any known function, constructors, products, strings; the general-apply adapter | code identical per widening, counted per class |
| 4 | the typed lowering reads the typed pipeline's output directly, and workers (P3), pair returns and reuse (P4) are planned on typed or SSA facts; the erased lowering goes for checked functions | `KernelKinds` deleted (P2's deletion gate); erasure is a compatibility projection only; Decision 4's validation operation lands with the boundary classes |

The 7 November proposal's Change 2 table had "carry the checked signatures
of every function into `Lower`'s signature map; `KernelKinds` goes" as its
slice 1. The bridge did the carrying for the two consumers that exist, and
showed `KernelKinds` must stay as the verifier until the typed lowering is
the authority; so that row is done as far as it can be, and this page is
the continuation. Its slice 2 (typed inlining and fusion only, erased
`Inline.hs` and `Core/Opt/Fusion.hs` on no checked function) is independent
of this page and still stands.
