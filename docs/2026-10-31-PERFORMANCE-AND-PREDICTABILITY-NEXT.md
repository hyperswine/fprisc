# Native performance and predictable resource use: next steps

Date: 31 October 2026. Kind: prioritized plan and design direction, not an
implementation or timing certificate. Source reviewed: main `744941d`.
This records the agreed next steps after the October native performance work.
It builds on the [performance plan](2026-10-26-PERFORMANCE-PLAN.md), with the
later findings below taking precedence over that plan's earlier assumptions.

The primary objective is useful performance with predictable time, memory,
effects and failure behavior. Matching C is a useful comparison, not a universal
acceptance criterion. Optimization should make more useful programs fit their
resource contracts without weakening type, ownership, arithmetic or scheduling
semantics. There is no new bounded-execution syntax or default refusal policy
introduced by this document.

## 1. Expose recursive loops to the optimizer earlier

This is the largest identified structural opportunity. Many hot self-tail-call
loops become machine loops in `Codegen.Allocate.loopForm`, after typed IR
optimization. The loop-motion pass consequently misses them; natural loops
whose header is the function entry can also lack its required preheader.

The [loop-motion investigation](2026-10-28-LOOP-MOTION-FINDING.md) found
byte-identical root and prelude assembly across the recorded benchmark suite
with motion on and off. That observation applies to those compiler versions
and workloads; it is not a claim that loop motion can never help.

Next: form explicit, verified IR loops with entry/preheader, loop-carried block
parameters, back edges and exits before optimization. Start with supported self
tail calls. Mutual tail recursion needs an explicit group/calling contract;
ordinary non-tail recursion cannot simply be converted into a loop.

Implementation follow-up: [the first early-loop slice](2026-10-31-EARLY-LOOPS.md)
is available behind `FPR_TYPED_IR_EARLY_LOOPS=1`. Direct self-tail branches now
have a preheader before optimization; the linked report records the precise
supported forms, semantic checks and performance evidence. The flag defaults
off; this does not complete the remaining range, pressure or fuel work below.

Preserve argument evaluation, parallel parameter transfers, entry checks,
required fuel events, region boundaries and the lifetime of values across
resets. Keep a conservative fallback for unsupported forms. This opens the
same loop structure to invariant motion, induction analysis and fuel batching.

Evidence to collect: IR/emission witnesses showing the hot loops are visible,
independent answers and ordered traps for zero/one/many iterations, bounded
region behavior, and paired runtime plus compile-cost/code-size measurements.
Changing a flag without changing generated work is not a performance result.

## 2. Carry more facts through loops and calls

The current [difference-bound pass](2026-10-28-INTERVAL-DISCHARGE.md) can prove
that `i < n` makes `i + 1` safe from overflow. It does not generally connect
the caller's `i = 0` and `n = strlen s` with a recursive loop's parameters.
Consequently, bounds guards can remain even when the algorithm makes their
safety apparent.

Implemented subset: opt-in [guarded String scan versioning](2026-10-31-STRING-SCAN-RANGES.md)
establishes entry facts with runtime guards and proves every unit-stride
backedge, retaining the original checked fallback. General caller facts and
mutable-descriptor proofs remain follow-ups.

Next: propagate verified caller/precondition facts and derive induction ranges
for loop-carried values. Establish entry facts, prove they survive every back
edge, and account for each exit. Use those facts to remove only proven overflow
and bounds checks, and to identify repeated descriptor work.

An invariant descriptor load also needs a lifetime/mutation proof: vector
growth, callbacks, resets and actor safepoints must not leave a cached pointer
stale. Keep guards when facts are incomplete. Preserve arithmetic width,
overflow behavior, operand effects and trap order; an optimizer assumption must
not silently become an unchecked caller obligation.

Evidence to collect: successful discharge and refusal controls near integer
limits, empty/out-of-range inputs, invalidated descriptors, and ordered failures.
Compare against the nonoptimized evaluator/runtime behavior.

