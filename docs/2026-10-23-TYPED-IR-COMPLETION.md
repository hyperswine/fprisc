# Complete typed IR and native codegen migration

The goal is to use the typed IR and native selectors for every supported
native profile and remove the previous RISC-V text generator, its
translation/lowering passes, peephole optimizer and legacy-only modes.
A64.hs and X64.hs are already deleted. The remaining scalar/kernel generator and translation adapters are now removed;
all supported native profiles use typed lowering and selection.

Work continues in `fprisc-typed-ir-next`, branch `typed-ir-retire`, from
`98abc0c`. The final acceptance record is
[typed generator retirement](2026-10-23-TYPED-GENERATOR-RETIREMENT.md).
Profiles retain their allocation, stack, root and ownership contracts.

## Milestones

| Work | Current state | Acceptance |
|---|---|---|
| A64/x64 translators | Retired | Already landed after their recorded sweeps |
| Hosted scalar and kernel lowering | Default, including loaded QOS apps, RV64 modules and ESP-IDF hart access | Keep strict coverage and independent execution checks green; complete real platform acceptance |
| Float trees and FP allocation | F64/F32 arithmetic/comparison trees on A64/x64/RV64; hosted A64 pool across safepoints | 112 Base jobs and paired measurements recorded; extend pools only with target context contracts |
| Captured SIMD maps | Implemented: [matching Int/F64 captures on A64](2026-10-23-CAPTURED-SIMD.md), 113 Base jobs passed | Independent C, scalar parity, tails, overflow, hostile yields, real actor runtime, paired measurements |
| Fused SIMD pipelines and x64 pairs | [x64 SSE2 pairs implemented](2026-10-23-SSE2-PAIRS.md), 113 Base jobs passed; fused pipelines open | Stable filtering, source-order failures, fuel bounds, scalar tails; native A64 and x64 execution oracles |
| Filter compaction | [Bounded prefix implemented](2026-10-23-TYPED-RECORD-COMPACTION.md): cached bases and counted strips; dynamic tail unchanged | A discard-heavy benchmark, fewer directory/base loads, stable rows and all columns preserved, paired measurements |
| Native instruction accounting | [Consumer migrated](2026-10-23-NATIVE-METRIC-CONSUMER.md): complete native closure audit, instruction/call-site ceilings; 116 Base jobs and focused QOS gates passed | QOS uses `native-insns-v1`; absent/unbounded coverage fails; runtime time and call/return composition remain explicitly unprovided |
| Builtin manual/GC profiles, RV32/RV64 | [Implemented](2026-10-23-TYPED-BUILTIN.md), 114 Base jobs, QEMU and physical Tang Nano checks passed | Explicit allocator, root, raw-word and no-fuel policies; full function/data/kernel coverage; QEMU and supported board suites |
| Builtin ARC, RV64 | [Implemented](2026-10-23-TYPED-ARC.md), 115 Base jobs, strict QEMU execution and 31 paired measurements passed | Preserve consuming/borrowing adapters, alias-result retains, object layout and section/link behavior; QEMU-virt ownership/raw/interrupt/export gates and paired guest work |
| RV32 Base numeric constants | [Implemented](2026-10-23-TYPED-RV32-FLOAT-CONSTANTS.md), 117 Base jobs, strict QEMU and physical Tang Nano bit/numeric suites passed | Preserve boxed F64/F32 layouts and all IEEE bits, pooling, software/vector runtime behavior and integer boundaries |
| Plain RV plugins and RVV startup | [Implemented](2026-10-23-TYPED-RV-STARTUP.md): typed routing and native COMDAT startup, RV32/RV64 QEMU oracles; 118 Base jobs passed | Strict closure/data, exported PAP/args, VLEN 128/256/512, hostile yields, scalar overflow fallback and the full Base sweep |
| Oversized generated frames | [All three backends implemented](evidence/2026-10-23-native-sized-frames-final/README.md), 123 Base jobs passed; RISC-V also has QOS relocated-process and physical fixed-stack gates | Complete-frame reservation before writes, exact return/tail SP, all 64 arguments, hostile calls, actor ceilings, plane ABI; Linux x64 and native Linux A64 production-runtime execution also pass locally |
| Final legacy deletion | [Implemented and locally accepted](2026-10-23-TYPED-GENERATOR-RETIREMENT.md): 123 Base jobs, QOS 155 pass / 0 fail / 7 registered skips, both supplemental WebSocket suites pass | No production caller of legacy generation, relocation/lowering, peephole or modes; full fresh acceptance sweeps and clean build/install checks |

## Order of implementation

1. Captured NEON maps and x64 SSE2 pairs are implemented. Add fused
   map/filter SIMD with separate proofs for checked integer operations and stable
   compaction. SIMD improvements are bounded increments; they must not
   delay the ownership/profile migration indefinitely.
