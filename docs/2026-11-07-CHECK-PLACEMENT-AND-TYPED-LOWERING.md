# Check placement and typed lowering: two structural changes before the next optimizations

Date: 2026-11-07. Kind: proposal, with its first slice implemented in the
same change. Base: FP-RISC `8af12a2` (the frameless-entry slice, default off);
measurements on Apple M4, macOS, the `-O1` `./fpr`.

Planning follow-up: the [pipeline refactoring roadmap](2026-11-07-PIPELINE-REFACTORING-ROADMAP.md)
expands these two changes into staged evidence preservation, representation
planning and pass-retirement work. It supersedes the ordering of the
unimplemented architectural slices below; the implemented slice and its
measurements remain the historical baseline.

The question behind this page (docs/ISSUES.txt, 7 November): are there
bigger changes that would make the fixed-costs plan
([2026-11-06-FIXED-COSTS-PROPOSAL.md](2026-11-06-FIXED-COSTS-PROPOSAL.md))
simpler, and is there room for MLton's approach, whole-program compilation
with defunctionalization and monomorphization, extended so that everything
FP-RISC adds to a function (fuel ticks, stack checks, region room, overflow
checks) is gathered in one place and extracted systematically.

## Summary

Two changes, in this order:

1. **One check-placement pass on the native IR.** Every obligation a
   function owes the runtime is already an explicit IR operation
   (`OSafepoint`, `OStackCheck`, `ORegionRoom`, the checked arithmetic).
   What is missing is amounts and one placement rule. Today the batching
   of those obligations lives in four places with four notions of a bounded
   body. The pass replaces them and makes steps 1, 3, 4 and 5 of the
   fixed-costs plan instances of one mechanism.
2. **Lower from the typed program, not the erased one.** The pipeline
   closes and specializes a typed whole program, erases it, then re-derives
   representations and clones on untyped Core before lowering. The erased
   side carries a second inliner, fusion pass, normalizer and vector-read
   pass. The 2026-10-26 structural checkpoint already names typed global
   cloning as the next major requirement; this page makes it the second
   change and gives it a first slice.

Whole-program emission in MLton's sense is not proposed: the gains it is
known for are mostly already taken by typed passes, and the unit cache,
the frozen content-addressed modules and the compile budget push the other
way. Defunctionalization of the remaining generic applies waits for a
dynamic count.

Slice 1 of change 1 is in this change: the batched fuel tick moved from
erased Core (`Core.Opt.Ticks`, deleted) into lowering
(`Codegen.Placement`), where it sees the CFG it reasons about. The
behaviour it preserves and the gates it passed are recorded at the end.

## Evidence

### Where the batching lives today

| Obligation | Batched by | Level | Its bounded-body rule | Flag |
|---|---|---|---|---|
| Fuel tick | `Core.Opt.Ticks` (self-looping functions) and `Workers.batchTicks` (scalar workers) | erased Core | 1024 Core nodes | `FPR_NO_TICK_BATCH` |
| Fuel tick | `OSafepointN` before SIMD pairs and compaction strips | `Codegen.Kernel` | the kernel's own arithmetic | none |
| Allocation room | `$regionMark`/`$regionRoom` per loop and call region | Core region passes | the region's cost equation | `FPR_NO_LOOP_REGIONS`, `FPR_NO_CALL_REGIONS` |
| Stack headroom | shallow stack, shrink wrap, frameless entry | native frames | frame size and callee set, three ways | `FPR_TYPED_IR_SHALLOW_STACK`, `_SHRINK_WRAP`, `_FRAMELESS_ENTRY` |
| Overflow check | `Codegen.Interval` discharge | native IR | difference bounds | `FPR_NO_INTERVAL` |

Five mechanisms, 29 `FPR_` flags in `Compiler.Options`, 16 of them
typed-IR modes. The instruction accounting a placement pass needs is
already emitted for every function: the `native-insns-v1` line gives the
longest instruction segment between safepoints.

### What a real program carries

`examples/logbook.fpr`, warm unit cache, `fpr build --keep`, 7 November:

| | root unit | 45 std units |
|---|---|---|
| functions emitted | 309 | 2,865 |
| fuel-tick slow paths (`fpr_fuel_save_local` and `fpr_fuel_exhausted` references) | 1,154 | 10,236 |
| stack-growth checks (`fpr_stack_grow`) | 309 | 2,865 |
| allocation refills (`fpr_alloc_save_local`, `fpr_alloc`) | 585 | 4,733 |
| generic apply sites (`fpr_apply`) | 62 | 399 |

