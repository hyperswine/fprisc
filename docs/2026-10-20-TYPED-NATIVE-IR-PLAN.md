# Typed native IR and direct architecture backends

Date: 2026-10-20. Kind: goal / plan and proposed architecture.
Status: accepted with the narrowing of the 2026-10-20 review (one IR, A64
first, M0 as a register page, an M3 investment review). M1 review repairs
are implemented; M2's AArch64 half is implemented
([M2 page](2026-10-21-TYPED-IR-M2-A64.md)); its x86-64 half is open.
Baseline: native compiler at `c328232f63d3f4a6a4b4c1dde7bce17cc449e19d`
(codegen revision 66); 2026-10-21 amendments cover the M1 repairs at revision 67.
Audience: compiler implementers and reviewers.
This page changes no language contract, backend default, or runtime ABI.

## Goal and relationship to the performance work

Introduce a typed low-level IR between Core and native instructions, then
generate AArch64, x86-64, RV64 and RV32 directly. Share control-flow analysis,
value-lifetime analysis, verification and allocation infrastructure while
letting each backend select instructions and implement its calling convention.

The goal is to make code generation easier to verify and extend, and give the
compiler enough information to reduce unnecessary moves, spills, conversions
and call overhead. A cleaner representation alone is not a speedup or a claim
of parity with C.

This builds on:

- [Register allocation](2026-10-19-REGISTER-ALLOCATION.md): original lifetime
  and placement proposal.
- [Native cost experiments](2026-10-20-NATIVE-COST-EXPERIMENTS.md): corrected
  interpretation of the recursive-call gap and checked C comparisons.
- [Retained-register scoring](2026-10-20-RETAINED-REGISTER-SCORING.md):
  whole-function promotion, measured regressions and fuel-bound limitations.
- [Frame placement and call costs](2026-10-20-FRAME-PLACEMENT-AND-CALL-COSTS.md):
  bounded candidate selection, frame compaction, paired A64 frames, and the
  still-open mixed-local representation work.

The proposed IR becomes the foundation for the remaining work:

| Performance item | Planned mechanism | Evidence needed |
|---|---|---|
| Helpers regression | Inspect live ranges, call clobbers, spills and target instruction costs | Isolated paired measurements; a smaller instruction count is insufficient |
| Cost-aware register placement | Allocate by lifetime, call crossing and save/restore costs | Correctness under pressure, bounded safepoint segments, per-target timing |
| Frame placement | Keep slots symbolic until allocation; reuse compatible non-overlapping spill slots | Smaller frames where applicable, deep-stack and relocation correctness |
| Recursive-call overhead | Target-specific call lowering and prologue/epilogue generation | Independent C ABI harnesses, tail-call and recursive benchmarks |
| Untagged mixed locals | Explicit representations and conversions in selected arithmetic regions | Exact traps/effect order, managed-value survival and conversion counts |

Historical measurements remain evidence for those revisions, not predictions
for this design. In particular, tagged addition/subtraction can already be
cheap; unboxing every integer local is not an objective.

## Current implementation and its constraints

[`Codegen.hs`](../compiler/Codegen.hs) emits assembly strings with RISC-V
physical registers and concrete frame accesses. Its `compileFnBody` performs
cleanup, optional frame/register rewrites and instruction-bound annotation.
[`Peephole.hs`](../compiler/Peephole.hs) parses those strings to recover loads,
stores and clobbers. `wcetAnnotate` similarly reconstructs control flow.

[`A64.hs`](../compiler/A64.hs) and [`X64.hs`](../compiler/X64.hs) translate
the emitted text. The x86 backend compensates for return-address placement,
stack alignment, different argument/result registers and constrained
instructions. The new A64 frame-pair optimization recognizes exact adjacent
instruction strings. [`RV64.hs`](../compiler/RV64.hs) also contains hosted
TLS and tail-transfer lowering.

These passes work, but early physical-register and frame decisions restrict
later choices. Replacing strings with constructors would remove parsing
fragility; virtual values and delayed placement are needed for the broader
allocation improvements.

## Proposed architecture