## 3. Share repeated work across blocks and reduce register pressure

Much sharing remains confined to one block. Repeated untagging, loads and
equivalent calculations across branches can generate extra instructions and
live values. The interval pass already recognizes some equivalent values for
analysis; that does not mean emitted code shares all of them.

The [spill survey](2026-10-28-SPLITTING-7B-SURVEY.md) recorded 23 spills in
SHA's `rounds` body despite that body having no call. Splitting around calls
cannot fix this particular pressure problem. Splitting values used only on
cold paths outside a loop was also measured and deferred.

Next: dominance-aware cross-block sharing and rematerialization of cheap values.
For loads, require proof that the relevant memory and its lifetime are unchanged
on every path. Evaluate whether sharing reduces work or instead extends a live
range enough to introduce spills. Invariant motion must remain pressure-aware:
earlier attempts regressed through longer live ranges, and removing spills
alone did not guarantee a faster critical path.

Evidence to collect: dynamic loop loads/stores, spill/reload counts, code size
and paired timings, including x64's smaller preserved-register bank. Retain
cases where recomputing a cheap value is better than keeping it live.

## 4. Amortize fuel checks in suitably bounded loops

Ordinary tight loops still update the fuel cell every iteration. The
[tick-removal experiment](2026-10-27-TICK-AMORTIZATION-BOUND.md) measured
1.22-1.39x speedups in a deliberately tiny counting loop after hand-removing
some or all tick work. These are experimental ceilings for that workload, not
promised application gains or a safe implementation of batching.

Next: choose a bounded batch size from the loop body's conservative cost, keep
a register countdown and charge/check fuel at a bounded interval. Define exact
accounting for partial batches, all exits, traps, nested loops and calls. The
existing counted kernel safepoints are a starting mechanism, not proof that
ordinary loops can be batched without further analysis.

Preserve the documented maximum work between opportunities to yield. Removing
fuel checks entirely changes the scheduling contract. A loop that allocates or
performs an operation with unknown cost needs a conservative batch or fallback.
Measure fairness and worst observed yield spacing alongside throughput; observed
spacing alone is not a hard wall-clock certificate.

## 5. Extend inlining and specialization by benefit

At the reviewed source revision, checked inlining already crosses module
boundaries, allows 24-node ordinary templates and 64-node templates in recursive
callers, runs at most three rounds and stops early at a fixed point. Recursive
callees remain excluded. The larger budget is a recursive-caller heuristic,
not profile-guided knowledge that a particular block is hot.

Next: identify remaining costly calls, then specialize profitable cases with
known constants or callbacks so the resulting loops can be optimized. Build on
the existing checked callback cloning; a blanket increase in every budget or
indiscriminate recursive expansion is not the proposal. Preserve code ownership,
capture/type contracts, evaluation order and dynamic reload boundaries.

Record call removals and their reasons, code growth, compiler time/allocation
and runtime results. Optimize a measured residual call, not a presumed one.

## Structural constraints to preserve

