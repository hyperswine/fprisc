# Resource contracts, simple-risc WCET and QOS admission

Follow-up: [resource inference and editor integration intent](2026-11-09-RESOURCE-INFERENCE-AND-EDITOR-INTENT.md)
defines the first user-facing inference/hover scope and its implementation gates.

Date: 7 November 2026. Status: proposed implementation roadmap; no milestone
below is claimed complete by this document. Baseline inspected: `6761b28`.

The order is deliberate: make resource contracts usable as checked function
interfaces, connect those contracts to an executable timing model for
simple-risc, then compose bounded turns into QOS admission. The first useful
end-to-end result is one bounded message-processing callback with checked
input sizes, stack/heap admission and a cycle bound for a frozen Tang Nano
20K configuration. General desktop admission follows that result.

The companion [pipeline refactoring roadmap](2026-11-07-PIPELINE-REFACTORING-ROADMAP.md)
defines the internal implementation phases, shared evidence and deletion gates.
Its summaries and analysis framework implement the contracts here; they are not
a second resource system. Hardware timing and deployment qualification remain
separate obligations under this roadmap.

This updates the WCET implementation sequence in the
[November 1 roadmap](2026-11-01-RELIABILITY-CORRECTNESS-WCET-ROADMAP.md).
Its unrelated reliability work remains separate. It retains the decisions
that resource bounds belong in the type system, rather than a separate
language profile, and cached SDRAM simple-risc is the reference timing target.

## Baseline and boundaries

| Capability | Present today | Remaining obligation |
| --- | --- | --- |
| Source contracts | `work`, `alloc`, `live` declarations checked in ordinary compilation; `--cost` requests reports | First-class checked resource interfaces, useful recurrence coverage and actionable diagnostics |
| Composition | Symbolic callback work/allocation, verified measures and supported result-size lemmas | Argument-dependent callback obligations, growing accumulators and branching recurrences |
| Native segments | `native-insns-v1` counts selected instructions between safepoints | Interprocedural execution paths, C runtime duration and hardware cycles |
| Memory admission | Callback budgets, linked stack analysis, controlled RV64 activation and finite-sequence arenas | RV32 qualification, persistent state, overlapping lifetimes and concurrent dispatch |
| Time manifests | Supplied `ns_per_op`, primitive prices and budgets | Validated timing model and enforced artifact identity |
| QOS evidence | Host/Pi competing-actor tests and physical Pi qualification | Bounded dispatch, blocking and interference; response-time admission |

The current source allocation equation uses requested cell bytes; it is not
the final target's physical heap geometry. Finite stack or heap bounds do not
prove termination. A sampled latency maximum does not prove WCET. The
RV64 controlled-runtime admission receipts do not qualify the RV32 Tang host.

Implementation anchors: [Cost](../compiler/Cost.hs),
[compile-time checking](../compiler/Compile.hs),
[result-size proofs](../compiler/Resource/ResultSize.hs),
[native segments](../compiler/Codegen/Bounds.hs),
[check placement](../compiler/Codegen/Placement.hs),
[heap](../compiler/Codegen/Heap.hs), [stack](../compiler/Codegen/Stack.hs),
[manifests](../compiler/Manifest.hs), and
[whole-activation admission](../tools/build_static_arena.py).

## Contract design rules

- Keep `work` in portable abstract operations. Hardware cycles and elapsed
  time are distinct, target-indexed judgments; never silently reinterpret work.
- Preserve the existing `| work f <= ...`, `alloc`, `live` and verified `size`
  vocabulary. Settle syntax for stack, timing and callback effect constraints
  in the first implementation slice before extending the parser.
- Make resource information part of checked function interfaces, including
  function-valued parameters. Check every declared finite contract without an
  opt-in flag. Infer summaries on demand and cache them with their dependencies.
- Unknown costs remain explicit. Ordinary code can use them; a finite contract
  or admission boundary rejects relevant reachable unknowns. Trusted external
  bounds must be identified as assumptions, not inferred proofs.
- Preserve input predicates, result-size facts, resource units and proof
  provenance through imports, specialization, lowering and cache reuse.
- Keep source-interface proofs and final-machine proofs separate but linked.
  A source work bound cannot certify machine costs introduced by lowering.
- Report three distinct outcomes: proved under listed assumptions, estimated,
  and unproved. Runtime exhaustion checks provide containment, not a timing proof.

## Phase 1 - Usable resource contracts in the type system

### R1. Checked resource interfaces and diagnostics