```text
Core after existing ownership and worker transformations
  -> typed low-level CFG with virtual values and explicit effects
  -> verified shared simplification and representation decisions
  -> target legalization, instruction selection and ABI lowering
  -> selected instructions with virtual operands and explicit constraints
  -> register allocation, spill insertion and parallel-copy resolution
  -> frame layout, prologue/epilogue and stack-check expansion
  -> target verification and instruction-bound analysis
  -> assembly printer -> existing assembler/linker
```

Use one portable IR and a small selected-instruction structure initially. The typed IR
describes operations, their semantics and their effects over virtual
values. Instruction selection is a per-target function from an IR
operation to a list of selected instructions whose operands carry
constraints: register class, fixed or tied operand, implicit uses and
definitions, clobbers. Physical register assignment respects those
constraints. Every temporary introduced by selection, flag dependency, fixed/tied operand,
and runtime-call clobber must be visible before allocation. This information
may live in a small instruction structure; the number of representations is
not a restriction. Add a separate machine IR if it makes those contracts
clearer. `Sol/KIR.hs` is a useful local precedent, not a constraint on native
compiler design.

Keep ISA/word size, calling convention, object format and execution profile
separate in target configuration. AArch64 macOS and Linux share instruction
selection but differ in symbols, relocations and TLS. Hosted and builtin
RISC-V differ in runtime and hart access policy. RV32 requires explicit width
legalization, not just substitution of load/store mnemonics.

Proposed module boundaries, subject to the first implementation review:

| Module area | Responsibility |
|---|---|
| `Codegen/IR.hs`, `Codegen/Verify.hs`, `Codegen/Dump.hs` | Portable types, CFG, validation and deterministic dumps |
| `Codegen/Lower.hs` | Core-to-IR lowering with source locations and existing semantics |
| `Codegen/Liveness.hs`, `Codegen/Allocate.hs` | Shared analyses, allocation and spill decisions |
| `Codegen/Selected.hs` | Selected instructions, operand constraints, temporaries, flags and call clobbers |
| `Codegen/Frame.hs` | Symbolic frame objects and final layout |
| `Codegen/Target/{A64,X64,RV64,RV32}.hs` | Legalization, instruction selection, ABI constraints and target printing |
| `Codegen/Bounds.hs` | Structured segment analysis and explicit bound provenance |

Start with ordinary Haskell algebraic data types and a mandatory verifier.
Use SSA virtual values and block parameters for joins and loop-carried values.
The verifier checks definitions, dominance, edge argument types, operation
signatures and terminators. A large GADT encoding is not a prerequisite.

`Sol/KIR.hs` is an existing typed kernel IR for Sol. Review it for reusable
ideas during the inventory; merging the native compiler and Sol JIT is outside
this plan's initial scope.

### Keeping up with the legacy generator

`Codegen.hs` changed from revision 50 to 66 between 2026-10-13 and
2026-10-20. Lowering starts from Core after the ownership and worker
passes, so most of that churn (`Workers.hs`, `Reuse.hs`, `Inline.hs`,
`ReceiveTurns.hs`) is upstream of both paths. What lives in the generator
itself (the inline table, the fit guards, the spill cells, direct
arguments, self loops, the unboxed kernels) is not. The rule from M1 on:
a change to `Codegen.hs` that affects a Core form the new path lowers
either carries the new path with it, or records the form as a fallback
reason in the same commit so strict mode shows the loss of coverage.
Coverage counts are part of the page that lands each generator change
once M2 exists. Nothing is frozen; coverage is not allowed to decay
silently.

## Contracts the IR must preserve

### Values and arithmetic

Distinguish tagged runtime values, raw machine integers by width, unboxed
language integers with their 31/63-bit range, predicates, addresses and floating
point values. Managed and unmanaged references need explicit metadata;
an arbitrary machine word must not silently become a managed reference.

Make box/unbox, tag checks and fallback paths explicit. Checked arithmetic
must specify range, overflow and division failure behaviour. Use explicit
failure edges or operations with equivalent ordered trap semantics. A
machine-width overflow flag alone does not establish language-range validity.

