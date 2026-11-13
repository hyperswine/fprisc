# Zero-overhead roadmap completion

Goal completed on 5 November 2026 under the amended acceptance criteria. Starting compiler: `22e1e55`, codegen 162.
This continues the [completed five-priority implementation](2026-11-04-ZERO-OVERHEAD-EXECUTION.md)
and the selected phases of the [unboxing proposal](2026-11-01-UNBOXING-ZERO-OVERHEAD-PROPOSAL.md).
Optional language-surface experiments and explicitly rejected default data
structures are not prerequisites for the selected roadmap.

## Amended goal acceptance

On 5 November the project owner set the finish line at implementation plus at least one relevant passing test for each core roadmap item. All five items meet that standard.

| Core item | Passing evidence |
|---|---|
| Materializing helpers | Direct, let-bound and helper forms took 501 allocations against 1,001 for the explicit loop. [Measurements](../bench/2026-11-04-materializing-pipelines-final.json) |
| C2 specialization | The fixed 4,096-node cutoff was replaced. Builtin target-image admission and hosted compiler-cost checks passed, including separately compiled tagged fallbacks. [Hosted admission](2026-11-05-HOSTED-WORKER-ADMISSION.md) |
| Unboxed aggregates | Imported wrappers matched explicit integer storage for 512 Map entries. Public, foreign and arena-boundary checks passed. [Validation](../bench/2026-11-05-imported-carrier-validation.json) |
| Scheduling latency | The Pi 4B running QOS passed the scheduler workload and watchdog checks. Single-stepping also confirmed the predicted 14,025 instructions from a full 2,000-tick slice to fuel-runtime entry. [Pi workload](../bench/2026-11-05-imported-carrier-validation.json) · [ARM64 fuel traces](../bench/2026-11-05-pi-fuel-window.json) |
| Static-arena admission | A controlled RV64 sequence admitted at 120 callback instructions executed 117 in QEMU. The gate rejected a limit of 119 and preserved the prior executable. [Admission and trace](../bench/2026-11-05-linked-callback-work.json) |

A general wall-clock deadline for QOS and overlapping static-arena lifetimes remain future work. The original criteria and milestone history below document the scope of the evidence.

## Original ordered acceptance criteria

1. **Materializing pipelines — implemented; focused validation passed.** Direct, let-bound and helper
   spellings must allocate no more than the equivalent explicit loop, with
   independent output and allocation oracles. Cover imported/captured helpers,
   shared results, callback effects, trap order and both integer endpoints.
   Keep declined shapes and the fusion rollback correct. Record paired timings,
   emitted size and compiler cost separately from instrumented allocation counts.
2. **C2 specialization.** Builtin admission uses the selected target image
   limit. Hosted workers use finite reachable call groups and the absolute
   compiler-cost gate. Checked instantiations have stable type-derived clone
   identities. Pinned exports, generic calls, hidden fields and compiled
   open-row shapes retain tested tagged boundaries. Complete deterministic
   storage for the remaining eligible Base aggregates and scalar variants.
   Each newly admitted layout needs cache, module, foreign, ownership and
   fallback evidence. A declined or over-budget instantiation must be explicit.
   [Hosted worker admission](2026-11-05-HOSTED-WORKER-ADMISSION.md)
3. **Unboxed aggregates.** Checked scalar and owned wrappers, nested builtin
   products, private returns through eight words and guarded Base parameter
   expansion have execution evidence. Codegen 196 also passes raw scalar
   arguments through the full 64-word private calling convention. Broader
   Base storage and scalar variants still require execution on each supported
   backend and safe handling at escaping or general entries.
   [Wide scalar workers](2026-11-05-WIDE-SCALAR-WORKERS.md)
4. **Scheduling latency — full physical Pi 4B matrix at codegen 197, with further forwarding, scalar-variant, persistent-list, aggregate-field and imported Map and wrapper-module workloads qualified through codegen 204. General response-time admission remains open.** Bound and measure yield spacing,
   competing-actor response and deadline/watchdog behavior under representative
   scalar, allocating and runtime-heavy work. Distinguish logical instruction
   bounds from physical time and throughput.
5. **Static-arena admission.** Controlled RV64 images admit individual bounded
   activations and finite sequential applications with typed scalar hand-offs.
   The linked dispatcher, startup, heap, stack and guards must fit the target.
   Reuse requires complete reclamation before every reset. An optional linked instruction budget now covers acyclic, frame-confined callback paths. Broader application
   lifetimes, concurrent dispatch and physical timing contracts remain open.
   [Finite application admission](2026-11-05-STATIC-APPLICATION-SEQUENCES.md)

Every milestone retains differential correctness, allocation and compile-cost
gates. Host, emulator, CI and physical-device evidence remain separate. The
Pi Main deployment validates the previous compact-runtime revision; it does
not automatically qualify new compiler work or a bare-metal timing contract.

On 5 November the user selected **Pi 4B running QOS** as the physical
qualification target. Fresh SSH checks confirm a Pi 4 Model B Rev 1.4 running
QOS Portable on Buildroot/Linux 6.6.28-v8, with the powersave policy observed
at 600 MHz. Candidate builds and physical measurements must bind the exact new
compiler/runtime inputs. Existing RV64 controlled-arena results remain separate
emulator evidence; Linux response samples cannot be relabeled as hardware WCET.

## Materializing pipeline milestone (codegen 163)

The missing allocation elimination was the input range, in all three pipeline
spellings. A checked descending `buildRange` step now handles filter/range,
map/filter/range and filter/map/range, constructing only the retained output
cells. Callback safety and capture checks remain mandatory. Division and
observable effects decline; the existing Int-overflow-order policy remains.
The mapped value is evaluated once before a mapped predicate observes it.
Range decrement executes before the step, preserving the original minInt
underflow; maxInt endpoints do not introduce an increment overflow.

At 1,000 inputs and 500 retained values, direct/let/helper use **501 allocation
requests**, previously 1,501, versus the explicit loop's 1,001. The pipeline
allocates the final 500 cells and one observed pair; the reference loop still
allocates a reverse pass. Shared output remains a real persistent list.

The [isolated 21-sample source-form benchmark](../bench/2026-11-04-materializing-pipelines-final.json)
records one million inputs, normal regions, one native macOS arm64 worker,
separate instrumented counters and startup-inclusive timings:

| Spelling | Median | Paired wins versus explicit loop |
| --- | ---: | ---: |
| Direct | 14.013 ms | 21/21 |
| Let-bound | 14.405 ms | 21/21 |
| Helper | 14.604 ms | 21/21 |
| Explicit loop | 18.406 ms | reference |

These are current source-form comparisons, not paired old/new compiler
speedups. Compilation and other validation were idle during this timing run.
The [full abstraction gate record](../bench/2026-11-04-materializing-pipelines.json)
covers all four families and all sixteen spellings.

`check_list_materialize.py` checks 17 independent programs in default,
fusion-off, inlining-off and specialization-off modes on one/four workers,
plus an imported captured helper and malformed replacement targets. The
target verifier checks the worker's exact recursion/decrement and refuses
overflowing hidden prefixes. Existing fusion tests and all 38 Haskell suites
pass. Final compiler budgets remain within unchanged limits: hello 1.58 GB,
std-live 32.91 GB and pos1 70.95 GB allocated; std-live is close to its ceiling.
The final generated default/rollback run passed 200 comparisons across 80
cases, with five documented Int-overflow-order relaxations and no unexpected
mismatches. The complete sixteen-spelling output/allocation gate also passed.
Broader profile/board qualification remains separate from this host milestone.

## C2 admission milestone (arcRev 9)

The representation solver no longer limits cloning to 256-node functions or
4,096 total Core nodes. Before extending a recursive specialization chain it
tries the active representation equation transactionally: ordinary list
accumulators can expose another constructor without needing another clone.
If incompatible recursive arguments structurally embed an earlier instance,
the solver refuses expanding specialization with an explicit diagnostic.
This is a conservative admission rule, not a proof that every finite source
program is accepted. It has no replacement clone-count or depth constant.
Failed reuse attempts cannot leak field/type bindings into the next clone.

Checked parameter and result evidence now applies to every clone. Previously,
fresh clones lost checked result evidence. Pinned external entries require a
concrete checked representation, retain their original ABI, and refuse
conflicting uses. There is **no generic uniform conversion adapter yet**;
the compiler now says so rather than treating failed monomorphic unification
as a fallback. The ownership/cache revision is `arcRev = 9`.

`RepresentationSpecialization.hs`, included in the Core pipeline check, covers
401-node helpers, 5,152 cloned nodes, finite representation-changing mutual
recursion, expanding recursion refusal, ordinary list accumulation,
transactional rollback, pinned boundaries and cloned result evidence.

Final image admission uses manifests in `machine/builtin/targets/`, selected
automatically by `BUILTIN_BOARD`/`BUILTIN_RAM`, with an explicit
`BUILTIN_IMAGE_MANIFEST` override. The manifest identity must match the build's
selected target independently. `tools/target-image.sol` validates ELF
width, load/run addresses, section/segment agreement, entry point, loaded
address span and static RAM plus the target's reserved minimum. The subsequent
[load-segment correction](2026-11-05-LOAD-SEGMENT-ADMISSION.md) includes complete
segment extents, even where no allocated section describes them, and emits
schema-2 receipts. Unloaded headers/debug tables and zero-fill do not count as
boot-image bytes; zero-fill does count as static RAM. Libraries are admitted
when linked into their final image.
The existing hardware linker assertions remain independently enforced.

The Makefile stages the linked ELF, admission receipt and optional Tang raw
binary before publishing them. An admission or link failure leaves the last
admitted output intact. Receipts bind the exact image and manifest by SHA256.
This proves image fit and static reservation only: it does not prove dynamic
heap/stack demand, scheduling latency or WCET.

Image admission must measure the final selected target image, not estimate
machine bytes from Core-node counts. The current builtin Tang SDRAM linker
(`machine/builtin/tangnano20k/link-sdram.ld`) limits loaded images to **64 KiB**;
the general runtime's `machine/tangnano20k/link.ld` allows **2 MiB**. Builtin
Tang currently rejects ARC and uses RV32/manual ownership. Those are distinct
target contracts; the proposal's 2 MiB example must not be copied into builtin
admission without changing and qualifying its actual loader. Both Tang
manifests therefore use a 64 KiB loaded-image limit. BRAM reserves 8 KiB stack
plus 4 KiB minimum heap; SDRAM reserves 64 KiB stack plus 4 KiB minimum heap.
The virt manifest uses its actual 128 MiB RAM; linked static sections include
the normal/trap/interrupt stacks, with at least 64 KiB left for the heap.

Validation on native macOS arm64:

- All **39 Haskell suites** passed, including the new representation suite.
- Existing `check_raw.py` and `check_pair_raw.py` passed on QEMU RV64, including
  mixed raw/managed containers, no leaked live pair allocation, overflow,
  division, shift/alignment failures, specialization rollback and interrupts.
- Eight image-parser boundary/malformed-input checks passed. Real virt,
  Tang BRAM and Tang SDRAM builds passed admission, including manual and ARC
  virt builds. Each rejected a deliberately tight or wrongly identified
  replacement while preserving the previous outputs. Both virt images also
  executed successfully in QEMU. Tang evidence here is
  cross-build/admission evidence, **not a new physical-board execution**.
- The unchanged host compile-cost gate passed: hello 1.58 GB, std-live
  32.91 GB, pos1 70.95 GB allocated. This gate currently exercises Base
  compilation; it is not a new C2-specific scaling measurement.

## Checked type instantiation (arcRev 10)