1. **Checked arithmetic.** Reordering can change which operation overflows or
   traps. Ordinary signed C overflow is undefined, giving C optimizers a
   different contract. Comparisons must match widths and overflow behavior;
   see the [corrected C experiment](2026-10-20-NATIVE-COST-EXPERIMENTS.md) and
   [Clang's documentation](https://clang.llvm.org/docs/UndefinedBehaviorSanitizer.html).
2. **Cooperative scheduling.** Execution must retain bounded opportunities to
   yield. Cheaper or batched checks must preserve that bound.
3. **Ownership and persistence.** Uniqueness can permit mutation, and sharing
   can avoid copying unchanged subgraphs. Where an old value really remains
   observable, preserving it still has a cost. No independent runtime collector
   is proposed by this work.
4. **Generic boundaries.** Tagged arguments, closures and dynamic calls can
   cost more than direct calls with raw values. Specialization and private
   unboxed workers can remove many such costs; genuinely unknown and reloadable
   boundaries need their original contracts.

## Performance expectations: hypotheses that may be wrong

| Workload | Working expectation |
| --- | --- |
| Numeric and flat-data kernels | A credible route to near-C performance where semantics and algorithms match |
| Ordinary native applications | Potentially competitive; allocation, representation and library implementation often determine the result |
| Actor-heavy or persistent-data-heavy code | Competitive with C implementing equivalent behavior; harder to match shared-mutable-memory C with fewer guarantees |
| Sol | A separate performance target: its VM/JIT has different overheads from native FP-RISC |

These expectations are neither measured guarantees nor release gates. Use
matched workloads, independent expected outputs and paired measurements. Keep
native hardware, Rosetta/QEMU functional evidence and physical-board timings
distinct. Do not multiply unrelated step-specific speedups into a total claim.

## WCET and enforceable resource contracts

For a future explicitly bounded callback/closure, acceptance must establish all
five properties:

1. Inputs and captured state have sufficient, enforced or verified size bounds.
2. Loops and recursion have bounded total work for that invocation.
3. Every transitive call, including runtime operations, has an applicable and
   composable cost contract. Unknown callback targets cannot acquire a bound by
   omission; the bound must travel through the callable interface or be derived
   from its known implementation.
4. Allocation, copying and reclamation fit their work and memory budgets. Track
   total allocation, peak live memory and stack requirements explicitly; they
   are different quantities. Include cost on normal and failure paths.
5. The complete bound fits the declared deadline on the selected target under
   qualified hardware, runtime and scheduling assumptions.

In that mode, both an exceeded budget and an unproved budget should refuse
compilation/admission, with a reason the developer can act on. Unknown budget
names, missing contracts and stale/mismatched evidence must fail closed. Large
runtime inputs must be rejected or validated at a boundary, not silently assumed
to fit the static size declaration. No particular annotation syntax is settled.

### Work bounds and elapsed deadlines are different promises

A bound on instructions or abstract operations is not itself "finishes within
20 ms of invocation". A hard elapsed deadline must also account for runtime
internals, call/return composition, allocation/ARC work, blocking, scheduler
interference, interrupts and hardware memory timing. Per-handler bounds alone
do not establish queueing delay or whole-system schedulability; admission also
needs arrival/concurrency limits and an applicable scheduling policy.

The current [target manifests](2026-10-02-TARGET-MANIFESTS.md) can reject over
or unproved function budgets, but their ops-to-time assumptions are supplied,
not independently qualified by the compiler. The
[native instruction regression metric](2026-10-23-NATIVE-METRIC-CONSUMER.md)
does not include all runtime internals or compose return chains into a global
latency certificate. Do not rename either result into a proven 20 ms deadline.

General macOS/Linux execution can offer bounded work plus measured responsiveness
without implying an unconditional wall-clock guarantee. Hard time admission
should start with one controlled target and explicit assumptions. Blocking I/O
belongs outside the bounded callback unless it has its own adequate contract.
Runtime fuel/watchdogs/timeouts add containment; aborting or deferring excessive
work does not prove successful completion by a deadline.

### Delivery order and evidence

First establish a complete work-and-memory contract for a useful small callback
subset, with rejection tests for each missing property above. Then qualify its
time mapping and scheduler admission on one controlled target. Keep an interface
through which larger programs can invoke bounded callbacks without making all
general-purpose native or Sol code satisfy the same restricted contract.

The optimization order is early loop formation, stronger loop/caller facts,
cross-block sharing and pressure work, then bounded fuel batching. Benefit-based
specialization can proceed where a specific residual call justifies it. Each
implementation needs semantic/trap/ownership checks and a measured runtime and
compile-cost delta. Improving optimization expands what passes admission; it
does not replace the proof obligation.