Preserve argument evaluation order, source diagnostics and observable failure
order. Move or remove a potentially trapping operation only with a proof that
the transformation preserves those behaviours. Preserve floating-point
semantics; this migration does not enable reassociation or fast-math.

### Effects, ownership and memory

Represent allocation, ARC changes, calls, loads/stores, volatile MMIO, atomics
and fences distinctly. Initially keep effectful operations in source order
and treat unknown calls conservatively. Do not introduce speculative memory
motion as part of the representation change.

Carry the ownership/lifetime obligations established by existing passes
through lowering. Specify which values must remain visible to the runtime
across allocation, collection, stack growth and safepoints for each profile.
Preserve the existing root/scanning and stack-relocation contracts before
attempting any improvement to them. Address-taken or escaping slots cannot
be reused merely because an SSA value has no later direct use.

### Calls, frames and runtime integration

Calls describe argument/result representations, calling convention, clobbers
and runtime effects. Preserve the existing generated-code ABI, C boundary,
closures/apply path, extra-argument cells and exported/imported entrypoints.
Any future ABI change requires separate versioning and adapters.

Keep frame objects symbolic, including alignment, size, managed-reference
status and address escape. Reserve target scratch and runtime registers
explicitly. Stack-growth/fuel slow paths are real calls with real clobbers;
allocation must see their obligations before final instruction expansion.
If late expansion adds clobbers, revalidate allocation or reject the result.

Tail calls and self loops are explicit terminators. Preserve parallel argument
assignment, teardown and required safepoints on every path, including
high-arity and mutually recursive transfers.

### Fuel and bounds

Retain logical fuel ticks, cancellation opportunities and stack checks.
Initially do not move, merge or remove safepoints. Re-run structured segment
analysis after transformations and final lowering, including spill code,
prologues, slow paths and target expansion.

The existing shared-RISC instruction count is not elapsed time. A new-IR
operation count or native instruction count is not interchangeable with it.
Milestone 0 must document the consumers and establish how the old bound is
preserved or conservatively mapped. Keep legacy logical bounds and native
instruction bounds separately named and versioned. Unknown/unbounded results
must fail the promotion gate. Do not retain a legacy bound label over a new
metric; changing an externally consumed bound requires explicit migration.

## Implementation milestones

M1 has an initial implementation; its review repairs and M0 inventory precede
M2 native emission. Each stage remains independently reviewable and retains
a working legacy backend.

### M0. The inventory as a register page

Sections 1 to 3 of the [register-allocation design](2026-10-19-REGISTER-ALLOCATION.md)
already record how values flow through the generator, the three
translators' register maps and per-line costs, the call, constructor and
case sequences, the fuel tick and the stack check. M0 is a short register
page that points at those sections and adds what they do not hold. It is
a bounded inventory rather than a broad redesign. Its ABI, root, stack and
bound contracts are an exit gate before M2 emits native code.

- [x] Core forms the generator accepts, grouped by the milestone that lowers them.
- [x] Preserve ordered scalar-worker representations from the worker producer;
  never recover them by parameter name or default an unknown worker to `TVal`.
- [x] Call shapes: `a0..a7`, the x64 `a6`/`a7` cells, the per-hart argspill
  cells, `fpr_apply`'s argument vector, exported and imported entrypoints,
  TLS and hart reads per host.
- [x] The root, scanning and stack-relocation contract per profile.
- [x] Bound consumers and a compatibility strategy are recorded in the
  [register](2026-10-21-NATIVE-IR-CONTRACTS.md). QOS has documentation
  references; no executable QOS parser was found in the inspected source.
- [x] The opt-in backend selector and strict coverage mode (M2):
  `FPR_TYPED_IR_BACKEND`, `FPR_TYPED_IR_STRICT`
  ([M2 page](2026-10-21-TYPED-IR-M2-A64.md), commit `17c2dec`); the
  report and dump format are the M1 page's `FPR_TYPED_IR`.

Exit: the [register](2026-10-21-NATIVE-IR-CONTRACTS.md) maps every Core form
and records the runtime contracts. Executable native selection and strict
coverage remain M2 deliverables.

### M1. IR, verifier and a scalar lowering path