Builtin ARC now instantiates checked generic functions **before layout and
erasure**, using the complete type at each global reference. Clone identity
contains the source identity and an injective, length-delimited type key;
closed record fields are canonicalized by label. No first-call choice,
fresh-variable ordinal or inferred list length enters that identity.
Regular recursion reuses the reserved typed instance; expanding polymorphic
recursion is explicitly refused. Closed instances are verified as complete
typed programs before native lowering.

Original generic entries remain when an open/compatibility caller or
constructor authority needs them. Pinned exports and runtime roots retain
their identities. `ClosedSignature` evidence prevents the later ownership
solver from re-specializing a closed aggregate type merely because its calls
expose different constructor shapes. This does not change the public ABI or
enable hosted Base type specialization.

Tests check call-order-independent and repeated instance identities, complete
clone types, retained/pinned originals, recursive admission, canonical rows,
list lengths and nested list element types. `check_type_specialization.py`
executes real RV64 programs with effects, nested managed/raw lists, shared
reads and zero outstanding allocation. Printed prefixes and overflow/division
failures agree with specialization disabled. The strict native ARC suite also
passes the existing allocator, interrupt, C-export and independent raw-bit
oracles. The original arcRev 10 validation passed all 39 Haskell suites. The final
compile-cost and execution checks for arcRev 11 are recorded below.

## Compiler scaling and immortal ownership (arcRev 11)

The first [C2 cost record](../bench/2026-11-04-typed-specialization-cost-before.json)
exposed a shared compiler bottleneck: generic helpers and explicit monomorphic
twins both allocated about 0.30 GB at 16 helpers, 1.30 GB at 32 and 9.31 GB
at 64. Their near-identical costs did not establish acceptable scaling.
The [profile record](../bench/2026-11-04-typed-specialization-profile.json)
attributed 91.7% of allocation in the generic 64-helper case to repeated
free-variable enumeration in two vector-pipeline recognition paths.

Pipeline recognition now establishes that the consumer is a candidate before
checking the intervening scope, and membership-only queries stop at the first
occurrence. The shared lexical query walks scopes once while preserving
occurrence order and duplicates. Native branch labels and register-reservation
positions are indexed, and liveness builds use/definition histories without
repeated suffix copying. The index changes produced byte-identical RV64
assembly in the 128-helper comparison before the ownership change.

A separate source of real generated-code overhead was retaining every ignored
`Unit` result to the end of its scope. Ownership lowering now distinguishes
proven immortal `Unit`/`Bool` values from their tagged-word calling convention.
Their parameters, local bindings, projections and branch conditions need no
reference-count operations. Strings and heap objects retain their existing
ownership, including mixed containers and shared reads. The generic managed
representation alone is deliberately **not** an immortality proof.
The ownership/cache revision is now `arcRev = 11`.

In the 128-helper `main`, this removes 615 spilled values and reduces the
frame from 2,080 to 48 bytes. There are no spill slots in the new `main`.
The [final isolated cost record](../bench/2026-11-04-typed-specialization-cost.json)
uses cold compilation on macOS arm64 with GHC 9.8.2 and assembled RV64 code:

| Generic helpers | Compiler allocation | Assembled code | Cold compile time |
| ---: | ---: | ---: | ---: |
| 16 | 129.9 MB | 10,520 B | 0.059 s |
| 32 | 230.5 MB | 16,952 B | 0.091 s |
| 64 | 437.9 MB | 30,136 B | 0.164 s |
| 128 | 886.4 MB | 56,504 B | 0.322 s |
| 256 | 1,894.0 MB | 109,240 B | 0.730 s |

Every row has exactly the same generated function count and assembled code
size as its explicit monomorphic twin. Compiler allocations differ by less
than 0.2%. At 64 helpers the full sequence of changes reduces compiler
allocation by 95.3% and emitted code by 32.8% against the initial record.
These are compiler-workload measurements, not application speedups or a
proof of linear compilation for arbitrary programs. The intermediate
[index-only record](../bench/2026-11-04-typed-specialization-cost-indexed.json)
preserves the separation between compiler query fixes and ownership removal;
its timings overlapped validation and are not isolated timing evidence.

`check_type_spec_cost.py` checks exact code-size/function-count equivalence,
the existing 10% allocation margin against explicit twins, and absolute
host-specific allocation baselines in `tests/type_spec_cost_budget.json`.
The absolute gate prevents a shared regression from passing the twin test.
Peak residency and timing are reported separately. These are compiler-cost
gates, not arbitrary clone-count or linked-image-size caps.

The unchanged standard compile-cost gate also passes: hello 1.57 GB allocated,
std-live 32.37 GB and pos1 69.73 GB, respectively +7.2%, +8.2% and +7.6% against
the checked-in baseline, below its 10% allowance. Peak-live values are 36 MB,
428 MB and 759 MB, within the existing residency gate. No baseline or margin
in `tests/compile_budget.json` was raised.

Final validation:

- All **39 Haskell suites** pass, including 256 generated lexical-scope
  comparisons and positive/negative ownership checks.
- RV64/QEMU specialization/effect/trap differentials pass, including nested
  Int/Word lists and 1,000 allocation cycles with immortal fields alongside
  shared heap strings.
- The strict native ARC suite passes shared-edge/layout checks, 12,000-node
  drops under ASan/UBSan, C interoperability, interrupt resumption, 2,048 raw
  byte/canary cases and 879 independently calculated word/Int checks.
- Native macOS A64 execution and macOS x64 execution through Rosetta pass,
  including actors, mailbox, confinement, wide arity, deep recursion, large
  frames, floats and I64. Linux x64 native execution is unavailable on this
  host; its emission/oracle checks are not presented as Linux execution.
- Both the existing host compile budget and the new absolute/twin C2
  allocation gates pass. `git diff --check` passes.

These results do not add physical-board timing or deployment qualification.

## Checked aggregate field graphs (arcRev 12)

`Compiler.Native.TypeLayout` now derives a finite field graph from checked
constructor schemes, tuple types and canonical closed-record types. An entry
is identified by its complete type key. Recursive fields refer to table keys;
the current runtime's nominal type ids remain unchanged. Neither traversal
order, constructed list lengths nor the first caller selects field kinds.
Expanding recursive type graphs receive an explicit finite-layout diagnostic.

The graph crosses the native/ownership boundary separately from function
signatures, once per compiled unit. `Representation` seeds recursive field
equations from it before inferring bodies. This is used in real lowering:
an uncalled `showWords : List Word -> Unit` helper now selects the raw Word
print adapter without any constructed Word-valued cell. A missing checked
layout or a body contradicting checked raw field evidence is refused.

This establishes closed field-layout authority, not a new aggregate storage
convention: these aggregates still use boxed nodes and the existing runtime
field metadata. It does not yet make a scalar wrapper immediate or return a
wider product in registers. Pinned aggregate boundaries still explicitly
refuse the missing uniform conversion rather than claiming an adapter exists.

One source-language distinction matters for the remaining work. A declaration
such as `Box = Type (Box a b c)` can hide field variables behind the nominal
result type. Those variables are not concrete merely because `Box` itself
has no type arguments. Inventing managed fields for them would mishandle raw
values. The table therefore publishes only complete closed graphs; hidden
constructor variables and graphs depending on them remain on the existing
compatibility path. This case needs real uniform boxing/unboxing or explicit
source type parameters before the full deterministic representation contract
can be claimed.

Validation passes:

- All **39 Haskell suites**, including call/root-order independence, regular
  and expanding recursion, nested list instances, tuples, canonical records,
  an uncalled raw projection and rejection of contradictory/missing evidence.
- The real native compile checks the uncalled helper's raw print adapter.
  RV64/QEMU then passes nested Int/Word lists, shared ownership, effect order,
  overflow/division differentials and the existing 1,000-cycle ownership case.
  Parameterized user types (`Bundle a b` and `Choice a`), scalar variant
  payloads, tuples and closed records also pass 1,000 leak-free cycles.
- The strict native ARC suite passes allocator/exhaustion, C-export lp64/lp64d,
  separate units, interrupt, raw-byte, sanitizer and independent scalar oracles.
- The [checked-layout cost record](../bench/2026-11-04-checked-layout-cost.json)
  preserves equal generic/explicit code sizes and function counts at 16 through
  256 helpers, within the unchanged absolute C2 allocation baselines.
- The unchanged host compile-cost gate passes again: hello 1.57 GB, std-live
  32.37 GB and pos1 69.73 GB allocated. No existing baseline or limit was raised.

## Scalar uniform exports (codegen 164, arcRev 13)

Ordinary builtin ARC C exports now have a tagged FP-RISC entry and a private
raw worker. `Word`, `Addr`, `F64` and `F32` cross that entry as managed scalar
boxes; `Int`, `Bool` and `Unit` retain their existing tagged representation.
Checked internal calls go directly to the raw worker. The source export name
and declared C signature are unchanged. The C adapter boxes arguments, calls
the tagged entry, and consumes/unboxes its result. This is a real conversion
boundary, with an allocation cost, rather than a claim that raw bits are
already safe managed values.

Explicit `--raw` units retain their allocation-free convention. In particular,
the FP-RISC allocator must never allocate a box just to call itself. Automatic
ARC remains a whole-import-graph lowering in this profile; it does not mix
separately inferred raw imported bodies with a tagged entry. The existing
separate C-library link and imported raw-convention tests pass.

Each public wrapper consumes its argument references and returns an owned
result. Unboxing validates the scalar kind and width and releases exactly one
reference. An address box owns its storage, not the address it contains.
Float conversions preserve payload bits, including signed zero, subnormals,
infinities and NaNs. Generic printing and equality also recognize boxed float
leaves on RV64: NaN is unequal to itself, including inside a shared aggregate,
and positive/negative zero compare equal. Existing RV32 numeric behavior is
preserved.

The adapter first stages all C arguments, then performs allocating conversions,
then fills the native registers and hart argument cells. This prevents calls
made while boxing one argument from destroying a later argument, including
hard-float registers and wide calls. Exported precondition checking entries
are pinned and wrapped too. Valid C calls therefore enter the checked body
with the correct representation, while invalid calls retain their named
precondition failure. Invalid source export declarations are admitted or
rejected before ownership rewriting, retaining the source diagnostic.

Validation:

- The independent C probes pass 2,176 lp64 and 1,024 lp64d calls per run,
  spanning all boundary kinds, 64 arguments, distinct integer/float register
  banks and IEEE edge patterns. Nullary, direct tagged-entry, shared-input and
  direct private-worker probes repeat 128 times per convention.
- The probes require the exact number of boundary boxes and zero outstanding
  allocations after each cycle. Direct private-worker calls allocate nothing.
  Precondition-protected exports additionally check exact boundary allocations
  and both successful and rejected calls. The complete probe also passes with
  `FPR_NO_TYPE_SPEC=1`; rollback does not remove the public boundary contract.
- Public and private entries produce identical printed prefixes and
  overflow/division/alignment failures. Supplying the wrong scalar box to a
  tagged entry is rejected before the body's observable effect.
- All 39 Haskell suites pass. The strict RV64 ARC suite passes, including the
  allocator implemented in FP-RISC, deep release, exhaustion, separate units,
  sanitizer ownership checks, interrupts and the independent scalar oracles.
  After the precondition pinning fix, the expanded boundary probe passes again.
- The six RV32 numeric runtime cases pass. The shared runtime also passes
  native A64 execution and real macOS x64 runtime execution through Rosetta.
  The Linux x64 test reports execution unavailable; only its shared compiler
  checks run on this host.
