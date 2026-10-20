# Native IR: runtime and lowering contract register

Date: 2026-10-21. Kind: source-grounded register and M2 implementation gate.
Applies to: `f9cd965` plus the reviewed worker-metadata and Bool repairs
(codegen revision 67). Status: M0 inventory for the initial scalar backend;
native implementation and target acceptance remain M2/M4 work.

This is the bounded inventory requested by the
[plan](2026-10-20-TYPED-NATIVE-IR-PLAN.md). Existing details of frame slots,
register mappings and costs remain in the
[register-allocation design](2026-10-19-REGISTER-ALLOCATION.md).

## Core coverage and representation evidence

The complete Core constructor list is in [`FPRISC.hs`](../compiler/FPRISC.hs).
[`Codegen/Lower.hs`](../compiler/Codegen/Lower.hs) consumes Core after existing
ownership checks, lifting, specialization, worker creation and normalization.
An accepted function is not necessarily a closed executable program: it may
call an imported or legacy-only function. M2 must validate those boundaries.

| Core form | Current portable lowering | Native milestone |
|---|---|---|
| `CVar` | Local values; visible nullary constructor definitions | M2 scalar; other CAF/function values M4 |
| `CInt` | Checked signed-63-bit literal, explicit tagging at value boundaries | M2; RV32 signed-31-bit legalization M4 |
| `CStr` | Refused | M4 |
| `CApp` | Saturated known calls, scalar arithmetic/comparisons, internal conversions and fuel | M2 subset; callbacks/apply/HAL breadth M4 |
| `CLam` | Refused; ordinary native pipeline lifts lambdas | M4 closure/apply coverage |
| `CLet` | Sequenced expression and lexical alias | M2 |
| `CIf` | Blocks and typed join parameters | M2 |
| `CMk` | Nullary constructors only | M2 immutable constants; allocated aggregates M4 |
| `CTagEq` | Explicit tag tests; typed Bool conditions | M2 |
| `CProj` | Refused | M4 |
| `CErr` | Refused, including unreachable pattern arms | Add explicit error lowering before admitting such functions |

Representation signatures come from `Workers.workerizeWithSignatures`, which
retains `KernelKinds.signatureStrict`'s result when selecting each worker.
The list follows the original parameter order. `KI` means unboxed language
Int and `KB` means the normal Bool object; ordinary public arguments/results
remain tagged values. Normalization must preserve this evidence. Unknown
scalar-worker metadata is a named refusal at definitions and call sites.
It must never default to the public all-tagged ABI.

Worker Bool equality currently compares addresses. Base nullary Bool
construction therefore uses the same `fpr_true`/`fpr_false` runtime singletons
as comparison results. Wrappers normalize valid foreign Bool objects before
entering the worker. Builtin nullaries retain their existing local emission.

The portable IR is currently signed-63-bit, with abstract runtime ticks/checks
at entry. `FPR_TYPED_IR` is diagnostic, not a native backend selector. Before
M2 emission, pass explicit profile/entry policy to lowering: scheduler fuel,
stack checks and raw/ARC conventions cannot be inferred from ISA alone.
Builtin, ARC and RV32 native IR emission remain unsupported until that policy
and their separate contracts are implemented and tested.

## Calls and target constraints

Sources: [`Codegen.hs`](../compiler/Codegen.hs),
[`runtime.c`](../runtime/runtime.c) (`callf`, `fpr_apply`),
[`fpr.h`](../runtime/fpr.h), [`A64.hs`](../compiler/A64.hs),
[`X64.hs`](../compiler/X64.hs), [`RV64.hs`](../compiler/RV64.hs).

