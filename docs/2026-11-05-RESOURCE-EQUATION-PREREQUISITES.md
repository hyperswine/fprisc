# Resource equation prerequisites for arena admission

Codegen 175 closes several undercount paths in the existing source resource
equations. This is correctness work needed before physical arena admission,
not a new abstraction-removal optimization or an arena implementation.

## Reproduced undercounts

The [native comparison](../bench/2026-11-05-resource-equations.json) builds
the same fixtures with the previous codegen-174 compiler and the revised
compiler. All three undersized source contracts were accepted previously;
the revised compiler refuses them. Successful executions without those
contracts preserve their results on one/four harts.

| Case | Previously accepted requested-byte bound | Required requested bytes | Instrumented object-block bytes |
| --- | ---: | ---: | ---: |
| Binary tree at depth 5 | 144 | 744 | 992 |
| Three-argument function applied to one argument | 24 | 56 | 64 |
| String doubled five times from one byte | 108 | 142 | 208 |

An independent C walker observes the tree's 31 internal nodes and their
runtime layout. A C observer reads the closure's actual arity and supplied
argument count and calculates its capacity using `sizeof(pap_t)` and
`sizeof(V)`. The string's requested total follows from the five output
lengths 2, 4, 8, 16 and 32, plus five 16-byte string headers; native counters
independently observe five allocations and 208 object-block bytes.

The counters use compact Base cells, with loop/call regions disabled to
isolate these objects. Object-block bytes include their managed prefix and
rounding, but **not** complete slab, pool, stack, runtime or image storage.
They must not be used as a whole-program arena certificate.

## What changed

A verified termination measure bounds recursive depth. The existing
`(measure / step + 1) * body` equation now requires at most one saturated
recursive-group call on every evaluation path. Strict sequences, constructor
arguments and conditions add call counts; mutually exclusive branches take
their maximum. Escaped or partially applied recursive entries cannot supply
a call-count proof. Branching recursion remains legal, but its total resource
cost is opaque until a call-tree recurrence is proved. An independently
allocation-free recursive group can retain its zero requested-allocation fact.

A per-call cost can depend on a parameter only when that parameter is
forwarded unchanged on every recursive edge. Lexical aliases preserve this
evidence. Growing strings, lists or callbacks cannot borrow their initial
cost throughout the recursion. More general monotonic/accumulator recurrences
need an additional proof; the compiler does not infer one from termination.

Partial application now charges the complete runtime closure capacity:
32 bytes of header/function/arity/count fields plus eight bytes for each
argument slot in this existing 64-bit requested-byte model. The number of
already supplied arguments does not determine capacity. Unknown returned
callables in over-application and unlifted lambdas remain opaque. Parameter
and local shadows cannot inherit a global or primitive's resource contract.

These equations also guide region placement, so the native cache revision
advances to 175. This does not change the runtime's value or ownership ABI.

## Existing proof fixtures

The old `tests/cases/bound_pipeline.fpr` is retained as an expected refusal.
Its std-map equation priced the growing accumulator used by the final reverse
at the accumulator's initial length. Rejecting that proof does not reject
ordinary map execution, and does not claim that a linear bound for map is
impossible. It identifies a missing recurrence proof.

`bound_pipeline_direct.fpr` separately exercises a measured direct map,
invariant callback costs, result-size substitution, a fold consumer and the
manifest's under/over-budget diagnostics. Its derived work is
`16 * (len xs + 1) + 6`. The earlier std-map source remains in the test, so
the missing proof is not hidden by replacing it with an easier positive case.
Lifted closure expectations in the scoped-arena fixture now include their
full reserved capacity. Todo's report keeps both the measured outer loop and
the explicit unknown cost of changing reverse accumulators.

## Validation and limits

The focused resource checks run inside the existing `TypedProgram` Haskell
suite. They cover branching and mutually recursive groups, exclusive branches,
calls in arguments/conditions, escaped aliases, growing versus invariant
payloads, callback aliases, partial/over-application and lexical shadows.
The native suite is registered in Base and host-extra CI.

All 39 Haskell suites passed. Native request/capacity observations and refusal
checks passed on one/four harts. The ordinary region nesting, received-root
lifetime and persistent `loopWith` tests passed. Wrapper allocation/failure
checks and materializing-pipeline allocation/effect/endpoint regressions also
passed. The source cost-report suite retains both positive and refused proofs.

The unchanged compiler budget passes at **1.59/32.66/68.92 GB** for
hello/std-live/pos1. The
[16–256-helper C2 comparison](../bench/2026-11-05-resource-equation-specialization-cost.json)
retains exact code/function parity and 1.001–1.002x compiler allocations
against explicit twins. Cost-gate runs overlapped other validation; their
wall times are not throughput measurements. The
[validation manifest](../bench/2026-11-05-resource-equation-validation.json)
records source/compiler identities and completed checks.

This is not a claim that the entire historical cost model can now authorize
physical arenas. Remaining requirements include:

- Prove useful branching and changing-accumulator recurrences, including the
  standard map/reverse construction, instead of leaving them opaque.
- The implicit nonnegative-input assumption was subsequently corrected in
  [codegen 176](2026-11-05-SIGNED-RESOURCE-DOMAINS.md): signed inputs require
  explicit clamps or enforced value predicates. Admission must retain those
  domains and their boundary checks.
- [Codegen 177](2026-11-05-VERIFIED-RESULT-SIZES.md) subsequently verifies
  supported result-size lemmas before composition. Unsupported annotations
  remain unused; richer nested-container and callback invariants are open.
- Account for the final lowered representation and all allocation sites,
  conversion graphs, descriptors, scratch storage, prefixes and rounding.
- Derive peak-live storage and native stack bounds, then enforce a static
  arena capacity and bind the admission result to the exact image/target.
- Supply the runtime/scheduling/time contracts and physical-target execution
  needed for any hardware WCET claim.