- The [isolated C2 cost record](../bench/2026-11-04-uniform-boundary-cost.json)
  passes the unchanged absolute and twin allocation gates at 16 through 256
  helpers. Generated function counts and code sizes still match the explicit
  monomorphic twins exactly. This helper family has no exported boundary, so
  it checks absence of an internal-path regression, not the cost of boxing.

This milestone does not enable arbitrary generic/aggregate conversion or
change hosted Base representations. It adds no physical-device qualification.

## Closed aggregate uniform exports (codegen 165, arcRev 14)

Closed checked aggregate exports now retain a tagged public entry and a private
representation-specific worker. This covers recursive lists, parameterized
nominal constructors and variants, tuples and closed records. The native C
adapter reports `KValue` for these arguments/results: they are owned FP-RISC
tagged values (`V`/`uintptr_t`), not C structs or ordinary C string pointers.
Every incoming reference is consumed and the returned value owns one reference.
A C caller keeping its input must retain it before the call and release the
returned value when done. Strings use the same owned tagged-value contract.
Manual/`--raw` export admission remains unchanged.

`Arc.Uniform` serializes the reachable checked type graph in sorted type-key
order, with a distinct private identity for descriptor chains. That identity
avoids colliding with a source `List Word` when specialization is disabled.
The public entry converts uniform arguments to their checked field layouts,
calls the raw worker, and promotes its result. Internal calls still select the
worker directly. An aggregate whose complete graph already uses managed fields
uses identity adapters, with no graph allocation or copying.

The production runtime converter is iterative. An explicit graph worklist and
hash table preserve sharing by source object and checked shape, and reject
cycles in the converted graph. There is no C recursion or fixed depth/arity
limit. Scalar payloads retain their exact bits; address leaves never own their
pointees. Already-managed subgraphs and leaves are retained rather than copied.
Node type, variant, exact field count and field-kind metadata are checked before
raw payloads can be interpreted as managed references. Conversion descriptors
are immutable static strings and outlive the converted objects. Temporary
graph tables, descriptor chains and input references are released on success.
Allocation failure remains the allocator's named failure.

`check_uniform_aggregate.py`, registered in Base and native CI, exercises the
actual generated exports and production converters:

- Lists, shared tuple fields, records containing Word/Addr/F64/F32/String,
  and a parameterized nominal variant pass with specialization on and off,
  using both the C and FP-RISC allocators. Each generated test repeats 128
  ownership cycles and checks zero outstanding allocations.
- Already-tagged `List Int` and String identity exports retain pointer identity
  and perform no ADT allocations. The two list instantiations are separate C
  libraries in the rollback case; rollback still refuses incompatible source
  instantiations of one nominal type within a unit.
- A 6,000-node list shared by two fields round-trips through promotion and
  demotion without recursive stack growth or duplicated shared nodes. It keeps
  an independent original reference alive, including when a raw Addr points
  into that original graph. Both allocators pass, as do the same production
  converters under host ASan/UBSan.
- Wrong field metadata, duplicate variant descriptors, cyclic input and a
  mismatched scalar box are refused by name. All 39 Haskell suites pass, along
  with the existing scalar export, allocator, interrupt and raw-bit ARC checks.
- The unchanged standard compiler budgets pass (hello 1.57 GB, std-live
  32.37 GB, pos1 69.73 GB allocated). The
  [aggregate-boundary C2 cost record](../bench/2026-11-04-aggregate-boundary-cost.json)
  retains exact code-size/function-count equivalence against explicit twins
  at 16 through 256 helpers and passes the existing absolute allocation gate.
  As with the scalar milestone, that family measures the internal path, not
  the cost of a foreign graph conversion.

This is a safe conversion fallback, not zero-cost foreign conversion: graphs
containing raw fields require boxing/copying and temporary map storage. It does
not yet make scalar wrappers immediate, widen the product return ABI, or admit
open generic and hidden-field nominal interfaces. Hosted Base representations
and physical-board qualification remain unchanged.

## Generic tagged fallback (codegen 166, arcRev 15)

Checked source type variables now have an explicit `UniformRep` contract,
distinct from raw scalar bits and concrete tagged integers. Parametric lists,
tuples, records and nominal types have stable checked field graphs with uniform
slots; their identity does not depend on the first caller or variable numbering.
Closed typed callers still use specialized workers. Generic exported entries
remain available alongside those workers and accept owned tagged values from C.

At a generic call edge, representation lowering first tries the ordinary
equations transactionally. When a uniform slot requires conversion, it records
that boundary and emits the conversion after all field/projection evidence is
resolved. Raw scalars are boxed/unboxed; aggregate field graphs use the existing
sharing-preserving converter. Already-managed subgraphs retain their identity.
A neighboring uniform slot cannot hide a contradictory fixed field type.
Conditional conversions execute only on the selected branch. This also works
with `FPR_NO_TYPE_SPEC=1`: disabling cloning preserves the generic ABI instead
of reverting to unsafe pointer/raw-bit unification.

Expanding polymorphic recursion stops creating instances when the same-origin
type graph structurally grows. It retains the original generic function and
routes that edge through its tagged contract. `--remarks` explains the choice.
Regular recursive instances still close on their existing function. Missing
field authority and unsupported representation conversions continue to refuse;
the fallback is not permission to invent a layout. Explicit `--raw` units keep
their inferred raw helper convention so allocator bootstrap never needs boxes.
The reserved interrupt entry fills otherwise unconstrained argument slots from
its three-Word runtime ABI and its Unit result contract. Conflicting concrete
source declarations still fail. Both interrupt and raw-unit admission reject
generated uniform conversions, including conversions introduced after source
checking: boxing allocates and unboxing can release heap storage. A generic
helper that is allocation-free after specialization may therefore correctly
fail interrupt admission with specialization disabled.

Raw F64/F32 generic `print` and `str` also have direct adapters. Printing uses a
borrowed stack descriptor, with no heap box; generic tagged and specialized raw
paths use the same rendering behavior.

Validation:

- All **39 Haskell suites** pass, including scalar/aggregate conversion edges,
  concrete-field contradictions, deterministic generic layouts, bounded
  recursive instances and raw/interrupt conversion refusals.
- RV64/QEMU executes a type-growing recursive function through one specialized
  instance and its generic fallback. Both specialization modes print the same
  seven-step sequence and leave no live allocations. Generic/specialized
  F64/F32/Word rendering, raw/generic branch joins and overflow/division failures
  also agree. Branch effects occur only in the selected arm.
- Generated C exports repeat 128 ownership cycles with both allocators and
  both specialization modes. Generic identity preserves the exact input pointer
  without allocating; generic list reversal allocates exactly one output cell
  per input, and counting adds no allocations. A checked internal Word call
  through a generic source helper allocates **zero** boxes when specialized and
  exactly **one** in fallback mode. Every cycle returns to its initial live count.
- Recursive fallback remarks pass text/JSON, cold/warm stability and unchanged
  emitted-code checks. The existing remarks suite passes across seven target
  modes and native execution. The production aggregate converter also retains
  its 6,000-node sharing/roundtrip and refusal checks under host ASan/UBSan.
- The final strict RV64 ARC suite passes, including the new interrupt refusal,
  C exports under both float conventions, 10,000 FP-RISC allocator cycles,
  exhaustion, deep release and independent raw-byte/arithmetic oracles.
- The unchanged standard compiler budgets pass: hello **1.57 GB**, std-live
  **32.37 GB**, pos1 **69.72 GB** allocated. The subsequent
  [isolated generic-fallback cost record](../bench/2026-11-04-generic-fallback-cost.json)
  passes both the absolute and explicit-twin allocation gates at 16 through
  256 helpers. Every size retains exactly the same assembled code bytes and
  function count as its monomorphic twin (10,520 B/48 functions through
  109,240 B/528 functions). No baseline or admission limit was raised.

Generic fallback deliberately has conversion costs. These checks establish
correct boundaries and preserve the specialized path's allocation advantage;
they do not claim that every polymorphic program is allocation-free or qualify
new physical-board behavior.

## Hidden-field nominal boundaries (codegen 167, arcRev 16)

Ordinary builtin ARC now gives hidden constructor variables explicit uniform
storage. For `Hidden = Type (Hidden a)`, the field layout follows the definition,
not whichever payload happens to reach its constructor first. The same nominal
type can hold different payload representations within one unit. Declared C
exports use the owned tagged-value contract for this type, including across
specialization rollback. Explicit raw units retain their allocation-free layout
path and still refuse managed C exports.

Construction promotes each hidden field. A known constructor is built directly
in the destination field layout, avoiding a temporary raw enclosing object and
its copy. A hidden Word therefore requires exactly **two ADT allocations**:
the payload box and the enclosing node. This is the cost of the uniform hidden
field, not a claim that hiding a known raw type is free. Fixed/parameterized
types retain more checked field information for specialization.

Extraction validates raw scalar boxes, tagged integers, strings and nominal
tags before interpreting them. Boolean/Unit extraction also checks the immortal
representation contract. Nested projections from a uniform object check field
count and managed-field metadata and transfer an owned reference correctly.
Thus an incompatible payload produces a named boundary failure instead of
being treated as raw bits, a Boolean false value or a differently typed list.

The `U2` conversion plan adds checked managed leaves and traverses every
reachable declared graph, including graphs that need no copying. The iterative
worklist preserves sharing and checks cycles. All-managed graphs retain object
identity; raw-containing graphs use the existing conversion path. Validation
still uses temporary descriptors and worklist/map storage. Those costs must be
included in any future static-arena or scheduling admission; this milestone
does not make dynamic boundaries allocation-free.

Conversions run after source argument evaluation. Both call boundaries and
direct constructor promotion bind each source argument once and in order before
boxing or checking it. A failed allocation/check cannot suppress a later
argument's print, or replace its earlier division-by-zero failure.

Validation:

- All **39 Haskell suites** pass. Checked layout tests distinguish uniform
  hidden fields from the allocation-free raw-unit path.
- `check_hidden_fields.py`, registered in Base and RISC-V CI, passes 28 generated
  C-boundary cases over the C/FP-RISC allocators and specialization on/off.
  Each successful case repeats 128 ownership cycles, checks the two-allocation
  constructor bound, nested extraction, shared strings/lists and zero outstanding
  allocations. Wrong scalar, string, Boolean and list payloads fail by name.
- Six host ASan/UBSan cases check the production converter on a 6,000-node
  shared managed graph, preserving exact identity without copying. Invalid
  scalar/nominal/field metadata and cycles are rejected.
- Six RV64/QEMU effect probes inject allocation failures or invalid payloads.
  Both specialization modes preserve the printed prefix and failure order,
  including a division failure before the first possible boxing allocation.
- Existing generic-specialization and aggregate-boundary execution checks pass.
  The final strict RV64 ARC suite also passes, including C ABI probes, raw units,
  interrupt restrictions/execution, allocator exhaustion and independent oracles.
- Standard compiler budgets remain unchanged and pass: hello **1.57 GB**,
  std-live **32.37 GB**, pos1 **69.72 GB** allocated. The subsequent
  [isolated hidden-field cost record](../bench/2026-11-04-hidden-field-cost.json)
  passes both absolute and twin allocation gates at 16 through 256 helpers.
  Every size still has exactly the same assembled bytes and function count as
  its explicit monomorphic twin. This measures the specialized internal path;
  it does not hide the documented cost of dynamic payload validation.

## Checked scalar wrappers (codegen 168 / arcRev 17)

Closed checked definitions with one constructor and one scalar field can now
use the field's register representation. This includes Word, Addr, F64, F32,
tagged Int/I32, immortal Bool/Unit and finite nesting of eligible wrappers.
Single-field closed records use the same rule. String, unknown/uniform,
recursive, multi-constructor and multi-field payloads retain boxed storage.
The choice comes from the instantiated definition, not from the first observed
constructor. Nominal identity remains in the representation solver after the
physical kind becomes the leaf kind.

