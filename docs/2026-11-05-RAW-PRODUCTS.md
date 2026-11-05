# Allocation-free products in raw units and interrupts

Codegen 172 / arcRev 20 extends checked scalar-product values to raw units and
interrupt helpers. Eligible products can stay in private registers through
calls, recursive tail transfers and joins. Admission now checks both the
represented source and the actual lowered call graph. This establishes an
allocation-free subset, not a timing or stack bound.

## Two-stage admission

The source check accepts a constructor or projection only when complete checked
product evidence identifies its nominal type, variant and immediate fields.
The existing exclusions still apply: heap containers, strings, allocation,
generic conversion edges and disallowed interrupt-control operations are not
made safe by containing an otherwise eligible product.

After lowering, `Interrupt.checkLoweredProducts` follows reachable functions:

- Every actual parameter list must fit the existing RV64 register-only limit
  of eight words. Five two-field parameters therefore fail even though the
  source declaration has only five arguments. This is checked after expansion.
- Every non-nullary heap constructor is refused. A boxed fallback acceptable in
  ordinary ARC code is not acceptable in raw or interrupt code.
- A projection must select a valid component of a statically known private
  result packet. Ordinary heap projection and boxed entry unpacking are refused.
- Ordered packet markers, branch joins, call arities and result conventions
  must agree. Unknown calls, conversion adapters and indirect application are
  refused. A static terminating panic remains admissible.
- The lowered primitive allowlist is derived from the source primitive
  contract. Handler retain/release operations remain admissible only after
  source checks establish raw, tagged-immediate or immortal values. Raw units
  still emit no ownership instrumentation.

The source and lowered checks are both required: private marker names alone
are not authority for type eligibility or non-allocation. Handler roots keep
the existing three-Word-to-Unit ABI and interrupt-control restrictions. Raw C
exports retain their existing scalar ABI; aggregate exports are refused rather
than silently acquiring a new C struct convention.

Raw root discovery now includes pinned/exported definitions even when their
body looks like a constructor stub. Uncalled compiler stubs may still be
present, but the check cannot exempt a callable export solely by its shape.
The source C-export/type checks also continue to reject unsupported boundaries.

`FPR_NO_PAIR_RETURNS=1` disables the product convention. Raw/interrupt source
that then needs a heap constructor is refused. `FPR_NO_TYPE_SPEC=1` independently
disables cloning; closed checked product definitions remain eligible.

## Execution probes

`python3 tests/check_raw_products.py` uses required strict native lowering and
RV64 QEMU. It does not skip execution when tools are absent.

The raw-library oracle links generated code with a minimal startup, static
panic and raw memory-write shims, and independent C reference calculations.
No allocator, retain/release implementation or ARC runtime is linked; the
linked symbol table is inspected as well. It tests eight-word recursion and
joins, high Word bits, mixed scalar fields, F64/F32 NaN payloads and signed
zero, and memory writes with neighbor canaries. Both soft/hard C float ABIs
and specialization rollback are covered, with 256 input cycles per build.
This is an independent boundary harness, not the production runtime.

The interrupt probe uses the production builtin runtime with ARC checks and
both allocator implementations. Eight-word constructor and consumer helpers
execute inside real CLINT software interrupts. The existing assembly probe
seeds all GPRs/FPRs and fcsr and deliberately clobbers them in the handler
wrapper before checking restored state. A C guard intercepts allocator requests
and checks live allocations around every handler invocation. The main wrapper
requires exactly 1,001 delivered and resumed interrupts, including the initial
register-state probe, with and without type specialization.

Separate production-runtime fault programs use an unused second product field
to trigger both Int overflow endpoints, division by zero, an invalid shift and
an unaligned memory read. The panic guard requires an accumulated memory trace
of `0x12`, establishing that the first and second writes occurred in order before
failure, and checks the original diagnostic and failing exit status. These are
run with specialization enabled and disabled.

Negative cases require refusal before assembly output for expanded arguments,
boxed exports, incompatible generic representations, heap storage and product
rollback. Haskell tests independently challenge the lowered checker with heap
construction, arbitrary projection, a conversion adapter and a heap effect
inside a packet.

## Verified result

All eight positive execution configurations passed: four raw-library builds
and four production-runtime interrupt builds. All ten fault programs preserved
the accumulated effect trace and original failure. Twelve refusal checks
(six per specialization mode) failed before output as required. The
[validation record](../bench/2026-11-05-raw-products.json) identifies the compiler
and test-source hashes.

All 39 Haskell suites passed. Strict ARC execution, scalar wrappers, the
ordinary builtin-product allocation/boundary matrix and registry checks also
passed. The registry now includes 39 explicit CI configurations; these are local
results, not a remote CI claim. The existing 10,000-step builtin product loop
still uses zero allocations against 10,001 with product lowering disabled.

Unchanged compiler budgets passed at 1.59/32.73/70.33 GB allocated for
hello/std-live/pos1. Std-live remains close to its limit at +9.4% against the
baseline. The [16–256-helper C2 record](../bench/2026-11-05-raw-product-specialization-cost.json)
retains exact emitted-code/function-count parity with explicit monomorphic
twins, with 0.999–1.000x compiler-allocation ratios. These are the established
compiler-cost regression workloads, not timing bounds for the new handlers.

## Scope limits

These results do not establish maximum interrupt duration, interrupt-stack
usage, native actor response time, deadlines or physical-board behavior.
Recursive raw helpers still require separate termination and stack analysis
for static-arena/WCET admission. Owned-reference packets, open-row boundaries
and broader Base representation support remain separate roadmap work.