Every function checks its stack at entry. Ticks average almost four per
function because inlined callees bring theirs. Generic apply is already
the exception: typed closure conversion (`Core.Typed.Close`), whole-program
monomorphization (`Core.Typed.Monomorphize`) and callback specialization
(`Core.Typed.Callback`) take the cases MLton's defunctionalization is known
for. Every function in the build is lowered by the typed IR (`typed-ir
coverage 301/301` and the same for each unit); no function takes a
translation fallback.

### The duplicated passes

| Erased Core | lines | Typed program | lines |
|---|---|---|---|
| `Inline.hs` | 309 | `Core/Typed/Inline.hs` | 223 |
| `Core/Opt/Fusion.hs` | 121 | `Core/Typed/Fusion.hs`, `ListFusion.hs` | 239, 1,056 |
| `Core/Opt/Normalize.hs` | 183 | `Core/Typed/Normalize.hs` | 157 |
| `Core/VectorRead.hs` | 20 | `Core/Typed/VectorRead.hs` | 28 |
| `Mono.hs` | 298 | `Core/Typed/Monomorphize.hs`, `Specialize.hs`, `Callback.hs` | 180, 182, 389 |
| `KernelKinds.hs` (re-solves raw-word kinds) | 107 | the typed signatures | |
| `Representation.hs` (builtin/ARC representation inference) | 1,057 | `Core/Typed/Layout.hs` | |
| `Workers.hs` | 639 | | |

About 5,200 lines on the erased side whose information the typed program
had before erasure. `Codegen.Lower` receives signatures only for private
workers; every other parameter and result is the tagged word.

## Change 1: one check-placement pass on the native IR

### The pass

Input: a lowered function (`Codegen.IR.Fn`) after `Codegen.LoopForm`.
For the function and for each natural loop (`Codegen.ControlFlow`), the
pass computes the body's demand:

- ticks: how many entry ticks the body executes per iteration or
  activation (one per inlined callee today);
- allocation: bytes requested per iteration, from the constructor cells
  and the region cost equations that already exist;
- stack: the frame plus the deepest non-recursive callee chain, from the
  frame layouts the backends already compute;
- instructions: the segment length `Codegen.Bounds` reports.

Placement: when the body's demand is bounded, one combined check at the
loop header or the entry covers the body, and the body's own checks go.
On A64 the combined form is one hart-cell load, one subtract with the
amount, one compare against the region slab and one branch; the amount is
carried by the existing `OSafepointN` and by an amount on the stack and
room checks, which do not have one yet.

### The contracts it keeps

- **Fuel counts function entries**, `FUEL_QUANTUM = 2000` per slice
  ([2026-10-02-SCHED-MODEL.md](2026-10-02-SCHED-MODEL.md)). A header check
  of N ticks charges the same N; dropping an inlined callee's tick in a
  bounded recursive body is the rule `Core.Opt.Ticks` already applied,
  now with the CFG in view.
- **The instruction segment between safepoints stays bounded**: the
  `native-insns-v1` segment is the placement condition, measured in the
  unit the contract is stated in instead of Core nodes.
- **Region room is checked before the bytes are used**: the room check at
  the header asks for the iteration's bytes, as the loop regions do now.
- **Stack headroom is checked before the frame is used**: an entry check
  that covers the callee chain is what shrink-wrap and shallow stack
  approximate separately.
- **Overflow checks do not batch.** A trap's identity is semantic, and the
  flags-based form measured as a loss. They stay per operation and take
  the fold-and-share step of the fixed-costs plan.

### What it replaces

The entry emission in `Codegen.Lower` (`OStackCheck`, `OSafepoint`), the
Core tick pass, the region-room special case in lowering, the kernels'
private tick arithmetic, and the shallow, shrink-wrap and frameless triad.
Steps 1 (frames), 3 (loop-invariant checks), 4 (fuel per chunk and in a
register) and 5 (allocation path) of the fixed-costs plan become instances
of this pass instead of five mechanisms with five flags.

### Slices