Construction and projection disappear on the checked internal path. A known
single-constructor tag test still evaluates its scrutinee before returning its
constant result. Exact, effect-free constructor bodies can be exposed inside
the builtin path so cloning rollback does not force an otherwise unnecessary
generic constructor call. This exposure requires the actual body and checked
layout authority; it never drops an entry tick or arbitrary source function.
Shared typed erasure and hosted scheduling remain unchanged.

Generic and external boundaries still carry **nominal tagged wrappers**. The
new U3 graph format records scalar storage separately from nominal fields;
promotion reconstructs each wrapper, and demotion validates constructor id,
variant, field count, tagged field metadata and scalar payload before extracting
its bits. Nested scalar chains use an iterative walk. Boxes own their payload
references; an Addr payload never owns its pointee. Scalar wrapper fields in a
boxed product receive the scalar field descriptor. `print` and `str` promote
wrappers and enclosing aggregates when required, preserving nominal output.
Equality uses the underlying scalar operation, including IEEE NaN/signed-zero
behavior for wrapped floats.

The [10,000-step wrapped-word comparison](../bench/2026-11-04-scalar-wrapper-allocations.json)
now allocates **zero ADT objects**, matching its explicit scalar twin. The
previous codegen167 loop allocated 10,001 with specialization enabled and
40,004 with specialization disabled. The current zero-allocation result holds
in both modes. This is an allocation claim on RV64/QEMU, not a physical timing or
whole-program zero-overhead claim. Foreign/generic conversion and formatting
can still allocate nominal boxes, descriptors and scratch storage. Such scratch
storage must be included in future physical arena admission; ADT counters alone
are not an arena bound.

Validation for this slice:

- All 39 Haskell suites pass, including independent evaluator scheduling checks,
  deterministic checked storage, nested erasure, raw admission and invalid
  scalar-layout refusals.
- `check_scalar_wrappers.py` exercises both C and FP-RISC allocators, soft and
  hard float C ABIs, and both specialization settings. Each of the eight target
  configurations runs 128 cycles covering raw/internal zero allocations,
  public/generic round trips, retained aliases, nested and product fields, scalar
  records and Unit wrappers,
  exact F32/F64 NaN and signed-zero bits, Addr values and zero live-allocation
  drift. Each also runs the 10,000-step wrapped and explicit loops.
- Ten source probes preserve argument effects, division failure, checked
  overflow at both integer limits and pattern scrutinee execution. Nominal output is checked against the prior compiler's
  formatting behavior rather than accepting printed raw payloads.
- Seven host ASan/UBSan probes include a 6,000-wrapper round trip without C
  recursion and reject cycles, non-scalar fields, invalid scalar arity, nominal
  mismatches, wrong payload tags and raw metadata at a tagged boundary.
- Hidden-field validation, existing aggregate conversion and effect-order
  regressions pass again. Strict ARC passes with 2,176 lp64 and 1,024 lp64d
  independent C calls, exact boundary allocations, restored interrupt state,
  10,000 FP-RISC allocator cycles, deep release/exhaustion checks, 2,048 raw-byte
  cases and 879 independent word/Int checks. The new test
  is registered in the Base and RISC-V CI check registry; the eight registry
  tests pass. These are local runs, not a claim about remote CI.
- The unchanged standard compiler budgets pass: hello 1.57 GB, std-live
  32.37 GB and pos1 69.72 GB. The [C2 cost record](../bench/2026-11-04-scalar-wrapper-cost.json)
  retains equal code bytes/function counts against explicit twins at
  16/32/64/128/256 helpers and compiler-allocation ratios of 0.999–1.000x.
  Absolute compiler allocation is 131.0/232.2/440.7/891.4/1,903.8 MB.
  Wall times in this cost record are informational and were not an isolated
  throughput benchmark.

At codegen168 this milestone covered wrappers for which closed checked layout
evidence reached the representation boundary through interfaces. Local-only
closed layouts were still missing; the next milestone addresses that gap. Generic/open storage
continues to use its real tagged fallback. Multi-register products, hosted Base
storage changes and physical scheduling/arena qualification remain open.

## Checked local aggregate evidence (codegen 169 / arcRev 18)

The representation boundary now receives local aggregate types from the retained
checked expression tree, including closed instantiations inside generic bodies.
Previously its layout roots were only function arguments/results. A local
`Box Word`, nested wrapper or scalar record could therefore stay boxed even
though its checked type already justified scalar storage. No aggregate type
annotation in a function signature is now required for these local cases.

A checked erasure hook carries transient local representation markers with an
explicit evidence map. ARC consumes each marker by checking/converting the
value against the authoritative layout, then removes the marker. The evidence
comes from the checked owner; compatibility definitions retain their existing
projection. Reserved marker collisions are refused, and the markers never
become runtime calls or exported identities. A regression proves that removing
markers reproduces the ordinary erased program exactly, including binder and
control-flow structure. Generic slots retain their tagged contract; raw units
only receive closed local layouts and do not acquire allocating generic boxes.
Unsupported expanding layouts fail by name before emission rather than forcing
a failed pure projection.

The [paired allocation record](../bench/2026-11-04-local-evidence-allocations.json)
uses the same local-only source with codegen168 and codegen169. It runs 256
cycles of seven checked private-worker calls: Word and F64 wrappers, a scalar
record, nested wrappers, both branch outcomes, and a closed wrapper inside a
generic function. No ordinary function interface supplies these closed aggregate layouts.

| Compiler | Specialization enabled | Specialization disabled |
| --- | ---: | ---: |
| codegen168 | 2,048 ADT requests | 3,584 ADT requests |
| codegen169 | **0** | **0** |

Every call checks its result, including high Word bits and NaN payloads, and the
complete run checks zero live-allocation drift. These are RV64/QEMU allocation
results, not physical-board timing or a claim that generic boundaries allocate
nothing.

`check_scalar_wrappers.py` adds six local-only execution configurations: ordinary
ARC with both allocators and both specialization settings, plus allocation-free
raw units with both settings. They perform 10,240 checked private calls in total,
with zero ADT allocations, no leaked live allocations and no evidence marker in
the emitted assembly. The raw C fixture excludes the open generic entry; its
closed local cases remain allocation-free without ownership instrumentation. The same suite
continues to cover nominal output, ownership aliases, scalar records/Unit,
integer-limit overflow, division/effect order, soft/hard float C ABIs and deep
conversion validation.

All 39 Haskell suites pass. Existing hidden-field, aggregate, specialization
and strict ARC execution suites also pass, including the generic fallback,
export-allocation and interrupt/allocator checks. The registry still runs this
coverage as part of its scalar-wrapper check. These are local host/emulator
runs, not new remote CI or physical-board qualification.

The unchanged standard compiler gates pass at hello 1.59 GB, std-live 32.69 GB
and pos1 70.28 GB allocated. The largest baseline delta is std-live at +9.2%,
within the existing +10% allocation margin. The
[C2 cost record](../bench/2026-11-04-local-evidence-cost.json) keeps exactly equal
assembled code sizes/function counts against explicit twins at
16/32/64/128/256 helpers, with compiler-allocation ratios of 0.999–1.000x and
absolute allocation of 135.0/239.8/455.3/920.3/1,961.3 MB. Compiler cost grew
slightly to preserve and check the local evidence; no budget was loosened.
Recorded wall times are informational, not an isolated throughput benchmark.

This extends evidence for the supported finite checked aggregate layouts. It
does not turn open rows, unknown/opaque representations or arbitrary function
values into unboxed aggregates. Wider multi-register products and their target
calling conventions remain the next representation milestone.

## Private product-return foundation (codegen 170)

The [wider product-return implementation](2026-11-05-PRODUCT-RETURNS.md) extends
hosted Base private returns to 2–8 value words on AArch64/RV64, with the existing
pair convention on x86-64. Larger products and escaping uses retain the original
tagged entry. Ordered result packets are verified and selected as one call;
all result registers have explicit placement and clobber contracts. Source
field effects/traps retain their order, including unused returned fields.

All 39 Haskell suites passed. Native source tests remove exactly 1,000 returned
constructor allocations for 1,000 calls at each supported width, with the
isolated controls described in the implementation note. RV64 QEMU passed
14,700 independent C-reference results with volatile-register-clobbering fuel
resets. These results establish a wider private return mechanism, not raw
builtin aggregate storage or a platform C aggregate ABI.

The [default-settings benchmark](../bench/2026-11-05-product-returns-5m.json)
removes all approximately five million allocations for the three-, four- and
eight-field workloads. Median times fall from 31.039/34.938/51.829 ms to
28.323/33.072/47.489 ms, winning 13/13, 12/13 and 13/13 alternating comparisons.
The shorter 500,000-call samples are retained separately in the implementation
note. These are workload-specific native arm64 throughput results, not latency
or physical-board qualification.

The legacy pair/actor, new native product, RV64 oracle, scalar-wrapper and
strict ARC suites passed. Unchanged compiler budgets passed at 1.59/32.73/70.33
GB for hello/std-live/pos1; std-live remains close to its +10% allocation ceiling
at +9.4%. The 16–256-helper C2 cost gate retains exact code/function parity and
0.999–1.000x compiler-allocation ratios to explicit monomorphic twins.

## Checked builtin scalar-product values (codegen 171 / arcRev 19)

The [checked product value ABI](2026-11-05-BUILTIN-PRODUCTS.md) now connects
complete per-definition layouts to private parameters, returns, local bindings
and branch joins. Eligible fields are immediate scalar values, including nested
scalar wrappers. The nominal heap representation remains boxed, with exact
field descriptors and existing generic/public conversion contracts. Oversized
products and parameter expansions have explicit boxed fallbacks.

The [allocation record](../bench/2026-11-05-builtin-products.json) verifies a
10,000-step two-field loop at **10,001 → 0** allocator requests, matching the
explicit scalar loop's zero. Checked products also remain allocation-free with
type specialization disabled. Twelve RV64 QEMU configurations cover both
allocators, both float ABIs and the independent rollback modes. They test local
and eight-field products, oversized arguments, shared/public/generic values,
heap-contained products, exact scalar bits and restored live-allocation counts.
Eighteen effect/failure programs preserve argument order, unused-field traps,
branch selection and both integer overflow endpoints. All 39 Haskell suites
and the strict ARC, scalar-wrapper, aggregate-conversion, hidden-field, hosted
product, RV64 result-oracle and legacy pair/actor regressions passed locally.
Unchanged compiler budgets passed at 1.59/32.73/70.33 GB; the 16–256-helper
specialization gate retained exact emitted-size/function parity and
0.999–1.000x compiler-allocation ratios to explicit twins.

This is genuine removal of private constructor allocation, with explicit
materialization at boundaries. It does not qualify raw/interrupt products,
owned-reference packets, open rows, scheduling latency or physical arena use.

## Raw and interrupt products (codegen 172 / arcRev 20)

[Two-stage product admission](2026-11-05-RAW-PRODUCTS.md) now checks source
representation evidence and the actual lowered call graph. Raw units and
interrupt helpers may use eligible private products without materializing
constructors. Expanded parameters must still fit the existing eight-word
register-only ABI; heap fallback, ordinary heap projection and allocating
conversion edges remain refused. Exported constructor-shaped definitions are
included in raw root checks.

