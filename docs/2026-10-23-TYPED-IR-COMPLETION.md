# Complete typed IR and native codegen migration

The goal is to use the typed IR and native selectors for every supported
native profile and remove the previous RISC-V text generator, its
translation/lowering passes, peephole optimizer and legacy-only modes.
A64.hs and X64.hs are already deleted. Retiring those translators is an
achieved milestone; completing all profiles is the remaining goal.

Work continues in `fprisc-typed-ir-next`, branch `typed-ir-retire`, from
`98abc0c`. Existing compatibility paths remain until their replacement's
correctness and platform gates pass. Removing a profile or silently
switching its ownership model does not count as migration.

## Milestones

| Work | Current state | Acceptance |
|---|---|---|
| A64/x64 translators | Retired | Already landed after their recorded sweeps |
| Hosted scalar and kernel lowering | Default, including loaded QOS apps, RV64 modules and ESP-IDF hart access | Keep strict coverage and independent execution checks green; complete real platform acceptance |
| Float trees and FP allocation | F64/F32 arithmetic/comparison trees on A64/x64/RV64; hosted A64 pool across safepoints | 112 Base jobs and paired measurements recorded; extend pools only with target context contracts |
| Captured SIMD maps | Implemented: [matching Int/F64 captures on A64](2026-10-23-CAPTURED-SIMD.md), 113 Base jobs passed | Independent C, scalar parity, tails, overflow, hostile yields, real actor runtime, paired measurements |
| Fused SIMD pipelines and x64 pairs | [x64 SSE2 pairs implemented](2026-10-23-SSE2-PAIRS.md), 113 Base jobs passed; fused pipelines open | Stable filtering, source-order failures, fuel bounds, scalar tails; native A64 and x64 execution oracles |
| Filter compaction | Open | A discard-heavy benchmark, fewer directory/base loads, stable rows and all columns preserved, paired measurements |
| Native instruction accounting | Open | QOS ratchet/admission consumers use `native-insns-v1`; refuse absent or unbounded coverage; document runtime-call costs separately |
| Builtin manual/GC profiles, RV32/RV64 | Open | Explicit allocator, root, raw-word and no-fuel policies; full function/data/kernel coverage; QEMU and supported board suites |
| Builtin ARC, RV64 | Open | Preserve consuming/borrowing adapters, alias-result retains, object layout and section/link behavior; ownership and hardware oracles |
| Final legacy deletion | Open | No production caller of legacy generation, relocation/lowering, peephole or modes; full fresh acceptance sweeps and clean build/install checks |

## Order of implementation

1. Captured NEON maps and x64 SSE2 pairs are implemented. Add fused
   map/filter SIMD with separate proofs for checked integer operations and stable
   compaction. SIMD improvements are bounded increments; they must not
   delay the ownership/profile migration indefinitely.
2. Finish the filter-compaction pass using a workload that actually moves
   rows. Keep the dynamic-width loop fuel-bounded.
3. Move QOS's legacy instruction ratchet to the selected/native metric.
   Instruction counts are not a hardware-time WCET certificate. Preserve
   explicit treatment of unknown runtime-call costs and unbounded paths.
4. Admit builtin profiles individually. Begin with manual RV64, then
   conservative GC/root preservation, RV32 legalization and ARC. Review
   the actual runtime contracts before reusing hosted lowering.
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

This page records the goal and its acceptance conditions; it does not claim
that the open milestones or unavailable platform gates have passed.


## Profile work located in the current source

Builtin admission is more than removing the policy refusal. In the current
source, `Codegen.Lower` always inserts `OStackCheck`, and the RV selector
requires hosted stack/fuel obligations at entry. Builtin has a static stack
and no actor fuel; its explicit policy must remove those dependencies rather
than linking dummy hosted runtime entries.

ARC constructor allocation currently calls `fpr_builtin_alloc_adt(bytes,
fields)` in the legacy generator; the typed RV `OMake` uses `fpr_alloc`.
The field metadata and consuming adapters in `machine/builtin/arc.c` must
be preserved. ARC also analyzes imported representations together and uses
separate function/object sections for linking. The raw/interrupt checks in
`tests/check_raw.py` provide executable acceptance cases for those contracts.

Conservative GC is single-threaded and nonmoving. Its port captures all
registers before root scanning (`machine/builtin/builtin.h`); stack and
register roots, interior pointers, and allocator-private metadata have
explicit scanning rules. Verify those rules against allocated native frames
and calls before admitting the GC profile. A hosted stack map or ownership
assumption cannot replace them.

Builtin loops without actor fuel also need an honest interpretation of
native bounds. A hosted preemption bound cannot be fabricated by inserting
synthetic ticks into a no-fuel profile. Preserve the existing interrupt
contract and report unknown/unbounded native segments explicitly under the
appropriate profile policy.
