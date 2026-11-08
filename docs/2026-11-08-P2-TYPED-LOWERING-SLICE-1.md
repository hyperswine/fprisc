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

### Step 1: `Codegen.LowerTyped` for class T1

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