Four raw-library builds execute eight-word recursion/joins, exact scalar bits
and memory effects without an allocator or retain/release implementation linked.
Four production-runtime configurations each verify **1,001 resumed interrupts
and zero handler allocation requests**, with the existing full register/fcsr
restoration probe. Ten failure programs verify an accumulated ordered memory
trace before both Int overflow endpoints, division, shift and alignment failure.
The [validation record](../bench/2026-11-05-raw-products.json) retains exact scope
and compiler/test hashes. All 39 Haskell suites, strict ARC, scalar wrappers,
ordinary builtin products and unchanged compiler-cost gates passed locally.

This closes raw/interrupt scalar-product admission. It does not establish a
handler duration, interrupt-stack bound, actor response deadline or hardware
WCET. Those remain explicit scheduling and static-arena qualification work.

## Separate-unit type-instance foundation (codegen 173)

The [retained-entry prototype](2026-11-05-BASE-TYPE-INSTANCE-CONTRACTS.md)
preserves original entries and admits private instances by complete checked
type. Explicit origin/scheme/arity declarations survive callback copying,
inlining and fusion. Cross-unit linking and emission reject missing homes,
copied definitions and stale physical arities. Verified recursion measures can
be prepared explicitly for specialized instances; absent proof remains unknown.

Eager Base activation failed the unchanged compiler budget at
1.76/37.70/80.62 GB for hello/std-live/pos1 and was removed. Preparing measure
provenance on the ordinary Base path also forced extra analysis, so that
preparation belongs to an explicitly enabled specialization consumer.
**This is a checked pipeline foundation, not completed Base representation
lowering or a new allocation-removal result.** The default Base ABI and analysis
path remain in place while a profitable layout consumer is developed.

The final compiler passes all 39 Haskell suites, RV64 specialization semantics
and the unchanged compiler budget at 1.59/32.74/70.33 GB. The 16–256-helper
C2 gate retains exact code/function parity at 1.001–1.002x compiler allocations
to explicit twins. The implementation note records the rejected experiments
alongside the accepted result; no baseline was raised.

## Guarded one-field Base workers (codegen 174)

[One-field constructor and seed admission](2026-11-05-BASE-WRAPPERS.md) now
removes wrapper cells through private recursive loops while retaining original
public arities, shape guards and boundary materialization. Successive existing
worker rounds also remove two nested wrappers. The payload remains an ordinary
Base value; no new raw ownership or public representation is introduced.

The 1,000-step Int loop drops from 1,001 allocations to zero, matching its
explicit twin; nested wrappers drop from 2,002 to zero. Returned wrappers and
heap-valued payloads retain the expected boundary cells. Normal-region and
one/four-worker checks preserve outputs, both Int limits, exact effect/failure
prefixes, unused-seed strictness and module calls. All 39 Haskell suites and
the existing worker regressions passed.

The 50-million-step native arm64 benchmark uses default region settings and
separate allocation/timing builds. The field-worker control comparison drops
from 50,000,003 allocations to zero and from 196.31 to 44.86 ms median, winning
13/13 samples. The explicit loop is also allocation-free at 44.91 ms median.
Unchanged compiler budgets pass at 1.59/32.75/70.35 GB, and the 16–256-helper
C2 cost gate retains exact code/function parity.

This is genuine Base wrapper allocation removal within the existing guarded
worker subset. It does not complete canonical type-directed Base layouts,
general aggregate ownership, scheduling latency or static-arena admission.

## Competing-actor scheduling qualification (codegen 174)

The [new native qualification](2026-11-05-SCHEDULER-LATENCY.md) covers scalar,
wrapper, product, fused/unfused/unbatched list and large message-copy work.
Every CPU competitor must exhaust fuel during an instrumented measurement
window. Ordinary executables have no probe hooks and separately measure
request/reply latency. All 81 combinations of workload, competitor count,
local/cross-hart placement and one/four live harts passed their correctness and
progress gates; the recorded longer run contains 243,000 ordinary replies.

With eight same-hart competitors, wrapper/product allocation removal reduces
median response from 21/36 µs to 10/16 µs. Unbatched list loops respond sooner
than batched loops because they yield more often. The final large-copy sample
maximum is 666 µs, while an earlier inspected run reached 2,651 µs and had
eight replies over 1 ms. That earlier summary is retained explicitly, even
though its raw record was overwritten. No sampled latency ceiling is treated
as a proven admission bound.

A deliberately unbounded C call starves the requester and is caught by the
host watchdog on one/four harts. Full RV64 per-function instruction reports
pass, but interprocedural composition, bounded runtime C costs and physical
time remain unprovided. The ordinary scheduler locality and tick-batching
regressions also pass. This closes the missing empirical contention check;
scheduling time bounds and static-arena admission remain unfinished.

## Resource-equation prerequisites (codegen 175)

The [source resource-equation audit](2026-11-05-RESOURCE-EQUATION-PREREQUISITES.md)
reproduced three undersized accepted contracts: branching recursion priced by
depth, growing recursive payloads priced at their initial size, and partial
applications charged only for supplied arguments. The first two now remain
unproved without the missing recurrence; closures charge their full runtime
capacity. Unknown over-application and lexical shadows cannot borrow an
unrelated resource contract.

Native one/four-hart tests observe a 31-node tree requesting 744 bytes against
the former accepted 144-byte bound, and a closure requesting 56 against 24.
All 39 Haskell suites, source cost/report checks, region lifetime checks and
the wrapper/materializing allocation regressions passed. Unchanged compiler
budgets pass at 1.59/32.66/68.92 GB; the C2 twin gate retains exact code/function
parity. The old std-map bound fixture remains an explicit refusal because its
growing reverse accumulator still needs a recurrence proof.

This strengthens a prerequisite; it does not implement physical arena admission.
Verified input domains/result sizes, useful accumulator recurrences, final
physical allocation/stack accounting and target enforcement remain required.

## Signed resource domains (codegen 176)

The [signed-domain correction](2026-11-05-SIGNED-RESOURCE-DOMAINS.md) clamps
recursive call counts at zero before charging the base case. Resource
comparisons now distinguish signed input values from nonnegative costs and
lengths, preserve exact `max` budgets, and check negative declaration-only
terms. Existing enforced value preconditions can establish nonnegative inputs;
a termination measure alone cannot. Direct, partial and escaped calls retain
their runtime boundary checks.

Four invalid contracts accepted by codegen 175 are now refused, including
an unknown span whose two argument placeholders previously cancelled. Explicit
clamp bounds preserve valid negative inputs, including the minimum Base Int,
and independent integer evaluation checks the inequality solver's claimed
proofs. This closes the implicit-nonnegative-input assumption in the source
checker. All 39 Haskell suites, native resource and region-lifetime checks
pass. Unchanged compiler budgets pass at 1.59/32.69/68.96 GB, and the C2 twin
gate retains exact code/function parity. An initially over-budget bookkeeping
implementation was rejected and compacted without allowing unknown-value
cancellation. Verified result sizes, accumulator recurrences and final physical
resource accounting remain prerequisites for static-arena admission.

## Verified result-size composition (codegen 177)

The [result-size pass](2026-11-05-VERIFIED-RESULT-SIZES.md) now proves typed
list/String bounds before using them in a caller's resource equations.
Recursive map/reverse/filter accumulators, measured zip inputs, signed repeat
and inclusive ranges have checked invariants. Exact sizes and upper estimates
remain distinct; non-monotone substitutions stay opaque. Source `size`
annotations are candidates, not trusted assumptions.

The previous compiler accepted a 64-byte string-composition budget that needs
80 requested bytes, and a copying budget based on a false two-elements-per-input
size invariant. Both caller proofs now fail. Native checks observe the string
fixture's three allocations/112 managed block bytes, preserve outputs on
one/four harts, and retain minimum-range overflow and its preceding effect.
Twelve standard list size candidates are proved; `unique` and sorting remain
explicitly unproved and their annotations are unused.

All 39 Haskell suites, native resource/region checks, list fusion and the
materializing-pipeline regressions pass. The unchanged compiler budget passes
at 1.59/32.68/68.98 GB; the C2 twin gate retains exact code/function parity.

This supplies verified result-size facts for the supported operations, not
cumulative work/peak-live bounds for changing accumulators. Physical allocation,
stack, runtime/scheduling and exact-image admission remain unfinished.

## Physical native stack accounting (codegen 178)

The [native stack summary](2026-11-05-NATIVE-STACK-ACCOUNTING.md) now owns
physical frame sizes and selected call edges after register allocation and
layout. It composes ordinary calls, releases caller frames at tail transfers,
and bounds tail-only recursive components. Runtime/foreign/dynamic boundaries,
missing definitions and recursion retaining stack remain explicitly unproved.
The summary includes x86-64 return-address and call-alignment storage.

An independent oracle covers all 19,683 three-node call graphs. All four native
backends have layout/call tests; RV32 and RV64 execution independently measures
exact stack high-water for five closed builtin probes, including 24 live values
forcing spills. These are generated-unit bounds, not a linked-image or static
arena certificate. Hosted runtime frames, export/interrupt adapters, heap/live
storage and physical target timing remain open.

All 40 Haskell suites and the materializing-pipeline regressions pass. The
unchanged compiler budget passes at 1.61/32.91/69.40 GB; std-live is close to
its limit. The C2 gate retains exact code/function parity through 256 helpers.

## Public callback stack budgets (codegen 179)

The [callback admission contract](2026-11-05-CALLBACK-STACK-BUDGETS.md) now
checks `--stack-budget=BYTES` for every builtin RV64 C export. Checked adapter
frames are part of the native call graph; uniform conversions, runtime calls,
missing definitions, retaining recursion and over-budget callbacks refuse
admission. Limits are enforced before publishing new root assembly.

An impossible `truth True`/panic guard left after product erasure is now
removed using immutable Bool evidence, preserving prefix effects and overflow.
This allows a real unboxed product callback to acquire a bound. The independent
RV64 execution harness runs 192 loop/product callbacks in each of plain and
measured modes on an 80-byte guarded stack with no allocator in either image;
measured peaks match 32/80/32-byte bounds. Both exact linked test images pass
target-image admission as a separate gate. Weak definitions refuse admission
because linked replacements can invalidate a local bound.

All 40 Haskell suites, native stack execution, raw-product/interrupt execution
and materializing-pipeline regressions pass. The unchanged compiler budget
passes at 1.60/32.80/69.20 GB, with std-live peak residency close to the limit
(+24.9%). C2 retains exact code/function parity through 256 helpers. See the
[validation manifest](../bench/2026-11-05-callback-stack-validation.json).

This closes public-entry stack-budget enforcement for closed native callbacks.
It does not yet install heap arenas, prove runtime/C costs or account for
startup, caller stacks and interrupt nesting. Whole-image storage admission,
reference timing and physical-board qualification remain open.

## Complete load-segment accounting

The image gate previously accepted an 8,193-byte load extent in an 8,192-byte
RAM fixture because its allocated section described only 256 bytes. Complete
segment file/memory extents now determine admission; malformed alignment and
overlapping load ranges also refuse. Schema-2 receipts distinguish the new
checks from historical section-only receipts. All twelve boundary tests,
four target build/preservation configurations and both fixed-stack callback
execution modes pass. See the [contract and evidence](2026-11-05-LOAD-SEGMENT-ADMISSION.md).
This strengthens image-fit correctness; dynamic heap/arena and timing proofs
remain unfinished.

## Builtin physical heap geometry

Allocator-backed geometry queries now share the runtime's checked range and
request-size arithmetic. They expose the real 48/80-byte RV32/RV64 prefixes,
minimum payload, bitmap reservation and split-tail limitations. Independent
sanitizer and RV32/RV64 execution observes all request sizes through 4,096;
a seven-allocation trace uses exactly 544/768 arena bytes and refuses a
one-byte shortage without corrupting prior payloads. See the
[geometry contract and evidence](2026-11-05-BUILTIN-HEAP-GEOMETRY.md).

