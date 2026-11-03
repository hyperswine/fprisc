# TRMC on the typed IR: where B2 has to live

Date: 3 November 2026. Kind: design; changes no compiler behaviour. Closes the
open *Placement* item of [the B2 record](2026-11-03-TRMC.md) and supersedes its
"revisit" sentence with a plan.

Implementation update, later on 3 November: the [typed TRMC implementation
record](2026-11-03-TYPED-TRMC-IMPLEMENTATION.md) supersedes the proposed freshness
check and records the hosted default implementation. The design below is kept
as the original plan; builtin/ARC is still a later gate.

## Why the Core pass cannot reach the copies (measured)

`mapGo f xs acc = case xs of Nil -> reverse acc | x :: r -> mapGo f r (f x :: acc)`
over 100 elements, allocations reported by the cost probe:

| build | requests |
| --- | --- |
| default | 300 |
| `FPR_NO_INLINE=1` (compatibility inliner off) | 300 |
| `FPR_NO_SPEC=1` (callback specialization off) | 200 |

So the transform is right and the loop that *runs* is a copy made later. Two
facts pin the stage:

1. `trmcProgramWithImports` applied to the artifact program before `Mono`
   returns **no** notes: the recognizers do not match the pre-pipeline Core
   shape, so "run it earlier" silently does nothing today.
2. The executed loop is inside `$typed.mono.<owner>.<n>`, a clone named by
   `Core/Typed/Callback.hs:121` — i.e. created after the Core pipeline, from
   the callee's body substituted at its call site.

`append` improves on every profile because nothing clones or inlines it. Any
fix that keeps the transform on Core keeps losing to whichever pass makes the
next copy; the transform has to run where the final bodies are.

## What the typed IR buys

- **Stability.** `linkedResult` (`compiler/Compile.hs:933-949`) is the end of
  the copy-making chain: list fusion, callback specialization, inlining,
  specialization again, known-constructor cases, vector reads, normalization,
  vector fusion. A pass appended there sees the shapes that are emitted.
- **Real uniqueness evidence.** Core's soundness argument is "root and last are
  freshly allocated by construction". The typed IR carries `LShape`
  (`exprShape`), so the accumulator can be *checked* linear instead of assumed
  fresh; a non-linear accumulator is refused.
- **Per-function verification and re-erasure.** `Core.Typed.Verify` and
  `replaceClosed` already re-check and re-erase exactly the definitions a pass
  touched, so a new node costs one verification case, not a new invariant.
- **A profile it cannot reach today.** `optTrmc` is gated on `not (tgtArc tgt)`
  (`compiler/Codegen.hs:345`), so `builtin`/`--arc` never get TRMC. A typed
  pass is profile-agnostic.

## Design

### 1. One new node: `SetField Expr Int Expr`

Core has `OSetField Int VId VId` already (`compiler/Codegen/IR.hs:186`), and
`Codegen.Lower:636` recognises `$trmc.setTail`; the typed IR has no in-place
store. `PlannedUpdate` is **not** a substitute: `plannedUpdate` in
`Core/Typed/Erase.hs:267-279` rebuilds a `CMk` (a fresh allocation), which is
the cost TRMC exists to remove.

Touch points, each one case:

- `Core/Typed/Syntax.hs`: new `Node` constructor.
- `Core/Typed/Walk.hs`: `mapChildrenM` case (all binders see it).
- `Core/Typed/Verify.hs`: base is a constructor cell with more than `index + 1`
  fields, the value's type is that field's type, and the base is linear.
- `Core/Typed/Erase.hs`: `CApp (CApp (CVar "$trmc.setTail") base) value`. That
  spelling is already an accepted internal form in `Codegen.hs:184` and lowers
  to `OSetField 1`, selected as one word store on A64/X64/RV64 — no new
  backend work and no `abirev` change.
- Legacy/compatibility lowering refuses the node: it can never come from
  source.

### 2. `Core/Typed/Trmc.hs`, shaped like `ListFusion.fuseListClosed`

Recognition, in typed terms:

- a function of arity ≥ 2 with a parameter `acc` that is (a) only matched to
  test `Nil`, (b) consed onto in argument position, and (c) never otherwise
  mentioned;
- every non-trapping leaf is `reverse acc`, `revOnto acc tail`, or the same
  with one final cons onto `acc` — the recognizers of `Core.Opt.Trmc`, retargeted
  at `Match`/`Alternative` with `ConstructorPattern`, and verified against the
  catalog templates rather than a bare name (as `ListFusion` does);
- every recursive occurrence is a saturated self-`Apply` in tail position whose
  `acc` argument is `Var acc` or `Construct "Cons" [hd, Var acc]`.

Rewrite:

- **entry**: keep `(ps)`; at each exit leaf emit
  `Match CaseMatch [acc] [Alt [ConstructorPattern "Nil" []] [] tailExpr,
   Alt [Bind rest] [] origCall]`, and at each consing recursive call, after the
  arguments are bound in source order, allocate `cell0 = Construct "Cons" [hd,
  Nil]` and tail-call the worker with `(root = cell0, last = cell0)`;