- [x] Implement typed values, blocks/parameters, branches, calls, checked
  arithmetic, returns and explicit runtime effects
  ([M1 page](2026-10-20-TYPED-IR-M1.md)); symbolic frame objects wait for
  M2, where the first spill needs one.
- [x] Lower a bounded scalar subset from Core without changing ownership passes
  ([M1 page](2026-10-20-TYPED-IR-M1.md): `Codegen/Lower.hs`).
- [x] Add positive and negative verifier fixtures, including dominance, edge
  types, missing terminators, illegal conversions and malformed calls
  ([M1 page](2026-10-20-TYPED-IR-M1.md): `tests/TypedIR.hs`, nineteen refusals).
- [x] Provide deterministic dumps and a small scalar interpreter/reference
  evaluator for result, trap and effect-order checks
  ([M1 page](2026-10-20-TYPED-IR-M1.md): `Codegen/Dump.hs`, `Codegen/Eval.hs`,
  `tests/check_typed_ir.py`).

Exit: scalar arithmetic, branch joins, calls and recursive control flow have
verified IR and reference results. This stage makes no native speed claim.

### M2. First direct native path: AArch64 first, x86-64 inside the milestone

- [x] Define the operand-constraint model with x86-64's needs in it from the
  first commit: tied destination, fixed registers for division and shifts,
  the `%rax`/`%rdi` split of value and first argument, call alignment, and
  the `a6`/`a7` cells (`Codegen/Selected.hs`, `tests/SelectedIR.hs`;
  [M2 page](2026-10-21-TYPED-IR-M2-A64.md), commit `17c2dec`).
- [x] Select AArch64 instructions directly from the IR, initially using
  conservative spill placement to establish correctness
  (`Codegen/Target/A64.hs`, `Codegen/Place.hs`, `Codegen/Frame.hs`; commit `17c2dec`).
- [x] Integrate existing ABI, fuel and stack-growth behaviour, with direct
  Mach-O assembly emission and ELF assembly checks
  ([M2 page](2026-10-21-TYPED-IR-M2-A64.md) "Selection" and "Evidence"; commit `17c2dec`).
- [ ] Implement the same scalar subset for x86-64 Linux through that
  constraint model, before any default change or performance claim
  (open: the vocabulary and its tests exist, no x86-64 selection does).
- [x] Test independent C callers/callees and legacy/new compiled units together
  (`tests/typed_ir/tir_probe.c`, `scalarlib.fpr` under `scalar_mod.fpr`,
  `tests/check_typed_ir_a64.py`; commit `17c2dec`).

Exit: the same scalar fixtures execute through both direct backends with exact
results and failure behaviour. New-backend strict mode proves that the intended
functions used the new path. Native x86 Linux execution is required; assembly
inspection alone does not close that leg.

This is the first end-to-end milestone. AArch64 lands first because it is
the development host; x86-64 lands inside the same milestone, through a
constraint model designed for it, so that the IR's assumptions never fit
only the Mac.

### M3. Allocation, frame planning and measured improvements

- [ ] Implement liveness and an initial linear-scan allocator with target
  constraints, call-clobber handling and correct parallel-copy resolution.
- [ ] Account for caller/callee-save costs; begin with static loop/call
  information, recording any later use of measured profiles.
- [ ] Insert spills and compute frames afterward; reuse slots only with
  compatible representation, alignment, lifetime and root requirements.
- [ ] Generate native prologues/epilogues, including legal A64 paired accesses,
  and preserve stack-growth behaviour for large frames.
- [ ] Revisit helpers, recursive calls and selected mixed arithmetic regions
  as separate experiments with separate switches and measurements.

Exit: register-pressure and runtime-boundary tests pass; targeted reductions
in spills, frame bytes or conversions are visible in dumps and assembly.
Publish paired timing and compile-time/memory costs, including regressions.

### M4. RISC-V and broader language/profile coverage

- [ ] Add direct RV64 and RV32 selection and width legalization.
- [ ] Expand to aggregates, strings, closures/apply, floating point, vectors,
  ownership-sensitive paths, and builtin/HAL operations in bounded increments.
- [ ] Cover QOS TLS/hart access, imported units, dynamic loading and exported
  C entrypoints where supported.