Uninstrumented allocation/release instruction counts match the baseline at
512, 2,048 and 8,192 nodes on both XLENs. This is an accounting foundation;
compiler-to-runtime allocation/count proofs, peak-live/fragmentation admission,
runtime C stack and hardware timing qualification remain open.

## Allocating callback heap budgets (codegen 180)

The [heap-budget contract](2026-11-05-CALLBACK-HEAP-BUDGETS.md) adds enforced
`--heap-budget=BYTES` for explicit builtin RV64 ARC C exports. Final verified
native IR supplies cumulative request counts and requested bytes; checked
adapter conversions are included. Physical admission includes allocator
prefixes, alignment, unsplittable tails and the live-start bitmap. Unknown
runtime calls, missing/interposable definitions and allocating cycles refuse.
Exact limits pass; a one-byte shortage refuses before replacing root assembly,
including when a previous successful output is cached.

Plain and measured RV64 QEMU images execute 256 callbacks each on fresh guarded
arenas. Word identity, twelve Word arguments and conditional selection need
conservative admitted capacities of 416/2,640/624 bytes; observed peak block
storage is 112/1,344/224 bytes. Measured requests match the proof and every call
reclaims all live allocations. Heap admission changes no callback instructions.
Both exact test images separately pass schema-2 target-image admission.

All 41 Haskell suites, native/callback stack execution, allocator geometry,
materializing pipelines and registry checks pass. Compiler-cost gates pass at
1.59/32.68/68.98 GB; C2 retains exact code/function parity through 256 helpers.
Ordinary compilation now requests stack reports explicitly with `--stack-report`
(automatic for C exports/admission), reducing std-live peak memory to 428 MB.
The stack solver is unchanged; cached-unit report refresh preserves code and
unit identity. See the [validation manifest](../bench/2026-11-05-heap-budget-validation.json).

This admits one invocation on a fresh aligned, exclusively used builtin C heap.
It is a cumulative capacity proof, not a tight peak-live bound. Allocating loops,
runtime C-stack bounds, complete conversion/region/reallocation accounting and
linked-runtime identity still need work. Caller/startup/interrupt storage and
concurrent entries are not yet composed into whole-image admission. No new
physical-board timing or WCET qualification is claimed.

## Linked native/C stack admission

The [linked stack gate](2026-11-05-LINKED-STACK-ADMISSION.md) now derives bounds
from actual executable bytes, including C runtime calls and panic paths. It
handles direct calls after relaxation, fixed large frames, ordinary loops and
tail transfers, while refusing unresolved control, changing stack joins and
retaining recursion. No source annotation, old sidecar or fixed assumed C
frame supplies authority. Receipts bind the exact image and target manifest.

Allocating identity/wide/conditional callbacks have 224/400/256-byte linked
bounds; unmodified instruction-step QEMU observations reach 208/384/240 bytes.
Both plain and heap-counter images retain their heap-guard/reclamation checks.
The raw callback execution harness independently retains exact 32/80/32-byte
agreement with the compiler's stack proof. Seven test groups include 216
independent call graphs, changed runtime frames, unsafe refusals and preserved
receipts. This is a fixed-width RV64 IM subset under the ordinary valid-memory
and register/return ABI contract, not an arbitrary-machine-code verifier.

`BUILTIN_STACK_ENTRIES` optionally enforces per-entry bounds before the builtin
image build publishes its image/receipt. Virt manual/ARC exact/short/missing
entry checks and the existing four image configurations pass. Ordinary image
receipts remain schema 2; an enforced linked-stack proof is embedded in schema
3. Disabling the option removes the old claim when publishing a new image.

This supplies concrete C runtime stack accounting for the admitted linked
subset. Heap-contract/runtime binding, actual arena placement, caller/startup/
interrupt composition, compressed or dynamic runtime paths and physical timing
qualification remain open. The compiler binary is unchanged from codegen 180.

## Compressed linked stack paths

The [compressed-stack follow-up](2026-11-05-COMPRESSED-STACK-ADMISSION.md)
extends the gate to integer C instructions, halfword-aligned full instructions
and two-byte call continuations. All 38,550 supported short encodings agree
with independent disassembly; 216 call graphs run in each of IM and IMC form.
Twelve test groups retain the refusal and exact/short-budget contracts.

Real allocator callbacks keep 224/400/256-byte bounds in both encoding modes,
with observed high-water of 208/384/240 bytes. The 192-call raw harness retains
exact compiler/linked/observed stack parity. The normal builtin build gate
now accepts genuinely compressed entries without changing default flags.

The earlier trace oracle logged only predicted PCs, potentially hiding an
omitted path. It now traces every executable section independently; a fault-
injected unpredicted path is rejected. This strengthens path-coverage evidence
and replaces the filtered trace qualification. No compiler code or allocation
behavior changed. Heap/runtime identity, arena placement and caller/startup/
interrupt composition, broader representations and physical timing remain open.

## Owned product packets (codegen 181, ARC revision 21)

Checked private builtin products can now carry owned references alongside
scalar words. Strings, lists and other boxed payloads retain their existing
representations while the enclosing two-to-eight-field wrapper disappears.
Field ownership transfers through calls, returns and joins; nominal boxes
remain at public/generic/heap boundaries and oversized argument expansions.
Lexical packet aliases and one-word field bindings borrow from their live
parent owners, retaining only at consuming uses. Raw/interrupt code still
refuses owned products. Nested products were not flattened at this milestone;
the codegen-184 follow-up below adds eligible acyclic nesting.

The String/Word loop's 1,001 wrapper allocations become **zero**, matching its
explicit loop. A list-payload loop drops from 1,005 constructor allocations to
**four**, also matching its explicit loop's payload construction/conversion.
The twelve ARC-check configurations cover both allocators, soft/hard ABIs,
type-specialization rollback and boxed rollback. Aliased Strings, nested/heap
values, returned String handles, public tagged layouts, full-width Words and
wide-argument fallbacks reclaim completely. Effects, unused-field division
and both integer-overflow endpoints agree exactly across three modes.

The uninstrumented RV64 QEMU work probe at 10,000 steps drops from 19,143,047
guest instructions to **2,121,227**, versus the unchanged explicit loop's
3,581,374. The boxed rollback reproduces the old count. Repeated counts agree
at 100/1,000/10,000 steps. This is instruction-count evidence, not physical
timing or a WCET claim. See the [ownership contract and evidence](2026-11-05-OWNED-PRODUCT-PACKETS.md).

All 41 Haskell suites and the existing builtin/raw products, uniform/hidden
boundaries, scalar wrappers, heap budgets and registry regressions pass.
Unchanged compiler budgets pass at 1.59/32.68/68.97 GB; C2 keeps exact code
size/function parity through 256 helpers at 1.000–1.001x compiler allocation.

## Controlled static-activation arenas (compiler unchanged at codegen 181)

`tools/build_static_arena.py` builds a bounded builtin scalar callback into a
controlled RV64 virt activation image. Fresh compiler heap evidence is paired
with an audited C-runtime/ABI dependency contract and a closed link recipe.
There are no user-supplied objects, runtime choices or link overrides. The
selected target and physical RAM geometry are checked independently of the
manifest's claims; the final image binds every receipt by hash.

The linker reserves distinct heap/stack regions and guard bands alongside all
static data and native argument cells. Startup selects the reserved stack,
clears BSS and enters the generated caller with ordinary interrupts disabled.
The complete caller/allocator/native/output/panic stack is proved from actual
linked code. A callback that proves zero heap demand reserves zero heap bytes
and omits heap initialization. Other callbacks initialize exactly their admitted
fresh arena and must reclaim it completely before successful termination.

Ten callback configurations execute at their proved stack limits, including
both Int limits, full-width Words, mixed argument kinds and 64 arguments.
The Word identity uses 416 heap bytes and a 352-byte linked stack bound;
twelve Word arguments use 2,640/560 bytes, and 64 arguments use 13,120/1,808.
Four independent full-code traces verify exact startup BSS stores, initial SP,
executed-PC coverage and stack high-water. Short budgets, changed/omitted
runtime contracts, wrong targets/geometries, unsupported/interrupt-control
calls, overlapping regions and failed guard checks refuse without replacing
existing successful artifacts. The check is registered in Base and required
RISC-V execution coverage. See the [contract and evidence](2026-11-05-STATIC-ACTIVATION-ARENAS.md).

This closes runtime selection, provisioning, startup/caller composition and
placement for a single fresh activation; it is not a general application or
physical WCET claim. The compiler binary is unchanged, so this introduces no
new abstraction-removal or compiler-performance claim. Word HAL/arithmetic
contracts, allocating loops, peak-liveness proofs, general conversions,
concurrent dispatch, resumable interrupts, Base arenas and physical-target
qualification remain open.

## Shared scalar selection and arena admission (codegen 182)

RV64 selection and heap analysis now share checked descriptions for 21 pure
Word/comparison/address adapters. The compiler already inlined these operations;
the resource checker previously mistook them for unproved runtime calls. The
same instructions now admit bounded storage for useful zero-allocation loops.
This is a resource-proof improvement, not a new runtime speedup.

The 76 independently checked execution cases cover full-width wrapping,
conversion endpoints, comparison outcomes and address-bit arithmetic. The
0/10,000/100,000-step loop cases all execute with 624 heap bytes and a 368-byte
linked whole-activation stack limit. Only three boundary conversion requests
remain; the loop body allocates nothing. Instructions/data match the saved
codegen-181 compiler and ordinary compilation. Guarded shifts and checked
overflow still refuse admission. See the [contract and validation](2026-11-05-SCALAR-ARENA-ADMISSION.md).

## Eight-word x86-64 results (codegen 183)

The private hosted Base convention now supports eight returned words on x86-64,
matching AArch64/RV64's width. Public and escaping values retain their original
tagged entries. The eighth result occupies `r10`, so the parallel-copy resolver
now protects completed and identity destinations from later scratch use.
All 256 mappings in an independent copy oracle pass; the isolated old resolver
fails that oracle.

The backend executes 16,800 independent C-reference results across widths two
through eight, including repeated fields, with volatile-register-clobbering fuel resets and no allocator
linked. Separate real-runtime recursive-product actors return correct answers
with the pass on/off on one/four workers; each configuration observes 150 fuel
exhaustions. Source checks preserve 96 live fields, heap-valued fields, escapes,
effects, failures and the nine-field fallback.

At five million calls with normal settings, widths three/four/eight remove
5,003,661/5,003,661/5,006,098 allocations respectively, reaching zero. Separate
Rosetta timing medians improve from 101.788/107.157/137.214 ms to
78.429/84.758/110.504 ms, winning 13/12/13 of thirteen pairs. This is measured
x86-64-under-Rosetta throughput, not native Intel or physical scheduling time.
See the [contract and evidence](2026-11-05-X64-PRODUCT-RETURNS.md).

## Nested builtin product packets (codegen 184, ARC revision 22)

Checked acyclic product nesting now flattens into the parent's private leaf
packet within the existing target capacity. Complete type-graph evidence fixes
the shape independently of caller order; recursive edges and over-wide
expansions retain boxed child boundaries. Each leaf has its own checked kind
and ownership, while public/generic/heap materialization rebuilds the original
nominal tree. Raw/interrupt admission still refuses owned leaves and boxes.

The nested String/Word-plus-String loop drops from 1,001 constructor allocations
to **zero**, matching its explicit loop. Fully disabling product lowering
produces 2,002 allocations because that also restores the outer box. At 10,000
steps, repeated QEMU guest instruction counts fall from 13,232,785 to
**3,611,702**, versus the unchanged explicit loop's 6,531,997. These are
allocation and executed-work results, not hardware timing.