Introduce one checked resource-summary representation attached to function
interfaces. Include parameter domains, result-size facts, work/alloc/live
equations, callback requirements, effects, unknown dependencies and provenance.
Use explicit units. Native stack and target timing evidence can attach later.

Keep existing declaration syntax compatible. Audit interface serialization,
`fpr commit`, module hashes and cache invalidation. Compare compatible changes
semantically where supported: a lower upper bound can satisfy an older promise;
a stronger input requirement cannot silently replace the previous contract.
Refuse unsupported compatibility proofs instead of comparing only rendered text.

Add structured JSON diagnostics alongside text, with source locations and a
dependency chain: caller -> callback -> opaque primitive, or caller -> recurrence
whose changing argument lacks an invariant. Display the missing obligation and
the input domain used by the checker. Do not suggest an unverified annotation
as a way to bypass a proof failure.

**Acceptance:** existing contracts retain their meaning; direct, imported,
escaped and partially applied calls preserve obligations; changing a dependency
invalidates cached evidence; an unused declared bad contract still fails;
text/JSON identify the same failing source obligation.

**Primary touchpoints:** `Cost`, `Compile`, typed function/interface metadata,
module serialization, `Diagnostic`, and existing cost/domain/result-size tests.

### R2. Common recurrences and bounded input domains

Implement small independently checked recurrence rules, in this order:

1. Affine accumulator growth and decreasing input length: prove standard
   reverse and map/reverse construction with argument-size substitution.
2. Bounded nested traversal and container result sizes, including the cost of
   callbacks at the size actually passed to them.
3. Structural branching with a verified total-node bound, then depth-based
   call-tree bounds where the supported algebra can express them.

Carry value ranges into budget evaluation: a parameterized equation with an
enforced maximum input size should yield a closed upper bound. Use mathematical
integers for proof arithmetic and preserve runtime overflow/trap semantics.
Do not infer total calls from recursion depth or assume signed inputs positive.

**Acceptance:** the currently refused standard-map pipeline has a justified
positive proof; growing-string and branching-tree undercount regressions remain
rejected; empty, negative, maximum-size and mutually recursive cases are covered.
Unsupported recurrence shapes remain named unknowns. Record analysis-time and
memory regressions against the existing compiler budget.

### R3. Higher-order and effect contracts

Extend callback requirements from symbolic work/allocation to argument-dependent
resource functions and relevant effects: bounded computation, allocation,
blocking, foreign calls and yield behavior. Specify the variance/substitution
rules for passing a callback to a bounded caller. Validate captures, closure
creation, partial application and dynamic dispatch, including their own costs.

Publish reviewed summaries for the supported list/container primitives. Foreign
summaries must state input domains, units, target/runtime identity and trust
source. A source `unsafe` marker alone neither supplies a finite bound nor
establishes a timing model.

**Acceptance:** a bounded callback composes through map/fold and module
interfaces; substituting a slower, allocating or blocking callback fails at the
relevant boundary. Specialization cannot drop obligations. Unknown callback
targets refuse finite admission rather than receiving an average cost.

### R4. Strict admission manifests and a worked example

Separate assumption-based estimates from strict admission. In strict mode,
reject unknown budget names, missing roots, missing timing entries, inconsistent
units and mismatched compiler/runtime/target/image identities. Bind receipts to
the final artifact, checked input domain and all trusted summaries. Revalidate
after linking and on cache reuse; failed builds must not publish valid receipts.

Add a small bounded-message example with a scalar result/state and no blocking
I/O in its callback. Document its source contracts, successful resource proof,
deliberately insufficient budget, unknown callback and oversized-input cases.
At this stage report hardware time as unavailable, not inferred from ns/op.

**Phase 1 exit:** a user can express and diagnose useful portable contracts for
the example and standard traversals. All declared contracts are enforced across
interfaces. There is one resource report format ready for target evidence.

## Phase 2 - A qualified simple-risc timing model

Dependency: Phase 1 supplies checked domains, recurrence facts and interfaces.
Hardware-model investigation can start earlier; it cannot replace those proofs.

### T1. Freeze the reference target and port memory admission

Start with the documented `fprisc-48` RV32IMC cached-SDRAM preset: CPU/SDRAM
48/48 MHz, 64 KiB cache and its selected phase. Record RTL, synthesis options,
bitstream, clock configuration, cache/replacement policy, SDRAM controller,
runtime, ABI, compiler, linker and image identities. The receipt must identify
the actual configuration rather than relying on the preset's name.

Port the controlled activation recipe to RV32. Derive heap geometry and linked
stack requirements from that runtime and ABI, including boxing, conversion and
software arithmetic helpers. For the first callback, use exclusive execution,
fixed storage and an explicit interrupt/device-interference policy. Bound or
exclude collection, refill, stack growth and blocking peripheral operations.

