# Fixed costs: what still separates emitted code from C

Date: 6 November 2026. Kind: design proposal with measurements. It changes no
compiler behaviour. Base: main `95e2fbc`, codegen 204.

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

- **Call-heavy code can match C carrying the same checks.** `fib 40` goes from
  469 ms to 253 ms with the fuel tick and the overflow check both kept. C `-O2`
  is 198 ms; C with a checked add is 244 ms.
- **A byte loop can come within 1.3x of scalar C.** `byteloop` goes from 70 ms
  to 18 ms; scalar C is 13.6 ms and vectorized C is 4.8 ms.
- **Recursive data improves by a third from the same changes**, 133 ms to 88 ms
  on `tree_sum`, and the rest (C is 33 ms) sits in the allocation path, which
  hand edits could not safely isolate.
- **Three ideas measured as not worth doing now**: overflow checks on the
  flags, trusting static types in constructor tests, and removing the stack
  check. The first answer I gave on this question listed all three; the
  measurements below withdraw them.

**Recommendation.** Five steps, in this order, each behind a rollback flag and
a differential gate as before:

1. Instruction selection and frames.
2. Folding and sharing of checked operations.
3. Loop-invariant checks, starting by promoting two modes that already exist.
4. The fuel counter: per-chunk in counted loops, in a register on AArch64.
5. The allocation fast path, as an investigation first.

No step changes `Int`, evaluation order, trap order, preemption points or the
source language.

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

### Measured ceilings

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
  new analysis.
- **The fuel counter costs a quarter of `fib` in memory and nothing in a
  register.** In a loop the memory form costs nothing extra on this machine
  (22.6 against 22.7), but charging per chunk removes a fifth of the loop.
- **A polled flag is no faster than a counted register.** There is no speed
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
reuse of a dominating identical result. Neither moves a trap.

### 3. Loop-invariant checks

- Qualify `LOOP_MOTION` and `STRING_SCAN` for the default build. They are
  measured above and already written.
- Hoist a type test on a value the loop does not change to the loop entry.
  The test still runs once, so a mistyped received value still takes the slow
  path.
- Discharge the index bounds from `i < n` and `n <= strlen s`.
  `Codegen.Interval` already works in difference constraints and has
  `OStrLen` producer bounds; what is missing is carrying the fact from the
  call site (`sumB s 0 (strlen s) 0`) into the callee, or a loop version
  guarded by one entry test of `n` against the length.

Target: `byteloop` at the hoisted figure, 23 ms.

### 4. The fuel counter

- **Counted loops charge per chunk.** A self-loop with a known step takes
  `c = min(iterations left, fuel left)`, subtracts `c` once and runs `c`
  iterations without a tick. Preemption then happens on exactly the tick it
  does today, and no new constant appears (my experiment used 1,024 as a
  stand-in). `OSafepointN` already expresses a counted charge for the vector
  kernels.
- **AArch64 keeps the counter in x27.** The runtime's C is already built with
  `-ffixed-x27` and the context switch already saves it. Generated code loses
  one of nine callee-saved registers. A tick becomes `subs; b.le`.
- **Other targets keep the memory cell for now.** x86-64 has five callee-saved
  registers and reaches the hart through thread-local storage; RV64 could
  give up one `s` register. Both need their own measurement.
- **Not proposed: dropping the tick from bounded non-recursive functions.**
  It would make the `native-insns` bound interprocedural and needs its own
  page.

### 5. The allocation fast path

Investigate before designing. The question is which of the five bookkeeping
stores must happen per cell. Candidates for per-slab accounting at refill or
region close: the hart allocation clock, the per-bucket byte count and the
second window test. The per-object slab link is what the earlier roadmap
called header-free region cells (C1 piece 3). The evidence so far is the
instruction count and the 88 ms against 33 ms left on `tree_sum`; nothing
here is measured in isolation.

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

| Step | Work | Gate | Measured ceiling |
| --- | --- | --- | --- |
| 1 | Selection and frames, A64 then x86-64 and RV64 | `fib` worker at 30 instructions per call or fewer, from 38; `segmax` not larger on any corpus function | `fib` 0.72 |
| 2 | Checked-operation folding and sharing | `option_loop` has no `sdiv` and no check on a literal; `build` multiplies once; random differential with trapping operands | `tree_sum` 0.66 with step 1 |
| 3 | Promote `LOOP_MOTION` and `STRING_SCAN`; hoist type tests; bounds from the call site | `byteloop` and `string_scan` loops free of type tests; out-of-range and mistyped inputs still trap as before | `byteloop` 0.33 |
| 4 | Chunked fuel in counted loops; x27 on A64 | preemption tick-for-tick identical on the scheduler fixtures; QOS ratchet and the Pi fuel window re-qualified | `fib` 0.54, `byteloop` 0.26 |
| 5 | Allocation path investigation | a per-store account of the fast path, then a proposal | not measured |

Each step keeps its `FPR_NO_<NAME>` flag, joins the default-build
differential, and states its compile-budget delta. Steps 1 and 2 are
independent and can run in parallel; step 3 depends on 2 for the folded
bounds; step 4 touches the runtime contract and should land alone.

Filter fusion and byte or string folds that fuse like `List` remain as listed
in today's performance record. They are the route to the vectorized figure
and are not repeated here.

## Open questions

1. Is one callee-saved register on AArch64 an acceptable price for the fuel
   counter, given that QOS apps share the convention?
2. May a check that provably cannot fire be removed, and a dominated
   identical checked operation be reused? Both keep trap order, but they
   amend a rule the simplifier states today.
3. Should the seven opt-in modes be qualified as a group or one at a time?
   I measured them only as a group.
4. Is the x86 box available for the same experiment? Its `fib` is 5.3x C
   against 2.4x here, and the memory fuel tick is the first thing to test.

## Limits of this evidence

- One machine: arm64 macOS on Apple silicon. Nothing here is measured on
  x86-64 or RISC-V, on QOS or on a board.
- The variants are hand-written assembly, not compiler output. They show a
  ceiling, not a result.
- The register-fuel variants reseed the counter instead of yielding, which is
  valid only for one actor. Trap paths are a breakpoint, never reached by
  these inputs.
- The `fib` rows vary by 5 to 10% between runs; medians are in the data file.
- The `tree_sum` builder variant uses flag-based tagged arithmetic for
  brevity, so its 88 ms mixes folding, sharing and selection.
- Each variant was checked only for identical output on the benchmark input.

## Reproduce

```
tests/bench/fixedcost/measure.py 11 > out.json     # about 3 minutes, arm64 macOS
```

The script asserts every emitted pattern its variants rely on (hart cell
offsets, the String type id, the `Leaf` header, the allocation sequence) and
fails when code generation has changed, instead of measuring something else.
