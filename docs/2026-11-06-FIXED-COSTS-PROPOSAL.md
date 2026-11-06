# Fixed costs: what still separates emitted code from C

Date: 6 November 2026. Kind: design proposal with measurements. It changes no
compiler behaviour. Base: main `95e2fbc`, codegen 204.

Review update: contracts and work order below were expanded on 6 November.
The original measurements and their baseline identities are preserved; no new
performance result or implementation is claimed by this revision.

It follows the [completed zero-overhead roadmap](2026-11-04-ZERO-OVERHEAD-COMPLETION.md)
and today's [performance record](2026-11-06-PERFORMANCE-AT-E138E65.md). The
roadmap removed most boxing and allocation: fused list pipelines match hand
loops, and generic code matches its hand-written form. This page asks the next
question: why is the hand-written form itself 2 to 8 times C, and what would
close that without changing the language.

## Summary and recommendation

The gap is no longer about representation. It is a set of fixed costs paid at
every function entry, loop iteration and checked operation. I measured each
one by replacing the body of one hot function in the emitted assembly with a
hand-written variant, relinking with the build's own link line, and timing
(`tests/bench/fixedcost/measure.py`, data in
`bench/2026-11-06-fixed-costs.json`; arm64 macOS, fastest of 11 interleaved
runs, process startup included: 5.1 ms for fpr, 2.5 ms for C).

- **Call-heavy code approaches this checked-add C reference.** `fib 40` goes from
  469 ms to 253 ms with the fuel tick and the overflow check both kept. C `-O2`
  is 198 ms; C with a checked add is 244 ms. The C reference does not carry
  the full FP-RISC runtime contract.
- **A byte loop can come within 1.3x of scalar C.** `byteloop` goes from 70 ms
  to 18 ms; scalar C is 13.6 ms and vectorized C is 4.8 ms.
- **Recursive data improves by a third from the same changes**, 133 ms to 88 ms
  on `tree_sum`. Allocation is a candidate for the remaining gap (C is 33 ms),
  but hand edits could not safely isolate it.
- **Three ideas measured as not worth doing now**: overflow checks on the
  flags, trusting static types in constructor tests, and removing the stack
  check. The first answer I gave on this question listed all three; the
  measurements below withdraw them.

**Recommendation.** Start with instruction selection and frames, then folding
and sharing checked operations. Qualify loop modes individually before testing
combinations. Keep register fuel as a separate, coordinated runtime/QOS ABI
change. Investigate allocation independently; defer chunked fuel until its
execution-boundary proof exists. Each implementation retains a rollback flag
and a differential gate.