| Slice | Work | Gate |
|---|---|---|
| 1 (this change) | Move the batched fuel tick from Core into `Codegen.Placement`; delete `Core.Opt.Ticks` | `tests/Placement.hs`; `tests/check_tick_batch.py`; the unbox benchmarks' assembly tick for tick against the previous compiler |
| 2 | Amounts: `OSafepointN` at loop headers for the ticks of a bounded body (today they are dropped, not counted); tick-for-tick traces unchanged in total | the evaluator differential on safepoint counts; `segmax` unchanged |
| 3 | Stack headroom as an amount at the entry covering the non-recursive callee chain; retire the three stack modes into the pass | the stack/unwind checks of the frameless slice; `fib` worker instruction count |
| 4 | Region room at loop headers from the pass, with the region cost equations as the amount; the Core region lowering special case goes | the region placement suites; flat resident memory over the swarm ticks |
| 5 | Fuel per chunk under the section 4b contract (`min(remaining, fuel-1)` at the chunk head), then the x27 register fuel with QOS | adversarial traces; QOS ratchet and the Pi window |

## Change 2: lower from the typed program

### Today

```
typed closed program (Close, Monomorphize, Specialize, Callback, Inline, Fusion, Trmc)
  -> Erase
  -> erased Core (Mono, Inline, Workers + KernelKinds, Reuse, ReceiveTurns, regions)
  -> Codegen.Lower (signatures: workers only; everything else TVal)
  -> native IR passes -> selection, frames, assembly
```

`KernelKinds` re-solves which parameters are raw words; `Representation.hs`
infers representations a third way for the builtin and ARC profiles; the
inliner, fusion and normalization exist on both sides because the erased
side still runs them for compatibility bodies.

### Proposed

`Codegen.Lower` takes the typed closed program's functions with their
checked signatures. The erased projection remains only as the
compatibility boundary for declared compatibility clauses, and shrinks as
those go. The receive caveat stands: `receive : Int -> a` is typed by its
use, so constructor tests on received values stay; typed lowering emits
them from one place and never trusts the static type to remove them
(the fixed-costs proposal measured that trust as within noise).

### Slices