2. Finish the filter-compaction pass using a workload that actually moves
   rows. Keep the dynamic-width loop fuel-bounded.
3. QOS's instruction ratchet now uses the selected/native metric. Keep its
   closure and failure controls green. Remove obsolete annotation/reporting
   code with the last legacy generator users. Runtime time and interprocedural
   composition still require separate proofs before any latency certificate.
4. Manual/GC RV32 and RV64 profiles and builtin RV64 ARC/raw now have
   explicit fixed-stack/no-fuel contracts. Preserve their ownership, root,
   layout, interrupt and export gates while removing legacy production paths.
5. Inventory and remove remaining legacy production entry points and
   their tests' obsolete text assertions. Keep equivalent behavioral
   tests. Delete the generator and peephole only when the inventory is
   empty, then run the final sweeps.

## Completion gates

- Every supported target/profile has an explicit typed policy and strict
  coverage of functions, kernels, static objects and module tables.
- Allocation, calls, tail transfers, stack growth, roots and ownership
  match each profile's runtime contract. No unsafe hosted assumptions
  enter bare-metal or ARC code.
- Fresh Base and QOS sweeps pass. Linux x64/RV64, module loading, QEMU,
  P4 and other supported board results are reported at their actual scope.
  An emission oracle is not a physical-board result.
- Paired measurements accompany performance changes; default promotion
  uses the acceptance evidence appropriate to that platform.
- No import or reachable production path remains for the legacy generator,
  translator/lowering adapters, peephole optimizer, old bound reporting
  or retired environment modes. Packaging, bootstrap and cache identities
  use only the replacement code.

The migration implementation and local acceptance are complete. The remaining
fused SIMD, additional FP pools and dynamic-width compaction are performance
follow-ups. No physical P4 or unexecuted platform gate is claimed.


## Profile work located in the current source

The [manual/GC profile increment](2026-10-23-TYPED-BUILTIN.md) replaces
hosted entry assumptions with `StackStatic` and no actor fuel on RV32/RV64.
Generated roots have QEMU negative controls and physical Tang Nano results.

The [ARC/raw increment](2026-10-23-TYPED-ARC.md) selects
`fpr_builtin_alloc_adt(bytes, fields)` for typed ARC constructors, preserves
the field metadata and consuming adapters in `machine/builtin/arc.c`, and
keeps separate function/object sections for linking. Imported representations
are still analyzed together. The aggregate ARC gate runs raw/interrupt,
layout and export checks, plus independent arithmetic and metadata controls.

Conservative GC is single-threaded and nonmoving. Its port captures all
registers before root scanning (`machine/builtin/builtin.h`); stack and
register roots, interior pointers, and allocator-private metadata have
explicit scanning rules. The generated-frame and call tests now validate those rules; a hosted
stack map or ownership assumption does not replace them.

Builtin loops without actor fuel now retain honest `UNBOUNDED` native
reports; hosted admission still requires bounded preemption segments.
ARC/interrupt selection preserves that distinction and the existing
interrupt restrictions. Final legacy removal must keep these gates.

The production-caller audit found RV32 float literal payloads being treated
as tagged Ints. The [typed constant increment](2026-10-23-TYPED-RV32-FLOAT-CONSTANTS.md)
replaces that fallback with explicit immutable boxed numeric leaves and native
data emission. Its 128-pattern bit/layout/pooling oracle and complete numeric
suite pass on the physical Tang Nano as well as QEMU.

Plain RISC-V plugins and RVV startup now have native owners and independent
execution gates. The remaining production-caller audit must include oversized
hosted frames and typed-kernel selection refusals, as well as explicit legacy
modes. The old RVV map template is already disabled by its checked-overflow
gate; it is dormant deletion material, not a missing supported native shape.
The RISC-V selector now reserves complete large frames through the versioned
runtime contract; A64 and x64 now have matching implementations, validated by
the combined 123-job sweep at their recorded platform scope. Codegen 87 passed its complete native-required sweep. Codegen 89 removes the
old scalar and kernel renderers, host translation passes and peephole path;
static data has an independent native owner. Its fresh Base and QOS sweeps pass at their documented scope, together with
Linux runtime, packaging, WebSocket and physical Tang acceptance. Dependency
skips and the unavailable P4 are explicit in the final evidence record.

QOS's `check-all.sh` now invokes `tools/native-insns-ratchet.py` on
`programs/system.fpr` with independent ceilings of 312 native instructions
per function segment and 67 runtime call sites per function. The old script
is deleted. Codegen 89 removes legacy annotations and rollback modes. Its summary switch
is `FPRC_NATIVE_INSNS=1`; no runtime timing or composition proof is implied.