The twelve-configuration ownership matrix preserves nested aliases, joins,
distinct String fields, tagged public trees, heap escapes and complete
reclamation. Nested strictness/effect/trap differentials agree across default,
type-specialization rollback and boxed modes. An allocator-free raw oracle
checks every position in a three-level eight-leaf tree, plus F64/F32 payloads;
the four resumed-interrupt configurations each execute 1,001 invocations with
register restoration and zero handler constructor allocation.

A nested Word loop also composes with controlled static-arena admission:
0/10,000/100,000 iterations use the same **624 heap bytes and 368-byte linked
whole-activation stack bound**. The previous compiler refuses its allocating
cycle. Exact-budget execution, short-budget refusals, reclamation, guards and
a zero-iteration full-code trace pass. See the
[representation contract and evidence](2026-11-05-NESTED-PRODUCT-PACKETS.md).

All 41 Haskell suites and the existing aggregate/ownership/boundary/resource
regressions pass. Unchanged compiler budgets pass at 1.59/32.68/68.98 GB;
C2 retains exact emitted code/function parity through 256 helpers at
1.000–1.001x compiler allocation versus explicit monomorphic twins.

## Open-record boundary contract (codegen 185, ARC revision 23)

Open rows now have a stable tagged fallback, including nested records and
open-record elements inside finite container layouts. Concrete callers convert
using complete checked field graphs. Shape dispatch checks all known row
labels against the compiled catalog; a nonmatching nominal tag falls through
without a conversion trap. Explicit field/scalar conversion failures remain.
Raw open-row exports refuse before emission.

Record update planning now uses the checked row type. Closed rows exclude
unrelated shapes; open plans may narrow after inlining but must retain every
required branch and valid physical shape facts. This fixes impossible
representation joins and improves Base's checked record planning without
enabling broader Base storage specialization.

The boundary matrix covers 32 configurations, 128 inputs per successful
configuration, exact Word/IEEE bits, nested updates, recursive helpers,
lists of records, retained originals and complete reclamation. Eight semantic
cases agree with specialization on/off, including unused-field failures,
effect order, hidden-type pattern fallthrough and both overflow endpoints.
Hosted Base checks the corresponding Int operations on one/four workers.
Those checks also exposed and fixed a Base Bool-pattern crash on an integer
payload: only a proven predicate now bypasses the guarded nominal tag test.
Checked builtin Bool use still rejects invalid hidden payloads.
See the [contract, baseline refusals and qualification evidence](2026-11-05-OPEN-RECORD-BOUNDARIES.md).
This is a boundary/semantic milestone, not a new runtime-speedup claim.

All 41 Haskell suites and 15 qualification groups pass, including existing
allocation/raw/ownership gates and controlled arena execution. Unchanged
compiler-allocation budgets pass at **1.60/32.64/67.14 GB**; C2 keeps exact
assembled code/function parity through 256 helpers at **1.000–1.001x**
compiler allocation versus explicit twins. Host/emulator evidence does not
qualify physical scheduling time or general application arenas.

## One-field owned wrapper payloads (codegen 186, ARC revision 24)

Checked one-field owned wrappers now travel through private calls and joins
as their payload. One-leaf results use the ordinary single-word convention;
eligible wider nesting uses the existing product ABI. Ownership remains per
leaf, and public/generic/heap boundaries reconstruct the nominal wrapper tree.
Raw and interrupt paths retain their owned-reference refusals.

At 1,000 steps the String wrapper drops from **1,001 to zero** constructor
requests, and two nested wrappers drop from **2,002 to zero**, matching the
explicit payload loop. A list wrapper drops from **1,005 to four**, retaining
the same payload cells as its explicit control. Twelve ownership configurations
and seventeen effect/trap cases preserve shared payloads, escapes, public
layouts, complete reclamation and both overflow endpoints. Hidden generic
payloads retain their required tagged scalar boxes.

See the [payload contract and qualification evidence](2026-11-05-OWNED-WRAPPER-PAYLOADS.md).

At 10,000 steps the wrapper drops from **26,802,901 to 3,711,238** executed
guest instructions, versus **3,691,383** for the explicit loop. Ordinary and
disabled inlining give the same repeated results: about **86.2% less work**,
with about **0.54%** residual overhead against the explicit spelling. This is
QEMU instruction evidence, not hardware timing. All 41 Haskell suites and
18 qualification groups pass, including unchanged compile-cost gates,
ordinary-inlining ownership, saved/current public-boundary checks and the
existing controlled arena recipes.

## Checked Base product parameters (codegen 187)

Base now consumes checked immediate product layouts to remove allocations at
nonrecursive helper calls that remain after ordinary inlining. The shape comes
from complete nominal declarations or closed tuple/record types; generic fields
retain their ordinary tagged Base value representation. Original entries keep
their nominal guard and full fallback body. Open rows and sums do not receive
an arbitrary canonical shape. Binder evidence is transported explicitly through
compatibility renaming and included in relevant module cache identities.

At 1,000 iterations, one-field, 2/4/8-field tuple, closed-record and generic
String helpers drop from **1,000 to zero allocations**. The generic list helper
drops from **1,002 to two**, retaining only its actual list cells. A loop inside
its owning imported module also reaches zero. Public cross-module calls retain
the tagged ABI, and a wrong-type actor message reaches the original fallback.
The saved compiler and current compiler agree on exact effects and failures,
including division by zero and both Int overflow limits.

See the [representation contract and evidence](2026-11-05-BASE-PRODUCT-PARAMETERS.md).
This is allocation removal at a checked, guarded call boundary. Broader Base
raw storage, variant/recursive layouts and physical scheduling admission remain
separate unfinished work.

At 20 million native helper calls, default-region allocations drop from
**20,009,766 to zero**. Median time falls **198.05 → 187.47 ms**, versus
**187.26 ms** for the explicit helper, with **13/13** paired wins. The
99-configuration scheduling matrix records 76,032 plain-runtime responses
and preserves per-actor fuel/progress checks; its sampled 318 us maximum is
not a physical latency bound. All 41 Haskell suites and 15 qualification
groups pass. Unchanged compiler budgets pass at **1.60/32.76/67.40 GB**;
C2 retains exact code/function parity through 256 helpers at 1.000–1.001x
compiler allocation against explicit twins.

## Multiple and nested Base parameter workers (codegen 188)

Checked field types and unaffected parameter evidence now survive private
worker expansion. This removes remaining boxes at helpers with multiple
arguments, nested products, closed records and tuple trees. Constructor
substitution is capture-safe; cache identities include finite latent declaration
graphs. Original entries retain each nominal guard and fallback, including a
valid outer constructor containing an invalid inner actor payload.

At 1,000 iterations, multiple/nested wrapper and nested-record helpers drop
from **1,000 to zero** allocations; nested tuples drop from **2,000 to zero**;
two nested arguments and four separate arguments drop from **3,000 to zero**.
Generic list helpers retain only their two payload cells. The existing
four-round policy deliberately leaves a five-level wrapper at **1,000**, down
from **4,000**. Both compiler versions pass 91 allocation/semantic rows, with
exact effects, traps and successful integer endpoints across rollback modes.

See the [contract and qualification](2026-11-05-BASE-PRODUCT-TREES.md).
Base fields and public entries remain tagged; this is private-call allocation
removal, not a new raw storage or general arena contract.

At 20 million calls with two nested arguments, allocations fall from
**60,029,283 to zero**. Native medians are **222.34 → 193.12 ms**, versus
**193.00 ms** for the explicit helper: **13/13** paired wins and **13.14%**
less elapsed time. The 117-configuration scheduling matrix passes with
89,856 plain responses and a sampled maximum of 324 us; this is not a
physical time bound. All 41 Haskell suites pass. Unchanged compiler budgets
pass at **1.60/32.76/67.42 GB** allocated. A separate progress-report retention
fix reduces std-live peak memory from approximately **505 to 353 MB**.

## Finite Base parameter expansion (codegen 191)

The field-worker pass now uses decreasing structural projection-path rank and
finite forwarding closure instead of four expansion rounds, three forwarding
rounds, 128 helpers and fixed Core-body cutoffs. Explicit parent/worker lineage
permits combining uniquely referenced private guards during each round, while
preserving conditional entry-fuel ticks and the original tagged fallback.
The physical 64-argument limit and semantic admission checks remain.

Five through sixteen nested wrappers, eight through sixty-four independent
arguments, 129 helpers, eight-result helpers and bodies above both old size
cutoffs now match their explicit controls at **zero wrapper allocations**.
At twenty million sixteen-argument calls, allocations fall from
**240,116,960 to zero**, and native median time falls **600.60 → 267.81 ms**,
versus **268.03 ms** explicit, with **13/13** paired wins.

All 41 Haskell suites and the unchanged absolute compiler-cost gates pass.
There is a remaining high-arity compiler hotspot: 64-argument compilation
uses **6.82 GB / 16.04 s**, versus the saved compiler's **3.67 GB / 3.10 s**,
although root machine code shrinks **69,788 → 26,184 bytes**. Full helper
coverage grows linearly, with one tagged entry and one private worker each.

All logical scheduling checks pass across **153 configurations**. Host timing
records four copy-workload responses over 1 ms, peaking at **7.97 ms**. A
focused saved/current comparison also records twelve current-compiler
responses over 1 ms (maximum **11.78 ms**) versus none for the saved compiler,
despite equal medians. These observations keep latency qualification open;
they are not erased by the successful correctness checks.
Fresh copy-workload binaries differ only in module-loader compiler identity
checks and metadata, so a code-generation cause is not established.

See the [finite-expansion contract, costs and evidence](2026-11-05-FINITE-BASE-FIELD-WORKERS.md).

## Field-worker compiler-cost refinement (codegen 191)

Constructor-argument preparation now rejects scalar right-hand sides before
scanning their continuations for capture and use. This reorders existing pure
admission tests; it does not relax them or move runtime effects. All eleven
finite-expansion fixtures retain exactly the same emitted RV64 assembly and
diagnostics. The measured 64-argument compile time falls **16.36 → 1.88 s**,
while allocation stays approximately **6.81 GB**. Compiler memory scaling
remains a separate cost; the explicit payload control uses 1.70 GB.

Both focused Haskell suites, all 77 native allocation/semantic rows and the
unchanged absolute compiler budgets pass. See the
[refinement and evidence](2026-11-05-FIELD-SHAPE-PREFILTER.md). This is compiler
efficiency supporting the existing allocation-removal milestone, not a new
runtime-throughput claim.

## Remaining C2 boundary

Closed checked instantiations have stable type-derived identities, and complete
parametric aggregate field graphs now have checked authority. Generic entries
have a real tagged contract and conversion path, including hidden-field nominal
types. Open record rows now have a tagged boundary for the compiled nominal
shape catalog; arbitrary foreign record schemas remain outside that contract.
Deterministic scalar-wrapper storage and checked local aggregate-expression
evidence are implemented. Checked builtin products, including owned-reference
fields, one-field owned wrappers and eligible acyclic nesting, now use the
private register ABI. Broader Base aggregate storage and the remaining agreed
scalar-variant cases remain **unfinished**. Recursive and mixed types staying
boxed is the explicit policy in proposal Decision 3; universal recursive
unboxing is not an additional completion requirement.