| Slice | Work | Gate |
|---|---|---|
| 1 | Carry the checked signatures of every function through erasure into `Lower`'s signature map; `KernelKinds` becomes a check of the carried kinds, then goes | identical workers chosen on the unbox corpus; compile budget |
| 2 | Typed inlining and fusion only: the erased `Inline.hs` and `Core/Opt/Fusion.hs` run on no checked function | the compatibility count per build is zero on the std corpus; list-fusion suite |
| 3 | `Mono.hs` retired for `Core.Typed.Monomorphize` (the checkpoint's requirement) | clone provenance in the remarks; `$spec` symbol counts |
| 4 | Builtin and ARC representation from `Core.Typed.Layout`; `Representation.hs` goes | builtin and ARC suites on QEMU and the Tang Nano |

### Baseline, 7 November

- 55,564 lines of Haskell in `compiler/`; 11,006 lines of runtime C.
- The erased-side passes in the table above: about 5,200 lines.
- `examples/logbook.fpr`: 33 s warm build (`fpr build`), 45 units, every
  function typed-IR lowered, 0 translation fallbacks.
- `tests/check_compile_budget.py` holds the allocation baseline each
  slice must state its delta against.

## Not proposed

- **Whole-program emission.** Units are content-addressed and frozen,
  cached as assembly; the prelude exports global entries and imported
  private bodies are read-only templates. Whole-program emission drops the
  cache and the general ABI on every export for 62 generic apply sites in
  the logbook root. The closed-world facts that would help the placement
  pass across units (frame size, allocation demand, tick count per
  exported function) can travel in the unit metadata the build already
  writes beside each unit.
- **Defunctionalization now.** One dynamic counter on the generic apply
  entry over the logbook and the swarm game decides it. Under one percent
  of calls, it is not worth a representation change.
- **Trusting static types in tests, flags-based overflow, guard pages,
  a polled flag, an LLVM backend**: unchanged from the fixed-costs
  proposal.

## Order

1. Change 1 slice 1 (this change), then slices 2 and 3.
2. Fold and share checked operations (fixed-costs step 2), independently.
3. Change 2 slice 1, which also hands the placement pass the typed
   signatures slice 3 of change 1 wants for callee frames.
4. Change 1 slices 4 and 5; change 2 slices 2 to 4.

Each slice keeps its `FPR_NO_<NAME>` flag until the differential has run
on every target, joins the default-build differential and states its
compile-budget delta. The two changes are months each; the design page is
this one, and each slice records itself here or in its own dated page.

## Slice 1 record: the batched tick moves into lowering

What changed:

- `compiler/Codegen/Placement.hs` (new): `placeTicks`, applied in
  `Codegen.Lower.lowerFn` after `formSelfLoop`, before the
  evaluator/simplifier boundary. A function is recursive when it has a
  natural loop or a direct call to itself (`OCall`, `OCallProduct`,
  `TTailCall`). When it is, and its body is within `tickBodyBound`
  (1024 IR instructions and terminators, the same number the Core pass
  used in Core nodes), every `OSafepoint` goes except the entry's leading
  checks and the closing tick `LoopForm` leaves on the back edges of a
  formed loop. After the strip the pass checks that every natural loop
  still contains a tick, and leaves the function untouched otherwise.
  `Codegen.Simplify` keeps its rule that it never moves, merges or removes
  a tick: the oracle it is compared against already has the placed ticks.
- `Codegen.Policy` gains `polTickBatch` (from `FPR_NO_TICK_BATCH`, cache
  suffix `-notickbatch` as before). `Core.Opt.Ticks` is deleted; the
  `BatchTicks` Core pass and `Workers`' batch parameter go with it.
- `tests/Placement.hs` (new): a self tail loop with an inlined callee in
  the body and in the exit arm keeps one tick (two with early loops, the
  back-edge tick), the rollback keeps three; recursion that is not a loop
  drops its inlined tick; a non-recursive function keeps its; a body above
  the bound is untouched; every loop still ticks; values, calls and traps
  match tick on and off; fuel disabled is untouched.

What stays the same: the granularity recorded in
[2026-11-02-TICK-BATCH.md](2026-11-02-TICK-BATCH.md) (one fuel unit per
iteration and per entry of a recursive function; non-recursive code and
calls that were not inlined unchanged).

What is different from the Core pass: the recursion test sees the IR
(a direct self call or a natural loop) instead of a Core spine; the body
bound is in IR instructions; a loop formed by `FPR_TYPED_IR_EARLY_LOOPS`
is batched like any other, where the Core pass ran before loop formation.

Gates: see "Results" below.

### Results

Apple M4, macOS, 7 November, the previous `./fpr` (built at `8af12a2`)
kept beside the new one.

- **Assembly tick for tick.** `fpr compile --system=posix` of the eleven
  unbox benchmarks and `examples/logbook.fpr` (45 units), for `rv64` and
  `a64mac`, with fresh caches for each compiler: 24 of 24 outputs byte
  identical, units included (fuel slow paths: 376 to 592 per benchmark,
  11,390 in the logbook). The IR rule reproduces the Core rule on this
  corpus exactly; the cases where they differ (a loop formed by early
  loops, a self call the Core spine test did not see) do not occur in it.
- **`tests/check_tick_batch.py`**: all four checks pass (unbox outputs
  identical on and off; the fused `list_sum` worker 1 tick batched, 3
  unbatched; the fused `list_filter` loop 1 batched, 6 unbatched; a
  spinning batched worker still preempted on 1 and 4 harts).
- **`make unit-tests`**: 42 of 42 suites pass, `Placement` among them.
  Two suites (`KernelIR`, `NativeStack`) did not compile before this
  change: `8af12a2` added `nmFramelessEntry` and `cfgFramelessEntry`
  without updating them. Repaired here.
- **Compile budget** (`tests/check_compile_budget.py`, allocation, 10%
  margin over the baseline of `8cabb16`):

  | program | previous `./fpr` | this change |
  |---|---|---|
  | hello | +9.8% | +9.9% |
  | std-live | +10.0% | +10.2% |
  | pos1 | +4.4% | +4.5% |

  The gate fails on std-live by 0.2 points. Ten of those points predate
  this change (measured with the previous binary on the same day); this
  change adds 0.1 to 0.2 points, the inlined ticks that are now lowered
  before they are dropped. A first version ran the CFG analysis for
  every function that inlined a callee and cost 0.8 points on std-live;
  the pass now analyses only functions with a jump to their entry, a
  direct self call, or under early loops. Whether to re-record the
  darwin baseline, which the drift since `8cabb16` already calls for, is
  left to the owner.
- Not run: the QEMU and board suites, the hosted CI matrix on Linux
  x86-64, QOS. The change is in the hosted lowering only; builtin
  profiles have no fuel and are untouched by construction (the pass
  returns at once when `polFuel` is off; `tests/Placement.hs` checks
  that).
