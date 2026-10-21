# Typed IR migration execution record

Date: 2026-10-22. Baseline: `0c9c8b7` (remote main at the start of this work).
Branch: `codex/typed-ir-migration-20261022`; isolated worktree
`fprisc-typed-ir-migration`. User-authorized sequence: steps 1-5 of the migration
assessment. Default promotion is conditional on the recorded acceptance gates.

## Sequence and acceptance

| Step | Work | Acceptance | Status |
|---|---|---|---|
| 1 | Reconcile plan; paired merged-compiler measurements | Exact source/compiler/host identities, outputs, 31 paired samples, regressions included | Complete: frozen compiler, 31 rounds on Apple M4 |
| 2 | Shallow-entry checks and forwarding parameters | Independent switches/cache identities, native ABI and scheduler tests, before/after measurements | Validated A64/Rosetta; 31 paired rounds; kept opt-in |
| 3 | Broader language coverage | Layout/allocation/root contracts; verifier/evaluator/native oracles; corpus counts | Aggregates/strings, terminating expressions and float runtime calls validated; 3707/3707 corpus instances |
| 4 | RV64/RV32 and remaining profiles | Direct selection and width legalization; matching runtime/board evidence | RV32/RV64 QEMU pass; Linux CI pending; other profiles remain refused |
| 5 | Promotion and retirement | Per-target correctness, coverage and performance gates pass; no remaining legacy consumers | Gates reviewed; promotion and retirement blocked by explicit gaps |

## Baseline evidence