The checked Base parameter milestone establishes a guarded immediate-shape
consumer under its ownership, cache and module contracts. Multiple and nested
private parameter plans now carry checked evidence through structurally finite
expansion, with no fixed round count. Broader Base storage remains a
representation gate; raw/interrupt scalar products now have an
allocation-free admission check. Keep the absolute and twin compile-cost gates.
High-arity compile time is now reduced without changing output, while its
allocation scaling remains recorded. The measured copy-workload outliers remain
unexplained; host sampling alone does not close scheduling qualification.
Broader Base aggregates, scheduling time bounds
and general-application static arenas remain open; none follows automatically
from more builtin clones. Controlled single-activation arenas and the selected
zero-allocation computational loops are implemented as described above.

## Private unary Base return milestone (codegen 193)

[Unary return workers](2026-11-05-UNARY-BASE-RETURNS.md) remove an eligible
one-field result wrapper while retaining the ordinary tagged payload ABI and
public constructor entry. Strict producer prefixes preserve effects and lexical
scope. Heap payloads survive allocation, region exits and actor transfer.
All 19 qualification groups pass, including 41 Haskell suites, native arm64
and x86-64 execution, independent RV64/x86-64 return oracles and controlled
static-arena regressions.

At twenty million calls allocation requests fall **20,009,766 → 0** and
median host runtime **87.49 → 70.96 ms**, with **12/13 paired wins**. The
171-configuration host scheduler matrix retains 50 replies above its
observational 1 ms threshold. Detailed costs, outliers and evidence hashes are
linked from the milestone. The return pass's existing 1,024-node admission cap
and broader result/storage representation work remain open; this milestone
does not complete C2 or physical QOS/static-arena qualification.

## Physical Pi 4B qualification (codegen 193)

The [physical report](2026-11-05-PI-QOS-PHYSICAL-QUALIFICATION.md) covers 171
configurations on the selected QOS Pi. All 702 executions passed their value,
progress, lifetime or watchdog checks. At 600 MHz, 24,638 of 131,328 measured
replies exceeded 1 ms. The median was 204 µs and the maximum was 24.561 ms.
All 6,912 large-copy replies crossed 1 ms. A physical timing contract needs a
bounded copy workload or a mechanism to bound work between yields. The matched
QOS Main and editor SDK were staged and exercised beside the installed service.
The Main allocator probe completed 16 and 17 UI cycles on one and four workers.
Both reported 38,400–38,592 KiB of post-warmup reserved storage with 17–19
ARC roots. The three Main runs all passed normal and signal shutdown. The
installed service reported zero restarts after qualification.

## Hosted worker admission (codegens 194–195)

[Finite hosted worker admission](2026-11-05-HOSTED-WORKER-ADMISSION.md)
removes the return and scalar body-size cutoffs and the scalar worker count
and total-node cutoffs. Recursive groups qualify together and import proved
callee signatures. A group that used to lose all 131 workers now retains all
131. A large constructor return removes 500,245 allocations at 500,000 calls.
Its elapsed-time gain was inconsistent. Solving scalar kinds once per group
reduced compiler allocation from 3.408 to 2.993 GB at 256 functions with
identical generated machine code. The unchanged absolute cost gates and all
41 Haskell suites passed. The host latency matrix now includes both large
shapes and passes 207 configurations. Physical results remain pinned to the
codegen-193 Pi bundle.

General Base aggregate storage, eligible scalar variants, and static-arena
admission for broader applications remain open. At this milestone scalar helper arguments retained their historical eight-argument limit. The codegen-196 milestone below qualifies the existing argument spill cells.

## Full native scalar argument frame (codegen 196)

[Wide scalar workers](2026-11-05-WIDE-SCALAR-WORKERS.md) use the backend's
64-word argument limit. A 63-field tuple plus loop counter now qualifies for
both field expansion and raw scalar arguments. Its million-iteration median
fell **35.36 → 26.20 ms**, close to the explicit argument loop at **26.71 ms**.
All forms already allocate zero. The added private code increased root RV64
text **33,584 → 53,312 bytes**. ARM64, x86-64 and RV64 execution cover spill
placement, real or deliberately hostile fuel resets, and exact answers. Tagged
module boundaries and dynamic fallbacks pass. The host scheduling matrix
covers 225 configurations. General Base storage and broader application
static-arena admission remain open.

The next measured Base gap is nested constructor returns. At 1,000 calls,
`Cell (Cell n)` still allocates **1,000 inner wrappers**. Returning two pairs
inside an outer pair still allocates **2,000 inner pairs**, while the equivalent
explicit four-field result allocates **zero**. Both ordinary and disabled
inlining reproduce these counts, with independent expected output. The
[baseline record](../bench/2026-11-05-nested-base-results-before.json) includes
every input program and its rollback measurements. A nested result worker must
preserve the tagged path when an inner value escapes, field evaluation and
failure order, payload ownership, and the backend result-width limit.

## Nested Base result packets and finite application arenas (codegen 197)

[Nested result workers](2026-11-05-NESTED-BASE-RETURNS.md) eliminate the
inner allocations measured at the previous checkpoint. At five million calls,
the one-, four- and eight-word nested results all allocate zero. Nested pairs
fall from 38.94 to 31.03 ms, and the eight-word case matches the explicit
flat result at about 47.8 ms. Tagged escape and module boundaries remain
available. The host scheduling matrix covers 243 configurations.

[Static application sequences](2026-11-05-STATIC-APPLICATION-SEQUENCES.md)
now compose distinct checked RV64 entries using one fixed heap. A sequence
of 257 activations fits 624 bytes of heap and 432 bytes of linked stack,
including its dispatcher. Scalar-only hand-offs, zero-live checks and fresh
heap geometry are explicit conditions. Its QEMU receipt and physical Pi QOS
measurements cover different runtimes.

At codegen 197, `specializeSelection` selected typed monomorphization for ARC while
Base used `compileSelection`. An internal retained-entry API exists, but Base
needs an admission rule tied to a representation change. A polymorphic
recursive helper forwarding a wrapper or pair still takes **2,000 allocations
per 1,000 iterations** for the two calls combined. The explicit scalar/flat
source takes **zero**. Both inlining modes and one/four workers reproduce the
gap. Toggling `FPR_NO_TYPE_SPEC` made no difference in the codegen 197 Base
program. [Exact sources and measurements](../bench/2026-11-05-base-instance-forwarding-before.json)

The codegen-197 physical Pi run passed 1,198 runtime cases, 243 scheduling
configurations and six isolated QOS Main boots. In the nested workload the
observed p99 fell from 3.011 to 1.943 ms. The large copy remained above 1 ms
throughout. Post-warmup Main allocator reservations spanned 192 KiB on both
one and four workers. [Physical results](../bench/2026-11-05-pi-qos-197.json)


## Hosted Base forwarding and physical qualification (codegen 198)

Hosted Base now specializes a proven recursive forwarding helper when the
caller supplies and immediately reads a known aggregate. The wrapper/pair
fixture went from 2,000 allocations to zero. At one million iterations the
median fell from 18.38 ms to 15.76 ms, compared with 16.11 ms for explicit
loops. Tagged module boundaries, trap order, all three hosted 64-bit
backends and the absolute compiler budgets passed their checks.

On the selected QOS Pi 4B, two toolchains each passed 130 cases. The
optimized scheduling workload had lower sampled p99 with both. The next
measured gap is a native scalar variant with two possible constructors:
1,000 allocations versus zero for the explicit tag and payload.

[Implementation, measurements, Pi qualification and remaining scope](2026-11-05-BASE-POLYMORPHIC-TRANSPORT.md)

## Scalar variant returns in hosted Base (codegen 199)

A private native result can now carry one of several named scalar constructors
in up to eight words, including its tag. The recorded two-variant workload
fell from 1,000 allocations to zero and matched the explicit representation.
Five million calls took 33.38 ms versus 37.15 ms previously and 33.03 ms for
the explicit loop. Private code added 488 bytes of root RV64 text. An active
call region still promotes all runtime values together before reclamation.

The Pi 4B running QOS passed 218 cases in the final run. Median reply latency
fell, while p99 moved in opposite directions across two runs. The desktop
retained its PID and zero-restart state. General response bounds and concurrent
static-arena lifetimes remain open.

The next confirmed C2 storage gap is a shared list of 1,000 scalar wrappers
or variants read twice. Both use 2,000 allocations and 64,000 bytes, versus
1,000 allocations and 32,000 bytes with explicit storage.

[Implementation, differential checks, measurements and physical evidence](2026-11-05-BASE-SCALAR-VARIANT-RETURNS.md)

## Persistent scalar list storage (codegens 200–201)

Shared lists of 1,000 scalar wrappers or variants now match explicit storage
at 1,000 allocations and 32,000 bytes. Physical Pi 4B qualification passed
210 cases alongside QOS. Observed p99 was 1.679 ms versus 2.354 ms with
rollback, with identical 191 µs medians. Host timing gains varied by sample,
and emitted code grew. The existing RV64 static-arena admission contract
passed requalification after the RISC-V selector change.

The next measured gap is a shared 1,023-node binary tree with a scalar
variant field. It uses 2,046 allocations versus 1,023 in the explicit tree.
General scheduler response bounds and concurrent arena lifetimes remain open.

[Admission, paired measurements, device evidence and remaining scope](2026-11-05-BASE-PERSISTENT-LIST-STORAGE.md)

## Scalar fields in persistent Base aggregates (codegen 202)

The 1,023-node tree now matches explicit storage at 1,023 allocations and
49,104 bytes. Host and emulator checks covered shared children, effect and
trap order, managed values across region closes, and tagged public entries.
In two physical Pi 4B runs, private tree storage improved the observed p99.
The expanded run passed 218 cases alongside the QOS desktop.

The imported AVL Map is the next measured storage boundary: wrapping 512
integer values still costs 512 allocations and 16,384 additional bytes. Code
growth and compiler cost are material limits on extending specialization.

[Admission, benchmarks, Pi evidence and standard-library Map baseline](2026-11-05-BASE-AGGREGATE-FIELD-STORAGE.md)

## Scalar wrappers transported by imported containers (codegen 203)

A local scalar wrapper stored through the imported AVL Map now matches plain
integer storage. For 512 keys the change removes 512 allocations and 16,384
bytes. The separate unit's checked bodies must prove that the value is carried
without observation, including through recursive helpers. Public cost contracts
cover the tagged execution. Repeated elapsed times were close, and root code
grew by 1,276 bytes.

The final Pi 4B run passed 158 cases alongside QOS. Observed p99 improved
slightly while the count over 1 ms increased. Two independently hosted
backends, RV64 userspace and both previously admitted static-arena modes passed.
An imported wrapper constructor or pack/read API still costs one allocation
per inserted value. General response-time and overlapping-lifetime admission
remain open.

[Proof, boundaries, cost and Pi measurements](2026-11-05-BASE-PARAMETRIC-CONTAINERS.md)

## Imported wrapper adapters and linked callback work (codegen 204)

Storing an imported wrapper in the AVL Map now matches explicit integers
whether the source calls its constructor or its pack/read API. For 512
keys both spellings remove 512 allocations and 16,384 bytes. Two 166-case
Pi 4B runs passed; median and p99 were lower in both, while the maximum
moved in opposite directions. [Compiler, size and physical evidence](2026-11-05-IMPORTED-SCALAR-ADAPTERS.md)

Controlled RV64 static arenas can now enforce an instruction budget summed
over the actual callback schedule, including matched calls and returns.
Four callbacks admitted at 120 instructions executed 117 under QEMU; a
119-instruction budget preserved the prior image on refusal. The current
proof rejects cyclic control and stores beyond proven stack frames.
[Scope and executable checks](2026-11-05-STATIC-APPLICATION-SEQUENCES.md#linked-callback-instruction-budget)

On the Pi, the actual pack adapter can enter stack growth before it checks
fuel. Stack-growth and runtime-call bounds, scheduler/OS response, and
overlapping application lifetimes remain independent obligations.