- [ ] Complete the target/profile coverage matrix with native or board
  execution and explicit remaining gaps.

Exit: each supported combination has evidence appropriate to its runtime.
QEMU is useful differential evidence; physical Pi/STAR64 and RV32 board
acceptance remain separate where those targets are claimed.

This is the long tail. The vector kernels, NEON and the x64 XMM shadow
bank, closures, TLS and dynamic loading are the larger half of the
generator. The legacy path stays the default for every form outside the
scalar subset until this milestone closes, and that is expected to be a
long time; the rule in "Keeping up with the legacy generator" is what
keeps the two paths honest meanwhile.

### M5. Default promotion and retirement of text translation

- [ ] Close coverage gaps and make strict mode pass for the supported corpus.
- [ ] Pass the correctness, bounds, performance and cache gates below.
- [ ] Promote separately by target/profile, retaining an explicit rollback.
- [ ] Retire old string optimizations and translators only after their final
  consumers move, with a documented transition for tooling and bound metadata.

Exit: supported native targets emit directly and shared passes no longer
reconstruct semantics from assembly strings. Sol JIT migration and a custom
object-file writer remain independent projects.

## Selection, fallback and cache policy

The new path starts opt-in. Preflight support for an entire function; select
the legacy path before emission when a Core operation/profile is unsupported.
Mixed old/new functions are permitted only after common-ABI interoperability
tests pass. Use whole-unit fallback until then.

An unsupported feature is a reported fallback reason. A failed verifier or
invalid selected instruction is a compiler error, not silent fallback.
Emit coverage counts and reasons in diagnostic/dump mode; strict test mode
rejects fallback for the functions under test.

Include backend mode, IR/selection revisions, target/ABI/profile settings and
optimization controls in imported-unit and executable cache identities.
Exercise off/on/off cache transitions, imports and cross-unit calls. Preserve
public module interfaces unless an explicitly versioned contract changes.

## Validation and acceptance

Existing starting points include `tests/check_base.py`,
`tests/check_workers.py`, `tests/check_registers.py`,
`tests/check_retained_registers.py`, `tests/check_frame_placement.py`,
`tests/check_a64_frame_pairs.py`, `tests/check_self_loops.py`,
`tests/check_self_loop_x64.py` and `tests/check_self_loop_rv64.py`.
Extend or supplement them when the IR introduces behaviour they do not cover.

For fast local x64 iteration, `python3 tests/check_x64_local.py --require-execution`
runs scalar/ABI, self-loop and vector probes on Intel or macOS Rosetta. The
[Rosetta testing record](2026-10-21-X64-ROSETTA-TESTING.md) documents its C
oracles and substituted runtime/TLS boundaries. It supplements the required
native Linux leg; it does not close that acceptance gate.

| Gate | Required evidence |
|---|---|
| IR validity | Verifier after each transforming pass; negative cases and deterministic dumps |
| Semantics | Legacy/new differential fixtures plus independent arithmetic/C oracles; exact traps, side effects and outputs |
| Control flow | Loops, joins, critical edges, copy cycles, early exits, self/mutual tail calls and high arity |
| ABI and runtime | Live values across calls, callee-save sentinels, alignment, closures, TLS, one/multiple harts, deep stack growth |
| Memory | Managed values across slow paths, ARC/collection where applicable, mixed locals and escaping frame addresses |
| Bounds | Preserved tick semantics, finite bounds with documented provenance, no silent relaxation of existing admission contracts |
| Portability | macOS A64 execution, Linux x86 execution in CI, A64 ELF checks, RISC-V emulation and separately recorded physical coverage |
| Build and caches | Plain macOS Cabal build, Linux CI build, imports, mode transitions and revision invalidation |
| Performance | Paired timings, emitted code/spill/frame metrics, compiler time and peak memory, target-specific regressions |

Use Fibonacci, sum, pipeline, byte-loop, helpers, SHA, mixed locals and at least
one allocation/actor workload. Compare against both legacy defaults and the
best validated legacy opt-in combination, keeping all unrelated settings fixed.
Build all binaries before timing; use at least 31 alternating paired rounds
after warmup, validate every result, and retain raw samples, hashes and flags.
Separate process-wall and internal-kernel timing.