- **`$worker.trmc.<f>`**: parameters `ps[i] := root, last`; each consing step
  allocates one cell, `SetField last 1 cell`, and recurses; `Nil`-tail exits
  return `root`; non-`Nil`-tail exits `SetField last 1 tailExpr` and return
  `root`. No branch on `last` — it is non-empty by construction.

### 3. Where it runs, and what retires

Append `Linked.trmcLinked` after `Linked.fuseLinked` in `linkedResult`, gated
by `FPR_NO_TRMC`. Two ordering constraints:

- **After list fusion.** B1 matches std combinator shapes; a rewritten `mapGo`
  is no longer that shape, so running TRMC first would silently decline every
  fused pipeline.
- **After both specializations and inlining.** That is the whole point.

The Core loop transform is retired in the same change: with both enabled a
rewritten body would be planned again, nesting workers. `Core.Opt.Trmc`'s
`append` rewrite has the same exposure (it rewrites call sites inside `append`)
and moves with it. `FPR_NO_TRMC` keeps covering the whole feature; the Core
pass's `optTrmc` field goes away with it.

`--remarks` keeps its `# trmc: loops=<n> appends=<n>` line, emitted from the
new stage.

## Gate

- `tests/check_trmc.py`: the default-profile rows must flip — `map` 3,000 →
  2,000 and `filter` 2,000 → 1,500 — and the same numbers must hold with
  `FPR_NO_INLINE=1` (today that row is 3,000 and proves nothing). The
  `FPR_NO_SPEC` rows stay as the transform's own baseline; `append` stays
  3,500 → 2,500. Keep the differential (output, trap order, non-`Nil`
  accumulator) and the multi-target assembly checks.
- New typed unit test next to `tests/TypedIR.hs`: worker created, entry
  transitions into it, `SetField` verifies and erases to `$trmc.setTail`, a
  non-linear accumulator is refused.
- Full differential on the recorded program set (`check_list_fusion`,
  `check_raw`, `check_pair_raw`, the Base suite): fusion must still fire, so
  this run also proves the ordering constraint above.
- `tests/check_compile_budget.py`: a new whole-program typed pass on every
  compile, so record the delta `--tracked` in the same commit.
- `codegenRev` bump (cache identity). No `abirev` change.

## Staging

1. `SetField`: node, verification, erasure, walker. No pass; accept/refuse
   tests only.
2. `Core.Typed.Trmc` for the loop transform, opt-in (`FPR_TYPE_TRMC=1`), Core
   pass disabled while it is on. Measure the probe above: 300 → 200 and 200 →
   the point of the exercise, `map`/`filter` 2,000/1,500 with specialization on.
3. Flip the default, delete the Core loop transform, port `append`.
4. Enable for `builtin`/`--arc` — the profiles the Core pass never served.

## The `builtin` gate is not a one-line win (measured)

`optTrmc` also blocks `tgtArc` and requires fuel, so `builtin`/QOS never get the
Core pass. Widening the gate was tried and is a **no-op**: on a builtin-ARC
program with a direct-call accumulator loop the pass reports `# trmc: loops=0`
(no plan) while `# tick batching` still fires, because the body it is handed is
already ARC-lowered — a nest of `$arc.retain`/`$arc.release` lets whose branch
condition is a bound variable, not the `CTagEq` the recognizer wants:

```
CLet l211 ($arc.retain xs) (CLet l213 ($arc.retain acc) ...
  (CLet l218 (CTagEq 2 0 l217) (CLet l247 ($arc.release l217)
    (CIf (CVar l218) ... ))))
```

Reaching that shape is not a recognizer tweak either: linking a tail in place
changes ownership, so the transform would have to thread ARC retain/release
through the worker. The honest placement is *before* erasure — the typed IR —
which is where this plan puts it, and which is also what makes `builtin` a
stage-4 gain rather than a separate Core hack.

## Rejected alternatives

- **Recognizer work plus an earlier Core placement.** The recognizers must be
  widened to the pre-pipeline shape *and* the pass still runs before the
  callback specializer, so the copy returns with the next clone policy change.
  It also leaves `builtin` unserved.
- **Telling the specializer to leave accumulator-reverse loops as calls.** Cheap,
  but gives up callback specialization for exactly the hot list loops; the two
  effects cancel or invert and the win becomes a measurement accident.

## Risks

- Two implementations of one transform (double rewrite): retired in the same
  slice, not "later".
- Linearity: a list that escapes through a branch, is stored, or is aliased
  must not be linked in place. `Verify` must refuse rather than assume; the
  differential suite is the oracle, as it was for B1's trap-order work.
- Compile time: typed passes are per artifact over the whole program; gate it
  like the others and record the budget.