| Boundary | Existing contract to retain |
|---|---|
| Known generated call | Evaluate arguments in order, stage before transfer; result uses the generated return convention |
| A64/RISC-V arguments 1–8 | `x0..x7` / `a0..a7`; preserve all live values around runtime calls |
| x86-64 arguments 1–6 | SysV argument registers at call boundaries; first argument and result use different registers |
| x86-64 arguments 7–8 | Private `fpr_x64_a6/a7` TLS cells, also populated by runtime `callf` |
| Arguments 9–64 | 56 per-hart spill cells, beginning at offset one word in the hart block; copy into the callee frame before any safepoint |
| Closures/partial calls | PAP object with code, arity and supplied arguments; runtime apply/callf bridges to the same ABI |
| Imported/public/exported functions | Keep the public representation and symbol/visibility convention; private worker symbols have no general function-value entry |
| Self tail transfer | Parallel argument assignment, correct loop-carried values, required entry tick/check |
| Other tail transfer | Restore caller state and frame while retaining staged arguments; do not treat a high-arity transfer as ordinary SysV stack arguments |
| Runtime/HAL call | Explicit argument/result convention and clobbers; unknown effects remain barriers |

M1 refuses definitions with more than eight parameters. Calls above that
limit may appear as declared boundaries; M2 strict coverage must reject them
until spill-cell staging is implemented. Preserve the existing C ABI rather
than allowing a selected-instruction list to assume all calls are generated
calls. Record each supported call shape in native tests, including callbacks
from an independent C harness.

Instruction selection must expose all generated temporaries and dependencies
before allocation. For x86 this includes tied arithmetic operands, division
registers, variable-shift constraints, condition flags and call alignment.
For A64 include branch/immediate ranges, paired-access offsets, TLS calls and
reserved scratch registers. A selected-instruction structure can encode this
without requiring a second optimization IR.

## Scheduler, hart and stack boundary

[`actors.c`](../runtime/actors.c), `fpr_fuel_exhausted`, may switch actors and
resume on a different hart. Reload hart-dependent state after such boundaries.
The fast fuel decrement is not itself a complete description of its slow path.

The context-switch implementations define what can survive descheduling:

- [`ctx_a64.S`](../machine/unix/ctx_a64.S) preserves x19–x27 and x29, with
  resume PC and SP. x28 is the hart register and deliberately not restored as
  actor state. d8–d15 are not saved; the allocator must not assume ordinary
  AAPCS floating-point preservation across a scheduler call.
- [`ctx_x64.S`](../machine/unix/ctx_x64.S) preserves rbp, rbx and r12–r15,
  resume PC and SP. XMM registers have no preservation promise here.
- [`ctx_rv64.S`](../machine/unix/ctx_rv64.S) records the hosted RISC-V integer
  and floating-point context. Other machine hosts have their own context
  implementations and must be checked before admitting their profile.

Hosted TLS belongs to the operating system. RV64 hosted hart reads use TLS;
builtin RISC-V may use `tp` directly. A64 Mach-O TLV access has its own call
and clobber sequence. QOS apps borrow host TLS/hart state. None of these should
be implemented as an unannotated pure pointer load in the selected stream.

**Existing actor stacks do not relocate live frames.** `actors.c:stack_grow_at`
links a new segment, normally doubling capacity, and leaves all old frames in
place. Generated code addresses its frame through FP and restores SP from FP
on return, so it naturally returns to the old segment. C frames and pointers
into the old stack make a moving-stack implementation invalid here.

The existing generator stages parameters before entry runtime calls and
skips stack checks only for its proven-shallow case. M2 may initially check
every supported entry, provided calls, frame costs and bounds account for it.
Its prologue and oversized-frame policy must still preserve runtime headroom;
checking after an arbitrarily large unchecked frame decrement is insufficient.
Self-loop reuse must not accidentally repeat prologue saves or omit ticks.

## Managed values and profile-specific roots