**Acceptance:** the example executes with a valid RV32 memory receipt; one
smaller aligned heap/stack budget refuses where applicable; target/runtime
mismatches refuse. The report lists all excluded interference and failure paths.

### T2. Executable cycle model with local validation

Derive the model from simple-risc RTL. Cover fetch and compressed instructions,
pipeline dependencies, branch prediction, multiply/divide, memory arbitration,
cache lookup/refill/writeback and SDRAM command/refresh timing. Specify initial
microarchitectural states and bound reachable states at each analysis boundary.

Use fixed-latency/BRAM experiments to isolate pipeline behavior, then validate
the actual cached-SDRAM configuration. Begin with conservative state/latency
bounds; only use a worst-access penalty if its compositional upper-bound
property has been established for this pipeline. Account for timing interactions
rather than assuming every local worst case combines monotonically.

**Acceptance:** instruction and transaction microbenchmarks cover cold/warm
caches, conflicting addresses, dirty eviction, dependencies, branch outcomes
and refresh phases. Cycle-stepped RTL checks find no underbound; deliberate
model undercounts are detected. Local exhaustive checks state their finite
scope. Passing samples alone are not a proof of model soundness.

### T3. Program-level cycle analysis and linked-image checking

Preserve verified loop/call facts through optimization and instruction
selection, with an explicit mapping to final control-flow edges. Implement
IPET (maximum path cost constrained by execution counts) or an equivalently
checked bound calculation. Include interprocedural paths and linked runtime
helpers, not just per-function segments. Invalidated loop mappings must refuse.

Add cache must/may or other conservative state analysis as needed for useful
tightness. Analyze code/data addresses after layout, including linker relaxation
and compressed instructions. Check the linked executable against the analyzed
stream and regenerate evidence when layout changes. A solver timeout is
unproved; validate solver results or retain the solver in the stated trust base.

**Acceptance:** emit cycles, loop facts, cache assumptions, runtime costs and
proof dependencies for the example. Unknown callees, unbounded paths and altered
binaries refuse. Optimization/placement variants preserve sound accounting,
including paths across calls, returns and batched fuel checks.

### T4. Physical qualification and first end-to-end release

Run the exact admitted image on the board, using `mcycle` and independently
checked inputs/results. Account for measurement overhead. Exercise adversarial
input sizes and cache/branch/refresh states. Record predicted cycles, observed
cycles and tightness; any observation exceeding the prediction blocks release.

Separately track SDRAM electrical and operating-envelope qualification. The
existing phase sweep is evidence for choosing 48 MHz, not closure of I/O timing
or voltage/temperature/process limits. Publish the supported operating assumptions.

**Phase 2 exit:** one bounded callback has linked memory and cycle evidence for
the pinned RV32 cached-SDRAM target, plus physical execution evidence. State
explicitly whether this is a conditional engineering bound or a fully qualified
deployment claim. QEMU instruction counts never stand in for hardware cycles.

## Phase 3 - QOS turn and application admission

### Q1. Define the bounded turn and runtime service contracts

Define the unit of admission as one application turn: consume a bounded message,
update bounded state, emit bounded output, then return or yield. Bound actor and
queue counts, message sizes, retained state and outstanding requests. Put storage,
network and other externally delayed operations behind asynchronous services;
bound enqueue/copy work separately from completion time.

Compose final native segment paths through calls and returns with the actual
fuel policy. Give size-dependent bounds to allocation, destruction, copying,
queue operations, scheduler scans, locks and context switches. A non-yielding
foreign call with unknown duration cannot enter a bounded turn.

**Acceptance:** the worked example runs as a QOS turn; oversized messages,
unbounded queue populations and unknown runtime paths refuse admission. The
unbounded-C negative control remains detectable and inadmissible. Fuel batching
changes invalidate the affected slot-duration evidence.

### Q2. Persistent and concurrent memory admission

Extend fresh-activation proofs to retained state, shared/received objects,
overlapping activations, queue storage, scratch buffers and per-worker stacks.
Choose a concrete capacity/reservation policy and enforce it at spawn, enqueue
and dispatch. Include conversion graphs, descriptors and allocator metadata.
Specify backpressure and failure behavior when an operation exceeds admission.

**Acceptance:** prove capacities for one persistent application and then two
competing applications; stress all admitted overlap patterns. Exhaustion traps
or sampled high-water marks cannot replace the static capacity proof. Existing
finite-sequence arena receipts retain their narrower documented scope.

