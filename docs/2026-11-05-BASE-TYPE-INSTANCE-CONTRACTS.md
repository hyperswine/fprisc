# Checked type instances across native units

Codegen 173 adds the checked ownership and declaration foundation for privately
instantiating functions in separately emitted units. This is preparation for
Base representation lowering. **Base does not enable eager type cloning by
default**, and this milestone does not claim a new Base allocation reduction.

## Admission and fallback

The retained-entry API keeps every original source entry and physical arity.
Its caller supplies an admission predicate over the complete checked function
type. An unselected call keeps its original generic entry. Selected instances
retain the existing source-name plus complete-type identity and the finite
instance-graph termination check. Admission does not replace target image or
compiler-cost gates, and introduces no new node or clone-count limit.

This distinction matters: ordinary scalar calls already use Base's existing
value convention, so copying every generic scalar helper need not remove any
representation cost. A future Base consumer must connect its admission policy
to actual checked layout lowering, ownership boundaries and scheduling rules.
The existing builtin representation implementation remains separate.

## Private declarations and verified descent

The compiler records each instance's source origin, checked scheme and physical
arity directly from the transformation. Names are not parsed to recover proof.
Callback copying, inlining and fusion carry the shared declaration catalog;
private definitions still have one emitting home. The linker compares imported
schemes and arities with that home. A missing home remains an error even if no
remaining artifact defines a symbol with that spelling.

Native emission gives private instances the same hidden home visibility and
code/function-value import contracts as existing checked private code. It
rejects copied definitions, missing home definitions and changed arities.
Public source entries retain their original calling convention.

Type substitution preserves parameter positions and source descent. Region
costing can therefore inherit a verified source recursion measure through the
explicit origin map, only when the emitted parameter count still agrees.
The consumer explicitly prepares these measures for standalone or shared
post-link analysis. Without that preparation or a verified source measure,
recursive work stays unknown. Ordinary Base compilation retains its existing
cost-analysis input: eagerly preparing provenance there forced an otherwise
unused checked context and exceeded the compiler allocation budget even when
type cloning was disabled. Broad activation must account for this cost too.

## Rejected eager activation

An exploratory codegen 173 binary enabled retained-entry cloning for 64-bit
Base units, excluding plugins and QOS process images. Its SHA-256 was
`762688e6d19edd3c276580a25febe1015ea253a32419f81afeb20807206ca54a`.
The unchanged cold compilation budget rejected it:

| Program | Compiler allocation | Change from baseline | Gate |
| --- | ---: | ---: | --- |
| hello | 1.76 GB | +20.1% | Fail |
| std-live | 37.70 GB | +26.0% | Fail |
| pos1 | 80.62 GB | +24.4% | Fail |

All three exceed the existing +10% margin. These are compiler allocations,
not allocations in the generated program. The activation was removed; neither
the baselines nor the limits were raised. Retained-entry specialization remains
a checked internal API for developing a representation consumer.

## Validation

The [validation record](../bench/2026-11-05-type-instance-contracts.json)
identifies the final compiler and source hashes. All 39 Haskell suites passed,
including the new selective-admission, cross-unit callback, missing-home,
changed-arity, emission-ownership and verified-measure cases. The RV64 QEMU
specialization suite passed effects, overflow/division failures, generic
fallback, scalar-bit conversions and leak checks.

The unchanged compiler budget passes at **1.59/32.74/70.33 GB** allocated for
hello/std-live/pos1. The std-live case remains close to its ceiling at +9.4%.
The [16–256-helper C2 gate](../bench/2026-11-05-type-instance-specialization-cost.json)
retains exact assembled-size/function-count parity with explicit monomorphic
twins, at 1.001–1.002x compiler allocations. Both the absolute and twin limits
remain unchanged. Wall times are observations, not a throughput improvement
claim; independent validation ran alongside the cost checks.

## Qualification still required

Base canonical scalar-wrapper/product layouts must remove allocations against
explicit twins while preserving generic/module/region escapes and the existing
public ABI. They must also pass the unchanged compile-cost gates. Open rows,
owned-reference aggregates, scheduling response bounds, physical stack/live
memory and static-arena admission remain separate unfinished roadmap work.