**M3 investment review.** Assess allocation gains and maintainability separately.
If, at the end of M3, the new path's allocator does not beat the best
validated legacy opt-in combination (as of `c328232`: retained scoring
under the costed gate, compact frames, self loops and A64 frame pairs
together) on fib, sum and helpers by at least the 2% trigger below, with
no regression on pipeline and SHA, record which performance goals remain unmet and assess whether to proceed to
M4. Use repeatable paired results and their uncertainty, not a single median
cutoff. Include compile time, code size, maintenance cost and target-specific
tradeoffs. Further backend investment is an explicit decision on that page.

For default promotion, set target-specific budgets before the experiment.
As an initial review trigger, investigate any median slowdown above 2% or a
compile-time/peak-memory increase above 10%; these are proposed triage limits,
not statistical proof or permission to ignore smaller consistent regressions.
Repeat uncertain results and document any accepted tradeoff explicitly.

Report C comparisons with matched arithmetic checks and fixture semantics.
Report time, allocation, resident memory and energy separately; energy
efficiency requires power/energy measurement. Missing hardware or CI legs
remain open acceptance items.

## Immediate next implementation slice

M1's initial implementation and review repairs are recorded in
[TYPED-IR-M1](2026-10-20-TYPED-IR-M1.md) and
[M1-REPAIRS](2026-10-21-TYPED-IR-M1-REPAIRS.md). The bounded M0 inventory is
[NATIVE-IR-CONTRACTS](2026-10-21-NATIVE-IR-CONTRACTS.md).

Next is M2: define explicit target/profile policy and a selected-instruction
structure with all introduced temporaries, fixed/tied operands, flag
use/definitions, register classes and runtime-call clobbers. Include the x86
constraints in its first tests. Then implement conservative A64 scalar
selection and spill placement, preserving the runtime ABI and entry policy.
Compare checked arithmetic, branch joins, known calls, recursion and a self
tail loop through independent oracles before attempting allocation improvements.
The opt-in selector, strict coverage, cache identity, bound reporting and
legacy/new ABI tests are part of this milestone, not follow-up default work.

## Alternatives and decision status

A structured assembly AST is a useful temporary bridge if it removes a
specific parsing dependency, but it does not satisfy the virtual-value and
delayed-placement goals. Avoid making a full AST conversion a prerequisite
for the first direct scalar path.

LLVM or another external backend could provide mature instruction selection
and allocation. Evaluate that separately if maintaining four direct backends
proves too expensive, including runtime integration, startup/build footprint
and bound provenance. This plan proposes an in-tree implementation first.
LLVM's [code-generator architecture](https://llvm.org/docs/CodeGenerator.html)
is a reference for separating selection, allocation and frame layout; it is
not a dependency decision.

Keep implementation evidence in dated follow-ups and update milestone
checkboxes only with links to the corresponding changes and validation.

## 2026-10-21 review amendments and immediate work

The [M1 review](2026-10-21-TYPED-IR-REVIEW.md) found two convention-recovery
defects and a native Bool equality discrepancy. Before native emission:

- [x] Carry ordered worker signatures from `Workers` into IR lowering and
  refuse internal calls with missing signature metadata.
- [x] Repair the native Bool discrepancy and cover mixed Bool/Int parameter
  order, equality/inequality and aliases. Cross-unit and foreign-Bool
  boundaries are exercised by the worker suite; M2 retains its own ABI gate.
- [x] Use independent expected results as well as legacy differential tests.
- [x] Finish the [runtime contract register](2026-10-21-NATIVE-IR-CONTRACTS.md),
  including target/profile policy and instruction-bound provenance.
- [x] Correct M1 evidence: native result/trap comparisons, structural evaluator
  tick expectations, and portable dumps are distinct validation legs.

Implementation evidence: [M1 repairs](2026-10-21-TYPED-IR-M1-REPAIRS.md).

Next implementation: M2's
selected-instruction constraints and conservative A64 emission. No native
backend selection or default promotion is implied by closing the repairs.