| Profile/runtime | Current lifetime/root mechanism | Native IR obligation |
|---|---|---|
| Hosted Base / actor runtime | Actor pools/arenas, compiler ownership actions, explicit ARC promotion/drop; no general moving collector | Preserve ownership effects and live managed references across calls and suspension; no invented GC relocation |
| QOS loaded Base app | Runtime plane callbacks delegate allocation/scheduling/stack growth to the host | Preserve plane ABI, hart state and public entry contracts; deployment validation is separate |
| Builtin with compiler ARC | Explicit retain/release/layout adapters in `machine/builtin/arc.c` | Preserve consuming versus borrowing calls and alias-result retains |
| Tang Nano conservative-collection configuration | `gc_registers.S` snapshots integer registers; `gc_roots.c` scans globals and stack; `heap.c` marks/sweeps without relocation | Keep pointer-bearing values visible to those scans; do not hide roots in unscanned register classes or encode them as arbitrary integers |

Sources: [`runtime.c`](../runtime/runtime.c),
[`builtin/arc.c`](../machine/builtin/arc.c),
[`builtin/heap.c`](../machine/builtin/heap.c),
[`gc_registers.S`](../machine/tangnano20k/gc_registers.S),
[`gc_roots.c`](../machine/tangnano20k/gc_roots.c).
Builtin conservative collection and compiler ARC are mutually exclusive in
the current heap implementation. These are distinct modes; a generic “GC
safepoint” flag is not an adequate replacement for their contracts.

The initial M2 path should preserve the existing runtime ABI and support only
its explicit scalar profile. Broader profiles remain whole-function/unit
fallback until their register and root contracts have executable tests.

## Bounds, consumers and compatibility strategy

`Codegen.wcetAnnotate` counts shared-RISC instructions on its reconstructed
CFG between fuel safepoints. It emits `segmax`, `exittail` and `ccalls`.
`Compile.wcetSummary`, enabled by `FPRC_WCET`, summarizes those comments;
tests including register/frame/self-loop checks consume them. QOS's
`programs/mods/docsdata.fpr` describes the metric and associated timing model.
At QOS `63942ce`, this inventory found no executable parser of these comments; documentation
references are still consumers and should not be described as “nothing in QOS”.

For the new path:

1. Keep logical fuel points explicit and verify each reachable cycle has the
   required scheduling boundary. Initially preserve source/inline tick policy.
2. Analyze the final selected stream after spills and frame/call expansion.
   Name and version native instruction metrics separately, for example
   `native-insns-v1`, with separate runtime-call accounting.
3. Keep legacy `# wcet:` reporting attached only to legacy emission. A parallel
   legacy compile can provide a reference bound, but cannot certify new native
   code. Never reuse that count under the old label for an unrelated stream.
4. In an opt-in mixed build, report legacy/native coverage separately and
   decline an aggregate legacy bound when any function lacks that metric.
   Unknown/unbounded segments fail strict native acceptance. Consumers that
   require the old aggregate must keep using the legacy path until migrated.
5. Before default promotion, implement and validate either a conservative
   mapping to the existing admission contract or an explicitly versioned
   consumer migration. Native instruction counts still require target timing
   assumptions and bounded C calls before implying elapsed-time guarantees.

This is a compatibility strategy, not an implemented bounds pass. Neither
portable IR operation counts nor evaluator tick totals establish native WCET.

## Selection, diagnostics and cache identity

`FPR_TYPED_IR` currently observes freshly emitted units; a cached unit may
produce no report. It changes no assembly and is not a cache key. Corpus
coverage must use a fresh cache. The worker metadata lives within compilation,
so current cached units do not need a new metadata serialization format.

M2 will introduce a separate opt-in backend selector and strict mode. They
must be part of both unit and executable cache identities, with target/profile
and IR/selection revisions. Unsupported functions fall back before emission;
invalid IR is a compiler error. Until ABI interoperability passes, select at
whole-unit granularity. Codegen revision 67 invalidates legacy artifacts for
the Bool correctness fix independently of these future controls.

## Completion boundary

The scalar ABI, Core coverage, stack/root inventory and bounds migration
strategy are recorded here. M2's executable selector, selected-instruction
constraints, native verification and bounds analysis remain implementation
work. This page does not certify a backend or hardware target. Add evidence
links as those gates close rather than marking them complete from this text.