### Q3. Response-time analysis and target deployment contracts

Choose and document the admitted scheduling policy before deriving its bound.
Separate execution cost, dispatch waiting, blocking and interference. Include
release patterns, runnable populations, priorities where applicable, interrupt
work and cross-worker communication. Avoid applying a fixed-priority response
formula to a scheduler that implements a different policy.

For QOS Portable on Linux, define a separate deployment contract covering CPU
placement, kernel/preemption configuration, memory residency, frequency/thermal
behavior and competing system work. The simple-risc cycle model does not qualify
Pi ARM64 execution. Add target-specific timing evidence and an explicit bound
on OS interference before claiming hard response deadlines; otherwise label
results conditional or measured service objectives.

**Acceptance:** admit or reject an application set against explicit response
budgets, with a breakdown of each term and assumption. A configuration whose
OS/runtime interference is unknown cannot receive a hard-deadline certificate.
Exercise both admitted schedules and deliberate overloads on physical hardware.

**Phase 3 exit:** a bounded persistent QOS workload has enforceable memory and
scheduling admission on a named deployment. Arbitrary desktop applications,
unbounded I/O completion and unqualified hardware remain outside the claim.

## Delivery sequence and validation policy

Suggested independently reviewable slices, in dependency order:

| Slice | Deliverable | Depends on |
| --- | --- | --- |
| 1 | Resource-summary schema, unit/domain rules and diagnostic fixtures | Baseline audit |
| 2 | Checked interface propagation and cache/compatibility tests | 1 |
| 3 | Affine recurrence/result-size rules; standard map/reverse proof | 2 |
| 4 | Callback/effect obligations and reviewed library summaries | 2, 3 |
| 5 | Strict manifest admission and portable worked example | 3, 4 |
| 6 | Pinned Tang target and RV32 memory recipe | 5 |
| 7 | RTL-derived pipeline/cache/SDRAM model with local checks | Target definition in 6 |
| 8 | Program cycle analysis, linked-image checker and board evidence | 5, 6, 7 |
| 9 | QOS turn/runtime contracts and persistent memory admission | 5, 8 |
| 10 | Scheduling analysis and qualified deployment example | 9 plus target-specific timing |

Every slice adds positive proofs and meaningful refusal cases. Run focused
checks in PR CI; keep broad generated/differential, RTL state exploration and
physical-board matrices in dedicated jobs. Retain the existing CI budget target
of under 30 minutes, ideally 15-20; measure new checks before assigning them.
Track analysis time/memory and proof coverage as well as runtime performance.

The release gates are soundness/refusal behavior, artifact identity, useful
coverage and target qualification. Tightness is a separate metric: publish
bound/observed ratios and choose workload-specific usefulness thresholds after
the first baseline. Never lower a bound merely to meet a tightness goal.

Planning scale: Phase 1 is several weeks of compiler work; Phase 2 is several
months of compiler/hardware analysis and qualification; Phase 3 is a further
multi-week to multi-month effort depending on runtime and deployment scope.
These are rough estimates, not commitments. Re-estimate after slices 2, 6 and 8.

## Supporting records

- [Original resource design](2026-10-02-RESOURCE-BOUNDS.md) and
  [signature implementation](2026-10-02-BOUNDS-IN-SIGNATURES.md). Historical
  claims about trusted result sizes are superseded by the verified-size work.
- [Equation corrections](2026-11-05-RESOURCE-EQUATION-PREREQUISITES.md),
  [signed domains](2026-11-05-SIGNED-RESOURCE-DOMAINS.md) and
  [verified result sizes](2026-11-05-VERIFIED-RESULT-SIZES.md).
- [Static activations](2026-11-05-STATIC-ACTIVATION-ARENAS.md) and
  [finite application sequences](2026-11-05-STATIC-APPLICATION-SEQUENCES.md).
- [Check placement and typed lowering](2026-11-07-CHECK-PLACEMENT-AND-TYPED-LOWERING.md).
- [Scheduler qualification](2026-11-05-SCHEDULER-LATENCY.md) and
  [physical Pi evidence](2026-11-05-PI-QOS-PHYSICAL-QUALIFICATION.md).
- [Tang preset](2026-10-21-TANGNANO20K-PRESET.md) and sibling simple-risc
  [SDRAM operating envelope](../../simple-risc/docs/2026-10-31-SDRAM-OPERATING-ENVELOPE.md).

Baseline validation note: the local compiler build completed during assessment.
The attempted cost suite could not write its default cache under the workspace
sandbox, so no fresh suite pass or physical-board rerun is claimed here.
