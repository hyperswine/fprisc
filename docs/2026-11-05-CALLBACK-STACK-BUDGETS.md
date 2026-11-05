# Public callback stack budgets

Codegen 179 adds a checked byte budget at builtin RV64 C callback entries:

```
fpr compile --profile=bare-metal-builtin --arc --raw --lib \
  --export=run,twice,product --stack-budget=80 callbacks.fpr callbacks.s
```

Every requested public entry must have a proved peak at or below the limit.
The compiler refuses missing/duplicate entries, unknown runtime costs,
retaining recursion and insufficient space before writing new root assembly.
The limit must be a positive decimal integer. Check-only modes and targets
without the supported C export contract reject the option. An existing output
from an earlier successful invocation is not an admission result for a failed
invocation; build drivers must honor the nonzero exit status.

The budget is checked again for each invocation, including a warm source/unit
cache. It is an admission limit, not an optimization parameter that changes
function bodies to fit. `--raw` is useful for allocator-free callbacks but is
not required: ARC callbacks may be submitted and are refused when their
reference-management or uniform conversions lack bounds.

## Accounted storage and boundaries

`Codegen.Target.RV.Export.adapterStack` consumes the same opaque checked plan
as the adapter renderer. Its frame, stack-staged arguments and direct target edge
participate in the native call graph. The ordinary wrapper contributes 16
bytes; counting only the implementation function is insufficient. Uniform
boxing/unboxing calls are explicit unknowns, even when the implementation
itself is bounded. Both conversion accounting and rendering enumerate the
closed conversion vocabulary.

The compiler retains selected native frames as structured `Emission` data;
admission never parses a comment or trusts a source `size` annotation. The
root emission and checked public wrappers form one graph. Unused constructors
that allocate do not disqualify a closed callback that cannot reach them.
Missing callees and unknown costs reached from a requested callback do. Weak
definitions are explicitly unproved because another linked object may replace
them; a local frame cannot certify that replacement. Strong/private definitions
retain their checked bounds.

Successful output includes:

```
# native-stack-v1: run local=16 peak=32
# native-stack-budget-v1: run peak=32 limit=80 scope=c-entry-closed-unit
```

The peak measures downward stack displacement from the public C entry pointer.
Incoming C stack arguments above that pointer belong to the caller; callers
using a separate stack must reserve their argument area separately. Startup,
the caller's own frame, interrupts, scheduler context switches and arbitrary
linked replacements are not included. This is not a whole-image RAM or WCET
certificate. It neither installs an arena nor changes stack-switching policy.
Per-hart argument cells, static constants and caller-provided memory are
separate storage obligations, not stack bytes.
Tail recursion can have a finite stack bound without a termination or duration
bound; this option proves neither of those time properties.

## Eliminated product guard

The execution test exposed a leftover `truth True` guard after scalar product
erasure, with an impossible panic arm. The conversion simplifier now folds
direct tests of the immutable language Bool constructors and removes blocks
that become unreachable from entry. It reuses its existing definition table;
ordinary unknown predicates retain both paths. Effects, allocations, fuel and
overflowing arithmetic before the branch stay in place.

This removes actual abstraction overhead and the impossible panic edge, rather
than assigning panic a fabricated stack cost. Independent typed-IR evaluation
checks true/false outcomes and all prefix events at both integer limits. The
oracle explicitly rejects evaluator gaps and confirms the prefix allocation
still occurs on success, panic and overflow paths.

## Execution evidence

The [callback record](../bench/2026-11-05-callback-stack.json) covers a 10,000-step
raw Word loop, two nested invocations and a scalarized two-field product:

| Public callback | Proved peak | Observed peak |
| --- | ---: | ---: |
| `run` | 32 bytes | 32 bytes |
| `twice` | 80 bytes | 80 bytes |
| `product` | 32 bytes | 32 bytes |

All three execute on one 80-byte stack with 16-byte guards at both ends. The
RV64 QEMU harness makes 192 invocations per plain/measured mode, including full-width Word wraparound,
checks outputs, SP restoration and every guard byte, and measures SP at each
frame decrement without adding stack usage. No allocator symbols are linked.
Both linked images also pass the existing exact-ELF target-image gate;
the record contains compiler, assembly, image and target-manifest hashes.
Image-fit admission and callback stack admission remain separate obligations.

The refusal suite covers a one-byte shortage, forgetting wrapper storage,
invalid limits, check-only use, absent/duplicate export roots, non-tail
recursion, uniform boxing, runtime writes and possible overflow paths. Base
registers the test, and the RISC-V CI configuration requires execution. Local
execution does not establish a remote CI or physical-board pass.

All 40 Haskell suites pass, including the independent stack-graph oracle and
literal-Bool semantic checks. Native RV32/RV64 stack probes, raw-product and
interrupt execution, and the materializing-pipeline regressions pass. The
unchanged compiler budget passes at **1.60/32.80/69.20 GB** for
hello/std-live/pos1; std-live residency is close to its ceiling at 503 MB
(+24.9%). The [C2 comparison](../bench/2026-11-05-callback-stack-specialization-cost.json)
retains identical code/function counts through 256 helpers and 1.004–1.005x
compiler allocations against explicit twins. The
[validation manifest](../bench/2026-11-05-callback-stack-validation.json)
records the completed checks and exact compiler/source identities.

Initial bookkeeping exceeded the unchanged absolute allocation gates. The
accepted implementation deduplicates runtime targets before making diagnostic
strings, skips graph construction for locally unproved functions, and avoids
copying the entire root assembly when no stack-budget report is requested.
No budget or baseline was relaxed. Unproved reasons identify sufficient
blockers, not an exhaustive inventory of all reachable runtime boundaries.

## Next arena obligations

Allocating callbacks still need physical cell/allocator sizes and peak-live
storage, followed by a checked bounded allocator and execution on that arena.
Runtime/foreign stack contracts and recursion-depth composition remain open.
Whole-image admission must connect entry dispatch, link identity, exported and
interrupt adapters, static sections and each dynamic storage region. Reference
target timing and physical-board qualification remain necessary for WCET.