Preserving `Int`, evaluation order, trap order and existing preemption points
is a requirement, not a result of these experiments. Register fuel can retain
tick locations; chunk charging needs the separate contract below before it can
make that claim. The joint order is recorded in the
[amended QOS proposal](../../qos/docs/2026-11-06-ZERO-OVERHEAD-OS-AMENDED.md#joint-order-of-work).

## Evidence

### Where the instructions go

The scalar worker for `fib` executes about 38 instructions per call; C
executes about 12. Counted from the emitted AArch64 text
(`fpr compile --system=posix tests/bench/fib.fpr`):

| Cost | Instructions | Notes |
| --- | ---: | --- |
| Stack check | 7 | two loads from the hart block, at every entry |
| Fuel tick | 5 | load, decrement, store to hart cell 0, compare, branch |
| `n < 2` | 4 | constant to a register, compare, `cset`, `cbz`; two would do |
| `n - 1`, `n - 2` | 4 | each constant goes to a register first |
| 63-bit overflow check on `+` | 4 + 1 | `sbfx`, `cmp`, `b.ne`, then a taken jump over the inline trap path |
| Frame | 9 | frame-pointer-relative restore with two extra moves |

The same shapes appear elsewhere, with larger effects:

- **Checked operations on constants are not folded.** `x % 2` in
  `option_loop` compiles to two `sdiv` instructions by a register holding 2, a
  zero test on that constant, two 31-bit fit tests and three overflow checks.
  `x / 2` is then computed a second time, with its own zero test and check.
- **Checked operations are not shared.** `build` in `tree_sum` computes `2 * k`
  twice, each with the full multiply check (about 12 instructions). The second
  cannot trap if the first did not. `Codegen.Simplify` shares pure operations
  only: "an operation that may trap, calls, or ticks is never moved, merged or
  removed".
- **Loop-invariant tests stay in the loop.** `sumB` in `byteloop` tests the Int
  bit of the string twice, its type id and the index against both bounds on
  every byte, although the string never changes and the caller passed
  `strlen s` as the limit. About 50 instructions run per byte.
- **Loop-carried Ints are retagged at the back edge** and untagged again at the
  top (`sumB`: three untags and two retags per iteration).
- **`d == 0` on an `Int` dispatches dynamically** in `build`: a tag test on both
  operands, with the generic `==` call as the other arm.
- **The inline allocation path is 22 instructions, 8 loads and 5 stores per
  cell**, before the header and fields are written (`build`): two window cells, the slab top and limit, a per-object slab
  link, a zeroed pad word, a per-bucket byte count and the hart's allocation
  clock. The C reference is an add and a store. A three-field node is 48 bytes
  against 24 in C.

`Codegen.Simplify`, `LoopOptimize` and `Interval` are 779 lines together.
That is the size of the scalar optimizer the typed IR has today.

### Hand-written experimental targets

Each row applies one more change to the row above it. Indented rows are
alternatives, not steps.

| `fib 40` | ms | vs emitted |
| --- | ---: | ---: |
| As emitted | 469 | 1.00 |
| Clean selection and frame | 338 | 0.72 |
| + no stack check | 339 | 0.72 |
| + fuel counter in x27 | 256 | 0.54 |
|   (fuel as a polled flag instead) | 247 | 0.53 |
| + overflow on flags, Int kept shifted | 303 | 0.64 |
| + frameless `n < 2` path | 253 | 0.54 |
|   (no fuel at all) | 238 | 0.51 |
| C `-O2` | 198 | 0.42 |
| C `-O1`, checked add, not inlined | 244 | 0.52 |

| `byteloop`, 40 M bytes | ms | vs emitted |
| --- | ---: | ---: |
| As emitted | 69.9 | 1.00 |
| Type test and bounds hoisted | 23.1 | 0.33 |
| + overflow on flags | 22.6 | 0.32 |
| + fuel counter in x27 | 22.7 | 0.32 |
| + fuel charged per chunk | 18.0 | 0.26 |
| + overflow checked per chunk | 18.1 | 0.26 |
| C `-O2`, scalar | 13.6 | 0.19 |
| C `-O2`, vectorized | 4.8 | 0.07 |

| `tree_sum`, 10 x depth 20 | ms | vs emitted |
| --- | ---: | ---: |
| As emitted | 133 | 1.00 |
| Walk: clean selection and frame | 106 | 0.80 |
| Walk: + `Leaf` test trusts the static type | 108 | 0.81 |
| Walk: + no stack check, fuel counter in x27 | 104 | 0.78 |
| + build: checks folded and shared, clean selection | 88 | 0.66 |
| C `-O2`, bump allocator | 33 | 0.25 |

Reading the tables:

- **Selection and frames are worth 20 to 28% on call-heavy code** and need no
  new analysis for the basic selection changes; frame placement still needs
  stack-check and unwind validation.
- **Register fuel substantially improves this `fib` variant.** In the loop,
  memory/register timings are indistinguishable here (22.6 against 22.7 ms).
  Chunk charging improves that hand-written variant, without yet establishing
  execution/yield equivalence.
- **A polled flag shows no established advantage over counted register fuel.** There is no speed
  reason to give up counted, reproducible preemption.
- **Overflow on the flags did not help.** It is neutral on `byteloop` and 18%
  slower on `fib` in one frame shape. Forcing code alignment did not remove
  that (a one-off test, not in the script), so I do not understand it yet. Its
  only sure value is two instructions
  less per check in size and in the `native-insns` bound.
- **Trusting the static type in the `Leaf` test is within noise.** The Int-bit
  branch is always predicted, as the [pin-trial record](2026-11-04-PIN-TRIAL-FIXES.md)
  already found on `list_fold`.
- **The stack check is at most 3% here.**
- **Checking overflow once per chunk gains nothing while the loop is scalar.**
  It is what would let the loop use the SIMD kernels.

### What the existing opt-in modes already buy

Seven typed-IR modes are off by default (`compiler/Compiler/Options.hs:64-71`):
`SHALLOW_STACK`, `SHRINK_WRAP`, `ENTRY_ARGS`, `SPLIT_ENTRY`, `LOOP_MOTION`,
`STRING_SCAN`, `EARLY_LOOPS`, each as `FPR_TYPED_IR_<NAME>=1`. All seven on,
against the default build:

| Benchmark | Default ms | All opt-in ms |
| --- | ---: | ---: |
| `fib` (35) | 48.1 | 47.0 |
| `byteloop` | 70.5 | 52.3 |
| `option_loop` | 49.2 | 48.7 |
| `tree_sum` | 125.4 | 124.7 |
| `string_scan` | 43.1 | 31.3 |

They take a quarter off the two string loops and nothing off the rest. The
hand-hoisted `byteloop` is 23 ms, so they reach about a third of what
hoisting can give. I did not test them one at a time.

## Proposals

### 1. Instruction selection and frames

- Branch on the comparison directly; no `cset` followed by `cbz`.
- Use immediate operands where the instruction has them.
- Place trap and slow paths after the function body, so the fast path falls
  through.
- Restore from `sp` with pre- and post-indexed pairs.
- Return from a path that needs no frame before building one. `SHRINK_WRAP`
  exists for this, but the opt-in modes together did not change `fib`; find
  out why before promoting it.

Cost: selection code in three backends. Risk: low, since the evaluator and
the per-target oracles already compare selected code with the IR.

### 2. Fold and share checked operations

- Fold a check whose operands make it constant: a literal divisor is not
  zero, `x / 2` cannot overflow, `2 * k` needs one overflow test and no
  `sdiv`.
- Reduce division and remainder by a literal power of two to shifts with the
  sign correction.
- Share a checked operation with an identical one that dominates it. The
  second gives the same value and cannot trap, so trap order is unchanged.
- Compare against an Int literal with one compare. This needs the generic
  `==` to answer False for an object against an Int; confirm that in
  `runtime/runtime.c` first.
- Keep a loop-carried Int untagged across the back edge.

This is the one place where today's rule ("never moved, merged or removed")
needs a stated exception: removal of a check that provably cannot fire, and
reuse of a dominating identical result. The first operation must have
successfully executed on every path reaching the replacement, with identical
immutable SSA operands and the same arithmetic semantics. The first possible
trap stays in place. This exception does not authorize sharing mutable loads,
allocation, runtime calls or fuel ticks.

Acceptance: differential results and first-trap/effect traces at signed extrema,
negative division/remainder inputs, zero divisors and intervening effects;
verify dominating-path and non-dominating-path cases. Record register pressure,
spills, code size and compile time so extending a value's live range does not
silently trade checks for memory traffic.

### 3. Loop-invariant checks

- Qualify `LOOP_MOTION` and `STRING_SCAN` individually, then in combination.
  Measure each of the other five modes separately before promoting it; the
  all-seven experiment does not attribute gains or establish individual safety.
- Hoist a type test on a value the loop does not change to the loop entry.
  Guard it with the original nonempty-loop condition, or version the loop
  with an unchanged slow path. A zero-iteration loop must not gain a type or
  bounds trap. Earlier effects and competing traps keep their original order.
- Discharge the index bounds from `i < n` and `n <= strlen s`.
  `Codegen.Interval` already works in difference constraints and has
  `OStrLen` producer bounds; what is missing is carrying the fact from the
  call site (`sumB s 0 (strlen s) 0`) into the callee, or a loop version
  guarded by one entry test of `n` against the length.

Target: the hand-hoisted `byteloop` figure, 23 ms, as an experimental target.
Gate zero/one/many iterations, negative and excessive limits, malformed received
values, overflow at bounds and effect/trap ordering. Check spills and
`native-insns`/`segmax` bounds on each target as well as output equivalence.

### 4. Register fuel: a separate ABI change

AArch64 may keep the counter in x27, retaining every existing tick location.
The runtime's C is already built with `-ffixed-x27` and the context switch saves
it, but those facts alone do not establish a complete fuel convention.

Before implementation, specify:

- Which copy is authoritative while generated code, runtime C and the scheduler
  execute; every entry/exit that loads or synchronizes the hart memory cell.
- Initial fuel, exhaustion handling, refill, yield/resume, stack growth, actor
  migration, traps and teardown, including nested runtime-to-generated calls.
- The convention at QOS app, loader, shared-plane and native code boundaries;
  version or reject incompatible compiler/runtime/app combinations.
- Register allocation and spill costs from losing one callee-saved register.

Gate fuel values around zero and one, repeated yields, mixed generated/runtime
calls and migration between harts. Compare exact tick and observable-effect
traces with memory fuel; re-qualify QOS's ratchet and Pi fuel window. Benchmark
call-heavy and register-heavy programs. Land this independently of loop
chunking. x86-64 and RV64 retain memory fuel pending their own measurements.

### 4b. Chunked fuel: deferred proof and experiment

`c = min(iterations left, fuel left)` followed by an upfront subtraction does
not by itself preserve preemption boundaries: exhaustion may yield before work
that previously preceded the yield. `OSafepointN` supports existing bounded
kernels; its presence is not a proof for arbitrary scalar loops.

Start only with callback-free counted loops. State the original tick position,
ticks per iteration, chunk entry/exit state, early-exit behavior, overflow and
other traps, and all observable operations. Define how partial chunks and fuel
exhaustion reproduce the original sequence of work and yields. Reject the
transformation when that equivalence cannot be shown; a deliberately relaxed
preemption profile would require a separate proposal.

Gate remaining iterations and fuel at 0, 1, c-1, c and c+1, trap/exit at every
position, nested ticks, and a competing runnable actor. Compare effect and
scheduler traces, not only final output. Preserve the instruction bound between
safepoints and re-qualify the QOS/Pi budget. The 18 ms assembly row is a timing
experiment, not evidence that this contract has been met.

Dropping ticks from bounded non-recursive functions is also deferred; it would
make the `native-insns` bound interprocedural.

### 5. The allocation fast path

Investigate before designing. The question is which of the five bookkeeping
stores must happen per cell. Candidates for per-slab accounting at refill or
region close: the hart allocation clock, the per-bucket byte count and the
second window test. The per-object slab link is what the earlier roadmap
called header-free region cells (C1 piece 3). The evidence so far is the
instruction count and the 88 ms against 33 ms left on `tree_sum`; nothing
here is measured in isolation. The residual gap does not attribute its cost
solely to allocation.

Before changing a store, map it to allocation limits, profiling, slab lifetime,
ARC and failure rollback. Measure stores/cells, refill frequency, bytes reserved
and live, plus time, in allocation-only and traversal-only workloads. Proposed
amortization must preserve the point at which caps refuse allocation, exact
account reconciliation on refill/close, and cleanup after traps or actor death.
Gate cap-edge allocations, failed refill, cancellation and teardown with no
leak, undercharge or double release. Compare object density/cache effects
separately from bookkeeping instruction changes.

### Not proposed

- **Overflow checks on the flags**: no measured gain, one measured loss.
- **Trusting static types in tests**: within noise, and it would need
  `receive` to validate its result and std/mvu's port to change. Not worth a
  language change for this.
- **Guard pages instead of stack checks**: at most 3%, and it would put a
  reserved-size bound on stacks that grow by segments today.
- **A polled preemption flag**: no faster than the counted register.
- **An LLVM or C backend**: the in-house backend carries the `native-insns`
  bounds, three instruction sets and the self-contained toolchain.

## Plan

| Step | Work | Gate | Experimental target |
| --- | --- | --- | --- |
| 0 | Repeatable baseline and matched references | Medians, variability, build identity and measurement boundaries recorded | No new result claimed |
| 1 | Selection and frames, A64 then x86-64 and RV64 | `fib` worker <=30 instructions from 38; no corpus `segmax` growth; target oracles and stack/unwind checks | `fib` 0.72 |
| 2 | Checked-operation folding and sharing | No redundant literal checks/`sdiv` in `option_loop`; one multiply in `build`; first-trap/effect differential and spill checks | `tree_sum` 0.66 includes other changes |
| 3 | Individual loop-mode qualification, then combinations | Zero-trip behavior, malformed inputs, bounds and effect order preserved; pressure and instruction bounds recorded | `byteloop` 0.33 |
| 4 | x27 register fuel, coordinated with QOS | ABI boundary audit; tick-for-tick traces; migration, runtime calls, QOS ratchet and Pi window | `fib` 0.54 mixes register fuel and selection |
| 5 | Allocation-path investigation | Per-store purpose, cap/refusal/lifetime requirements and isolated measurements before redesign | Not isolated |
| Later | Chunked fuel under section 4b's contract | Proof of execution/yield boundaries, adversarial traces and instruction bounds | `byteloop` 0.26 is not a qualified result |

Each implementation keeps its `FPR_NO_<NAME>` flag, joins the default-build
differential, and states its compile-budget delta. Steps 1 and 2 can be developed
independently; step 3 uses step 2 where bounds need folding. Register fuel lands
alone. Allocation investigation can proceed independently without authorizing
accounting changes.

### Measurement gate shared with QOS

Repeat warmed, interleaved baseline/variant runs; publish medians and variability
alongside minima, run counts, hardware, compiler/runtime commits and flags.
Separate process startup from steady-state work. Keep scalar/vectorized and
checked-add C references labelled with the contracts they actually implement.
Measure code size, spills, compile time and instruction bounds as well as wall
time. Set regression tolerances from baseline variability before promotion.
Preserve the current tables as historical experiments; add new evidence rather
than rewriting their numbers. The joint QOS gate adds latency distributions,
contention, CPU use, copy/allocation counts and pin-versus-sibling comparisons.

Filter fusion and byte or string folds that fuse like `List` remain as listed
in today's performance record. They are the route to the vectorized figure
and are not repeated here.

## Open questions

1. Is one callee-saved register on AArch64 an acceptable price for the fuel
   counter, given that QOS apps share the convention?
2. May a check that provably cannot fire be removed, and a dominated
   identical checked operation be reused? Both keep trap order, but they
   amend a rule the simplifier states today.
3. Which individual modes and combinations pass the new qualification matrix?
   The existing measurement covers only the all-seven combination.
4. Is the x86 box available for the same experiment? Its `fib` is 5.3x C
   against 2.4x here, and the memory fuel tick is the first thing to test.

## Limits of this evidence

- One machine: arm64 macOS on Apple silicon. Nothing here is measured on
  x86-64 or RISC-V, on QOS or on a board.
- The variants are hand-written assembly, not compiler output. They show a
  timing target for those variants, not a demonstrated compiler ceiling or
  qualified implementation result.
- The register-fuel variants reseed the counter instead of yielding, which is
  valid only for one actor. Trap paths are a breakpoint, never reached by
  these inputs.
- The `fib` rows vary by 5 to 10% between runs; medians are in the data file.
- The `tree_sum` builder variant uses flag-based tagged arithmetic for
  brevity, so its 88 ms mixes folding, sharing and selection.
- Each variant was checked only for identical output on the benchmark input.

## Addendum: second review, 6 November

Five adjustments from a further review. No new performance result is claimed
here; the one mechanism check added below is marked with its status.

1. **A candidate answer to the SHRINK_WRAP question.** The likely reason
   shrink-wrapping did not change `fib`: the entry checks force the frame
   before the first branch. The stack check compares `sp` against the hart
   limit and needs no frame, but the fuel tick's slow path
   (`fpr_fuel_save_local`) and `fpr_stack_grow` are calls that assume one
   exists, so the prologue builds the frame ahead of `n < 2`. The cheap
   experiment: make the slow paths self-framing (build a minimal frame only
   when taken; the performance plan's step 6 already has them saving their
   own live scratch), then re-measure SHRINK_WRAP. If the mechanism holds,
   frameless early-exit becomes a selection rule rather than a placement
   question. Status, 6 November: **verified against the emitted A64 `fib`**
   - the frame (`sub sp` / `stp x29,x30` / `stp x20,x19`) precedes every
   branch, and both entry slow paths are calls; `fpr_stack_grow` may also
   relocate the stack (`mov sp, x0` after the call), so a self-framing slow
   path must adopt the returned `sp` before building its frame, and the
   `sp`-restore precondition in point 2 is not optional.
2. **Pre/post-indexed `sp` restore needs its precondition stated.** The
   [fib gap record](2026-10-20-FIB-GAP-TO-C.md) already documents why
   epilogues rebuild `sp` from the frame pointer: with segmented growable
   stacks, a callee's growth can relocate the segment and stale register
   `sp` values. The rule is only sound when no growth can have occurred
   since the prologue - provable for leaf functions, and trackable in
   general (no stack-growth point dominates the return path). Backends
   should not implement it unconditionally.
3. **x27 fuel is missing one boundary in its checklist: the Sol JIT.**
   `Sol/HandJIT.hs` emits raw A64/x64 for recursion-scheme kernels. If x27
   becomes the authoritative counter, JIT-generated code must preserve and
   honor it, or the convention must exchange it for the memory cell around
   JIT kernel entry/exit. Add it to section 4's specification list.
4. **Replicate the `fib` ladder on x86 before locking the step order.** The
   order above is M4-derived. x86-64 has five callee-saved registers and a
   5.3x `fib` gap against 2.4x here, so the fuel and frame shares are
   probably larger there; one hour on the shared x86 box (the same host as
   the performance record) could reorder steps 1, 2 and 4. Treat that
   replication as a gate on the order, not a footnote (open question 4).
5. **Filter fusion belongs in the joint order.** The
   [performance record](2026-11-06-PERFORMANCE-AT-E138E65.md) ranks it
   first among list gaps (202 ms against 24 for fused `map`) and this page
   deliberately does not repeat it, but the QOS joint order's FP-RISC
   column should name it: it is independent, semantics-preserving, uses the
   landed fusion machinery, and can proceed in parallel with stages 1-3.

Two step-2 notes. The sharing rule should state its inversion explicitly:
for a two- or three-instruction check, recomputing at the use is often
better than keeping the value live; the spill recording covers the cost,
the policy does not. And the first slice of step 2 is best chosen by shape
frequency: the literal-divisor checks in `option_loop` (`x % 2` as two
`sdiv` plus fit tests plus a second division) are the most frequent shape
in the corpus and the cheapest to fold.

## Reproduce

```
tests/bench/fixedcost/measure.py 11 > out.json     # about 3 minutes, arm64 macOS
```

The script asserts every emitted pattern its variants rely on (hart cell
offsets, the String type id, the `Leaf` header, the allocation sequence) and
fails when code generation has changed, instead of measuring something else.
