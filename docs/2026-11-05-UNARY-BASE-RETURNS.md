# Private unary Base returns

Codegen 193 extends private constructor-return workers to one-field wrappers.
The worker returns its ordinary tagged payload. Its local reader replaces the
known field projection with that value. The original entry still returns the
nominal constructor for public, escaping or otherwise unsupported uses.

This removes the wrapper allocation without adding a one-word aggregate ABI.
`$worker.ret1.*` deliberately has no `TProduct` metadata: argument handling,
return registers, root tracking and owned values use the ordinary value
convention. Wider workers retain the existing two-through-eight-word ABI.
`FPR_NO_PAIR_RETURNS=1` disables both forms. Codegen identity is bumped because
emitted programs change; the external tagged calling convention is unchanged.

## Admission and semantics

All successful result paths must produce the same constructor shape, directly
or through saturated calls whose result shape is established by the finite
function graph. Error paths remain errors. Unknown callbacks, mixed result
constructors, unproved returned variables and unsupported shapes retain the
original calling convention. Only a saturated let-bound call whose result is
used exclusively by matching tag tests and valid projections is rewritten.
Escapes, capture and rebinding refuse the rewrite.

A producer behind a strict let prefix is also eligible. The prefix remains
before the call, in its original order; its binders may extend over the reader
only when they cannot capture reader variables or the newly introduced worker
reference. A prefix that shadows the producer cannot supply its global shape
evidence. Reshaping is published only when the final call and reader satisfy
the ordinary admission rule. No conditional continuation is duplicated.

The field evaluates at its original position. Removing its enclosing
constructor does not discard field effects or failures, even when the reader
uses only the constructor tag. Calls and entry-fuel checks remain. Public
module entries retain their tagged result; a module may independently use its
private worker internally. This is call-boundary allocation removal, not a
new raw-storage representation for arbitrary Base data.

## Allocation and throughput

At 1,000 calls the unary fixture drops from **1,000 wrapper allocations to
zero**. The existing two-through-eight-field cases retain the same reduction;
the unsupported nine-field case retains all 1,000 allocations. A separate
module fixture drops **two to one**: its owner-local return loses its wrapper,
while the value crossing the public boundary retains one.

The saved compiler and current compiler are recorded separately in the
[before](../bench/2026-11-05-unary-returns-before.json) and
[after](../bench/2026-11-05-unary-returns.json) records. The expanded suite checks
heap/function payloads, shared values, nested values, actor transport, unknown
callbacks and mixed constructors, with ordinary and disabled inlining.
Ten exact differentials cover effects, overflow/underflow, division by zero,
unused trapping fields and successful Int endpoints.

The dynamic lifetime regression retains actual list payloads across nested
allocating calls, normal region exits, actor transfer and shared message fields.
With inlining disabled it removes all **8,385** wrapper allocations:
**25,157 → 16,772**, retaining list cells and message storage. The initial
codegen-192 implementation left one actor-path wrapper; that observation led
to the strict-prefix handling above.

The final codegen-193 experiment uses twenty million calls with ordinary
regions and inlining. Its
[native arm64 benchmark](../bench/2026-11-05-unary-returns-throughput.json)
reduces allocation requests from **20,009,766 to zero**. Median time falls
**87.49 → 70.96 ms**, with **12/13** paired wins. The explicit payload source
measures **99.03 ms** and also allocates zero; disabling return workers measures
**90.81 ms** and restores the allocations. These results describe this source
family and compiler choices, not a general advantage over explicit code.
Timings use uninstrumented programs; allocation probes and compilation finish
before sampling. Earlier codegen-192 records remain separately labeled.

Root RV64 text grows **1,788 → 1,936 bytes**, with six versus seven functions,
because the original entry remains alongside its private worker. The explicit
source uses 1,628 bytes. Cold compiler allocation changes **1.5165 → 1.5173 GB**.
The unchanged absolute gates pass at **1.61 / 32.89 / 67.64 GB** for
hello / std-live / pos1; std-live is close to its unchanged 10% allowance.
Existing C2 scaling retains exact assembled code and function-count parity
through 256 helpers, at approximately 1.000–1.001x compiler allocation against
explicit twins.

## Qualification and remaining work

The final codegen-193 compiler passed all **41 Haskell suites**. Native arm64 and x86-64 full source regressions
pass. Independent allocator-free C oracles execute **16,800 RV64 cases** and
**18,900 x86-64 cases**, clobbering volatile registers at fuel resets. Nominal
constructors can introduce another private payload worker when inlining is
disabled; the oracle links the actual emitted worker closure. It supplies no
replacement constructor implementation or allocator. The x86-64 real-runtime
actor/fuel test, existing finite field-worker, wrapper, reuse and controlled
static-arena suites also pass.

All **19 qualification groups** pass in the
[validation manifest](../bench/2026-11-05-unary-returns-validation.json).
Dynamic heap-lifetime checks pass all 16 combinations on native arm64 and
x86-64, with the saved compiler separately checked. The host scheduling matrix
covers **171 configurations and 131,328 uninstrumented replies**, plus separate
fuel/progress probes and watchdog negative controls. It records **50 replies
above the observational 1 ms threshold**, maximum **1.949 ms**: 47 in boxed
guard-helper competition, two in boxed deep-helper competition, and one in
runtime copying. These outliers remain in the record; successful watchdog and
progress checks do not imply every reply met a hard deadline.

The selected **Pi 4B running QOS** subsequently reproduced the 8,385-wrapper
reduction on one and four workers. Its 131,328 physical replies had a median
of 204 µs and p99 of 6,239 µs at 600 MHz. Per-workload latencies, raw samples
and the isolated desktop checks are in the [Pi report](2026-11-05-PI-QOS-PHYSICAL-QUALIFICATION.md).

Codegen 193 inherited the 1,024-node body admission limit. The subsequent
finite hosted-worker admission milestone removes it. General
nested result flattening, unproved result shapes and broader Base storage are
not completed by this change. Recursive and mixed types staying boxed remains
part of the agreed representation policy. Host latency samples do not establish
hardware WCET or general application static-arena admission.
