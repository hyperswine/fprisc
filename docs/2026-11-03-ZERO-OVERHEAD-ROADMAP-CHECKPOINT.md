# Zero-overhead roadmap checkpoint

Date: 3 November 2026. Reviewed source: `9ffd4d2`. This is a status and
priority review, not a new implementation, release qualification or timing
certificate. It updates the reading order of the
[unboxing proposal](2026-11-01-UNBOXING-ZERO-OVERHEAD-PROPOSAL.md) and
[native performance plan](2026-10-31-PERFORMANCE-AND-PREDICTABILITY-NEXT.md).
Older measurements and implementation records retain their original scope.

## The three review issues are closed in source

Do not add these as new open defects; their fixes and records already exist.

| Original finding | Current implementation and existing record | Verification in this review |
| --- | --- | --- |
| **P1: producer floating suppresses output or changes division-by-zero into overflow** | `ListFusion.movable` uses `unsafeExpressionStrict`; commit `b3bc5dc`. See the [trap-safety addendum](2026-11-02-LIST-FUSION-TRAP-SAFETY.md#addendum-2026-11-02-later-the-float-crossed-overflow-capable-work). | Replayed the original printing and division repros with fusion on/off; compared exit status, stdout and stderr. |
| **P1: range fusion introduces a maxInt trap or drops a minInt trap** | `foldRange` preserves the original nonempty range's initial underflow, and `foldRangeGo` stops at the final element without incrementing past it; commit `3a5a83a`. See the [limit addendum](2026-11-02-LIST-FUSION-TRAP-SAFETY.md#addendum-2026-11-02-later-foldrange-at-the-int-limits). | Replayed the maxInt singleton repro and ran `tests/check_list_fusion.py`, including its six limit cases. |
| **P2: installing an index-selected version accepts a different payload release/platform** | `installExpected` carries the selected entry into `checkPayload`, which checks release, host platform and metadata before publication; commit `e68284d`. See [packaging contracts, section 3](2026-11-02-PACKAGING-CONTRACT-FIXES.md#3-installation-authentication-and-recovery). | Rebuilt the manager and ran `Contracts.test_payload_contracts` and `Contracts.test_index_contracts` in disposable homes. |

The first two are compiler-source conclusions. The packaging record reports
the manager fix shipped in 0.2.0; this review did not reinstall production
tools or repeat public-release qualification.

## What has advanced

| Area | Landed scope | Remaining boundary |
| --- | --- | --- |
| A1 / B1: constructor elimination and List fusion | Removes temporary constructors and intermediate lists in admitted shapes. | Preserve effects and traps across all transformations and source spellings. |
| [A2: tuple scalars](2026-11-02-TUPLE-SCALARS.md) | Loop-carried tuple/record state can become scalar workers, including let-bound and conditional next states. | Escaping whole values and unsupported shapes still use the general representation. |
| [Tick batching](2026-11-02-TICK-BATCH.md) | Removes redundant inlined entry ticks in eligible self-looping functions. | Fuel accounting changed to one unit per iteration; throughput gains alone do not establish unchanged scheduling latency. |
| [Typed case tests](2026-11-02-TYPED-CASE.md) | Uses static nominal type knowledge to reduce case-test overhead. | Does not change object layout. |
| [Pair returns](2026-11-04-MULTI-REGISTER-RETURNS.md) | Private two-register workers for same-shape pairs on hosted A64/X64/RV64; general entries remain. | Pair-specific, not general aggregate returns; X64/RV64 execution and builtin/raw-field support remain outside the recorded proof. The linked file is dated 4 November but its implementation is already in this snapshot. |
| [B2: typed TRMC](2026-11-03-TYPED-TRMC-IMPLEMENTATION.md) | Later on 3 November: checked typed workers remove reverse allocation in default specialized map/filter and append; Core pass retired. | Builtin/ARC and RV32 remain gated; see the implementation record for freshness, region constraints and validation scope. |
| [C1 layout table, slices 1-2](2026-11-03-LAYOUT-TABLE.md) | Derives object sizes and checks them against existing preheaders. | Preheaders remain; boxed-number/vector size paths lack the same exercised coverage as constructors, strings and PAPs. |
| [C2 builtin specialization](2026-11-03-BUILTIN-TYPE-SPEC-AND-INTERVAL.md) | Per-instance representations, representation-directed clones, rollback and diagnostics; interval and sharing improvements also landed. | Not the whole C2 contract: current cloning uses a fixed 4096-Core-node budget, and incompatible representations can still be refused. |
| [Packaging contracts](2026-11-02-PACKAGING-CONTRACT-FIXES.md) | Signed selection, payload checks, atomic receipts/recovery, exact pins and editor discovery. | Exact pins are not hermetic builds; host tools, sysroots and other inputs still matter. |

Fusion, constructor elimination, scalar replacement and private pair returns
directly remove costs introduced by abstractions. Smaller cells and faster
allocators reduce the cost of objects that remain. Packaging improves delivery
and reproducibility; it does not remove runtime abstraction costs.

## Recommended next work, in order

### 1. Make the correctness and abstraction-cost gates reflect default builds

The generated List-pipeline differential test already exists at
`tests/reliability/list_fusion_random.py` and is wired into the reliability CI
runner. Extend it rather than proposing it again: include printing callbacks,
capture evaluation, conditional uses, and interactions with TRMC, tuple scalars,
pair returns and tick batching. Run trapping cases independently so an earlier
trap cannot prevent the later generated cases from executing. Preserve the
explicit distinction between the permitted overflow-report reordering and
changes to success/failure, output, or other trap kinds.

Add an abstraction-equivalence family: direct pipeline, let-bound pipeline,
helper-wrapped pipeline and explicit loop, with the same checks and scheduling
contract. Record output, allocation, emitted code size, compile cost and paired
runtime samples. Add cold and warm cache runs. A remark that a rewrite fired
is not proof that the executed specialized body benefits.

**Exit criterion:** default-build allocation expectations and observable
behavior pass together; retain raw samples with revision, target and flags.
Fresh hosted CI results and cross-target execution must be reported separately
from local source inspection and existing implementation records.

### 2. Extend B2 after the hosted implementation

The [typed TRMC implementation](2026-11-03-TYPED-TRMC-IMPLEMENTATION.md) now
runs after specialization and fusion, retires the Core pass, and meets the
2,000/1,500 map/filter allocation targets with normal specialization enabled.
It checks fresh-cell provenance rather than equating payload linearity with
cell uniqueness. Append retains its gain; nonempty accumulators keep their
original behavior.

Next, qualify builtin/ARC with explicit retain/release and ownership-transfer
validation, then consider RV32. Keep the existing gates until that proof is
complete. Broaden admitted source shapes only alongside effect/trap and
allocation tests; this is still a selective optimization, not a universal
zero-allocation guarantee.

### 3. Complete C1's size/ownership proof before removing metadata

Exercise boxed-number and vector size paths through supported runtime
operations; vectors need not be made sendable to test their allocation/free
paths. Cover realloc, sharing, deep copy, actor transfer and region recycling.
Resolve the owning-slab word and alignment/bucket granularity explicitly:
deleting a size word alone does not establish the promised 48-to-32-byte cons.

**Exit criterion:** every affected object class and walker is exercised,
measured bytes per cell improve, and one coordinated runtime revision passes
multi-hart actor checks and QOS qualification. Preserve the existing layout
until that proof is complete; a table checked against a preheader is a
prerequisite, not completed preheader removal.

### 4. Reconcile the implemented C2 slice with the agreed C2 contract

The proposal's decisions require target-derived/manifest budgets, deterministic
representation and uniform boundary fallbacks. `Representation.hs` currently
uses `typeSpecBudget = 4096` and whole-program per-instance inference; a budget
decline retries unification with the original signature, which can still fail
for incompatible kinds. Document and test this narrower behavior before
calling C2 complete or extending it to Base.

**Exit criterion:** specify layout and clone identity across instantiations,
targets and runtime revisions; enforce the intended target-image limit;
test budget exhaustion and pinned exports; prove either a real conversion to
the uniform boundary or an explicitly supported refusal. Extend pair returns
to builtin/raw fields only after their ownership and calling conventions agree.
Keep Base/extbase, FFI, reload and QOS boundaries as explicit later gates.

### 5. Qualify predictable latency and delivery alongside throughput

Tick batching is implemented, so the next task is latency qualification:
measure maximum yield spacing, competing-actor latency, deadline/watchdog
response and work-dependent runtime operations under representative loads.
A 1024-node Core body cap is not a hardware cycle bound.

For delivery, follow the packaging record's remaining reproducibility work:
record or pin host tools/sysroots and build settings, compare fresh install
locations, then qualify additional hosts. Keep hardware WCET tied to the
reference target's timing model and measured board behavior. Neither release
pins nor instruction-count improvements establish a wall-clock guarantee.

## Validation scope for this checkpoint

- `make -n fpr` reported the checkout compiler up to date.
- `python3 tests/check_list_fusion.py`: passed, including current allocation
  baselines, trap-order and integer-limit cases.
- Original division, printing and maxInt repros: identical exit/stdout/stderr
  with fusion enabled and disabled; the maxInt singleton prints `0`.
- Fresh manager build; the two payload/index contract test groups above passed.
- Other implementation/performance claims above are attributed to their
  records and inspected source. This review did not rerun the full benchmark,
  hardware, release, or hosted CI matrices.
