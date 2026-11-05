# Multiple and nested Base product parameters

This is the codegen-188 record. Codegen 191 supersedes its four-round limit
with [finite expansion and combined guards](2026-11-05-FINITE-BASE-FIELD-WORKERS.md).
The measurements below remain historical evidence for 188.

Codegen 188 carries checked product evidence through successive private field
workers. A helper may consume several product arguments or nested products
without boxing each intermediate argument. The same transformation handles
closed tuples and records. Fields continue to use ordinary tagged Base values;
this does not introduce raw scalar storage or change the public calling
convention.

## Representation contract

Constructor definitions retain their parameterized field types. Constructor
variables are canonical positional indices, substituted once when a selected
worker expands its parameter. Caller variables cannot be captured by a
constructor's quantifiers. Hidden fields remain unknown. Function types, sums,
open rows and other opaque fields do not contribute an invented product shape.

A worker step transports evidence only when the original and generated binder
lists, selected parameter position, expanded arity and constructor shape agree.
Other checked parameters move to their new positions. The selected fields gain
plans only when their instantiated types have checked product layouts.
Heuristic worker steps can transport untouched checked parameters, but cannot
invent checked field types.

The declaration graph is finite even for expanding recursive types. Evidence
retains only reachable nominal declarations and structural layouts; cache keys
include these latent dependencies, even if two programs erase to identical
Core. A change from an opaque nested field to a product field invalidates the
relevant artifact. Unrelated declarations do not become cache dependencies.

Every original entry keeps its nominal guard and complete fallback. A valid
outer constructor containing an invalid inner actor payload therefore still
executes the inner fallback. Field evaluation, argument order, effects and
checked arithmetic remain unchanged. Public and dynamic calls keep their
ordinary tagged ABI.

The existing four worker rounds, expanded-arity and clone-size restrictions
remain. A five-level wrapper deliberately retains one boxed level. These
worker profitability limits are separate from C2's finite type-instance and
selected-target image admission policy. This milestone does not claim
arbitrary-depth flattening, recursive heap layout removal, variant storage or
general application arena admission.

## Allocation and semantic evidence

The saved codegen 187 and current compiler each pass 91 checked matrix rows.
At 1,000 iterations, with region adapters disabled only for allocation count
isolation:

| Helper shape | Codegen 187 | Codegen 188 | Field workers disabled |
| --- | ---: | ---: | ---: |
| Two independent arguments | 1,000 | 0 | 2,000 |
| Two nested wrappers | 1,000 | 0 | 2,000 |
| Two nested arguments | 3,000 | 0 | 4,000 |
| Four independent arguments | 3,000 | 0 | 4,000 |
| Nested tuples | 2,000 | 0 | 3,000 |
| Nested closed record | 1,000 | 0 | 2,000 |
| Five nested wrappers | 4,000 | 1,000 | 5,000 |
| Generic String payload | 1,000 | 0 | 2,000 |
| Generic list payload | 1,002 | 2 | 2,002 |
| Loop in owning imported module | 3,000 | 0 | 4,000 |

Every case also executes with normal region placement and one/four runtime
workers. The list retains its two actual payload cells. A wrong inner actor
payload preserves the expected `88` fallback. Seven semantic fixtures compare
exact output, exit status and failure text in default, field-disabled,
tuple-disabled and no-inline modes, including successful integer endpoints,
both overflow limits, division by zero and effects before a failure.
Independent machine-IR evaluation checks known valid and invalid argument
answers; compiler tests check latent cache dependencies and expanding recursive
declarations without infinite type expansion.

[Saved results](../bench/2026-11-05-base-product-trees-before.json) and
[current results](../bench/2026-11-05-base-product-trees.json) retain compiler and
fixture hashes.

## Compiler reporting retention

Per-unit progress summaries previously captured `M.size prog` lazily. Since
summaries print after all units are emitted, their thunks retained entire
compatibility-specialized programs. Forcing the count before returning each
summary releases those programs while retaining only an integer. This is a
compiler memory improvement, separate from runtime abstraction removal.
The compile-cost baselines and margins are unchanged. A fresh-emission
comparison against the compiler immediately before this reporting fix produces
byte-identical root assembly, all 38 dependency unit assemblies and exact
stdout/stderr. Both the user cache and adjacent unit directory are cleared
between runs. The [output record](../bench/2026-11-05-base-product-trees-reporting.json)
binds the compared compiler hashes and emitted bytes.

## Native throughput

The two-nested-arguments workload runs 20 million calls with ordinary inlining,
regions and fuel. Separate instrumented executables report **60,029,283 to
zero** constructor requests. Uninstrumented native arm64 executables use a
warmup and thirteen alternating samples, with no concurrent compiler or
qualification workload during timing.

| Form | Median time |
| --- | ---: |
| Saved codegen 187 | 222.34 ms |
| Codegen 188 | 193.12 ms |
| Explicit payload helper | 193.00 ms |
| Current compiler with field workers disabled | 243.83 ms |

The new compiler wins **13/13** paired comparisons: **13.14%** less elapsed
time than the saved compiler, with a measured median **0.06%** above the
explicit helper. This demonstrates consistent allocation removal and
near-explicit throughput for this workload, not a universal zero-cost claim.
The [record](../bench/2026-11-05-base-product-trees-throughput.json) includes
all samples, compiler/source/runtime hashes and independent allocation ledgers.

## Scheduling and compiler cost

The [host scheduling matrix](../bench/2026-11-05-base-product-trees-scheduling.json)
adds nested/multiple helper contention in default and boxed modes. All **117
configurations** pass, covering **89,856** uninstrumented responses. Required
competitors demonstrate fuel exhaustion and completed dispatches in separate
probe runs. The global sampled maximum is **324 us**, with no observations
above the 1 ms reporting threshold. The new helper subset's maxima are
172 us enabled and 261 us boxed. These are observations, not a controlled
latency-speedup claim or guaranteed deadline. The deliberately unbounded C
control is detected, killed and reaped by the 3-second watchdog on one/four
workers.

The unchanged compiler budgets pass at **1.60/32.76/67.42 GB** allocated for
hello/std-live/pos1. Peak live memory is **27/353/498 MB**. For std-live, forcing
the per-unit summary reduces the new compiler's prior approximately 505 MB
peak to 353 MB without raising a budget. The
[C2 16–256-helper gate](../bench/2026-11-05-base-product-trees-cost.json)
retains exact assembled code/function parity and **1.000–1.001x** compiler
allocation against explicit monomorphic counterparts.

## Qualification scope

All 41 Haskell suites pass, along with the saved/current product matrices,
earlier immediate-product and wrapper checks, worker and wide-arity gates,
reset/reuse, open rows, materializing pipelines, registry, compiler-cost,
scheduling and throughput qualification. The new regression is registered in
Base and host-extra CI. These are local native/IR/target-emission results;
no remote CI or physical-board run is claimed. Host measurements do not
establish worst-case execution time or general static-arena admission.

The final [validation manifest](../bench/2026-11-05-base-product-trees-validation.json)
records **17 passed qualification groups**, the 41 Haskell suites, and hashes
of the final implementation, tests, documentation and benchmark evidence.