The exact baseline passed the full native Linux job in
[run 39620437639](https://github.com/hyperswine/fprisc/actions/runs/39620437639),
including strict direct x86 execution (47/47 fixture functions, 73 independent
and differential calls), Base, I32/raw, experimental modes and RV64/QEMU.
The RV64 result is for the existing translator, not a direct RV64 backend.

The historical M3 M1-Mac-mini measurement is not a measurement of this merged
compiler. Preserve those samples; build a frozen optimized baseline compiler
before edits and keep new evidence separate. A corpus function count is not a
percentage of execution time or a percentage of the migration completed.

## Refreshed baseline (Apple M4, macOS 27.0.1)

[Raw samples and compiler identity](evidence/2026-10-22-typed-ir-migration/baseline.json)
and [paired tables](evidence/2026-10-22-typed-ir-migration/baseline.md) record 31
rounds of the frozen optimized baseline. Against `legacy-best`, `typed-ir`
median paired ratios are fib 1.1395, sum 0.6611, pipeline 1.0686 (internal
timers), helpers 0.6006 and SHA 1.0735 (process wall). Fib and SHA regressions
are real in this run; pipeline's interval includes parity. `typed-ir-best`
changes SHA to 0.9402 but leaves fib at 1.0923 and pipeline at 1.0962.
These are mixed-mode programs, not wholly direct-backend performance.

## Entry experiments

`FPR_TYPED_IR_SHALLOW_STACK=1` uses the final allocated frame and selected
call events: at most 1024 bytes, no non-tail generated call or generic apply.
Self loops retain fuel on every iteration. `FPR_TYPED_IR_FORWARD_PARAMS=1`
limits forwarding to a single-block wrapper with only entry events and a
non-self tail transfer, using at most eight A64 or six x64 register arguments.
The selected pseudo explicitly consumes and redefines the argument values;
private managed frame objects preserve them around slow runtime calls, with
no parameter parking on the common path. Mach-O TLV forwarding is excluded.
Both switches are opt-in and participate in compilation and executable cache
identity. Both require native scheduler/stack and independent ABI oracles.

### Entry measurement outcome

[Raw paired samples](evidence/2026-10-22-typed-ir-migration/entry.json) and
[tables](evidence/2026-10-22-typed-ir-migration/entry.md) show no reliable overall
speedup. Combined entry / unchanged typed ratios are fib 0.9971, sum 0.9939,
pipeline 1.0066, helpers 0.9988 and SHA 0.9718; every 95% interval contains 1.
Shallow-only pipeline process wall regressed (ratio 1.0903, CI 1.0500-1.1169).
Do not enable either switch by default on this evidence. The frozen entry
compiler hash identifies an uncommitted intermediate experiment before the
coverage/RISC-V changes; its recorded Git revision is the base revision,
not a clean commit containing that experiment. A source patch was not captured
for that intermediate binary; final measurements must identify the final commit.

## Aggregate/string contract and evidence

The IR now represents `OMake`, `OField`, `OString`, `OStrLen` and `OCharAt`.
Constructors use the existing `{int32 typeid, int32 variant, V fields[]}`
layout. Fields evaluate left to right; allocation is an ordered runtime effect.
Tagged field values survive `fpr_alloc` through the shared allocator's saved
registers/spill slots. Objects are immutable under the admitted Base policy,
whose allocator does not move objects. This does not establish ARC/root-scanning
correctness for the separately refused builtin profiles.

String literals share the existing byte encoding and object layout, including
embedded zero bytes. Source Unicode is encoded by the parser before Core reaches
lowering; byte access returns unsigned bytes. Length and access initially use
the exact runtime primitive entries, preserving type/range traps. The reference
evaluator models those bytes and exact traps independently.

Validation: IR verifier/evaluator and simplification equivalence; native nested
constructors/records across 2000 allocations/calls; UTF-8 byte results and bounds
traps; one/four harts; full A64 integration and Rosetta arithmetic/ABI checks.
All 12 benchmark-corpus outputs match their independent `.expected` files,
with **3707/3707 emitted function instances** native (formerly 1544/3707).
Repeated library instances are counted. The intermediate 3700/3707 result
left four value-position `CErr` instances and three F64 calls; these now lower.
These are coverage results, not a speedup or full-language acceptance claim.

## Terminating expressions and float value ABI

`CErr` now terminates any expression context, including constructor fields,
call arguments, conditions and both arms of a value-producing conditional.
The lowering keeps closed blocks and earlier effects, emits no phantom value,
and stops evaluating subsequent arguments. The independent evaluator verifies
trap text/order, earlier allocation, surviving sibling branches and unchanged
behavior through simplification.

F32/F64 operations use declared saturated runtime entries with `TVal` operands
and results. These are the existing target-width `V` representations (raw float
bits on 64-bit, runtime-managed representations where required on 32-bit), not
FP register allocation. The host runtime oracle compares 400 pairs containing
signed zero, subnormals, infinities and NaNs with C, with the inliner both ways
and one/four harts. Additional tests cover conversions, rendering, ten float
arguments, aggregate fields, generic apply and a 100,000-iteration tail loop.
Unboxed FP selection/allocation remains open.

## Coverage performance regression and preservation

The clean `7c6f8af` compiler was measured in 31 paired rounds:
[raw samples](evidence/2026-10-22-typed-ir-migration/coverage.json),
[tables](evidence/2026-10-22-typed-ir-migration/coverage.md).
Against legacy-best, typed ratios were fib 1.1053, sum 0.6449, pipeline 5.4597
(internal), helpers 0.5770 and SHA 0.8759 (wall). Expanded coverage exposed a
real regression: lowering the pipeline's main function bypassed the legacy
vector-specialization planner and ran generic callbacks instead of its fused
column kernel. The root coverage increase was therefore not a performance win.

Until typed kernels are implemented, native selection explicitly declines
functions with an enabled applicable vector specialization. The scan honors
lexical bindings, the target gate and float capability; it reports
`vector specialization requires legacy kernel emission`. Tests retain the
fused kernel on A64, x64, RV64 and RV32 and prove that local callback parameters
remain eligible for direct selection. Runtime results equal an independent
arithmetic answer. Final paired measurements of this repair follow below.
This preserves a live legacy consumer rather than claiming it has migrated.

## Direct RISC-V contract and evidence

`Codegen.Target.RV` selects directly from typed IR and shares the allocator,
CFG/liveness machinery and frame objects. Its explicit width controls word
loads/stores, constructor fields, frame links, hart cells and string length
words. RV32 literal validation/evaluation uses the signed 31-bit Int range;
shift counts, wrapping and logical-right-shift width follow the 32-bit runtime.
A64/x64 reject a 32-bit policy. Checked arithmetic initially calls the exact
runtime primitives; no performance claim is made for this first selector.

RV64 Unix uses local-exec TLS. Bare Base uses `tp`; that initial path refuses
frames above 1024 bytes, while Unix retains the 32768-byte hosted ceiling.
Self loops are optional and keep their fuel tick. Native bounds conservatively
account for assembler pseudo expansion before linker relaxation. Generic apply,
wide hart-cell arguments, immutable objects and strings have direct selection.
RV32/RV64 QEMU each pass **4724 independent results in both loop modes**, forcing
fuel hooks to clobber all volatile integer registers. The oracle also covers
nine arguments, nested allocation and string layout. Its allocator explicitly
uses the target word size. This runtime substitute proves codegen/ABI behavior;
it is not physical-board or real Linux scheduler acceptance.

## Promotion matrix and remaining order

| Target/profile | Local evidence | Remaining acceptance | Default |
|---|---|---|---|
| A64 hosted Base | Full native integration, aggregates, corpus, one/four harts | Final performance review; typed vector kernels and broader language gaps | Legacy |
| x64 Linux Base | Selected constraints and Rosetta ABI oracle | Fresh Linux CI with real TLS/scheduler and aggregates | Legacy |
| RV64 Unix Base | Direct QEMU oracle, TLS assembly path implemented | Fresh Linux cross-build/QEMU-user runtime job | Legacy |
| RV64 bare Base | Direct QEMU oracle, small-frame limit | Real runtime and physical STAR64 acceptance | Legacy |
| RV32 bare Base | Width verifier/evaluator and direct QEMU oracle | Real runtime and physical RV32 board acceptance | Legacy |
| Builtin / BuiltinArc / loaded QOS app | Named refusals retained | Ownership, roots, allocation and loader/hart contracts plus target oracles | Legacy |

The CI workflow now tests direct native x64 with/without entry options,
aggregate/string and corpus execution, RV32/RV64 bare QEMU oracles, and an
additional direct RV64 Linux runtime run. `--require-execution` turns missing
emulation/native support into failure for the required jobs. Loaded RV64 Unix
modules still use legacy emission; their host can exercise direct code, and
this distinction must stay visible.

Next implementation order: review the repaired benchmark; implement typed
vector kernels and unboxed floating selection; then implement each remaining
runtime profile with its own ownership/root and hart-access tests. Promote only a
specific target/profile after those gates pass. The legacy translators still
have live consumers, so retiring them now would remove supported behavior.
