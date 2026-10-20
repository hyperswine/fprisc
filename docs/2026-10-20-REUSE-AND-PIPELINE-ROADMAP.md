# Allocation reuse and pipeline optimization

Kind: implementation, measurement and remaining-work record.
Continues the two optimization tracks after commit `0c71fb4`, which published
the wider accumulator workers and first mixed scalar pipeline pass.
These follow-up changes use code-generation revision 54.

## Pipeline callbacks now inline within a fixed budget

The [mixed scalar pipeline](2026-10-20-MIXED-SCALAR-PIPELINES.md) can inline
each callback with at most 64 Core nodes and 64 temporary slots. Larger
callbacks retain their raw function calls. This is one level of inlining:
calls inside the callback keep the existing raw ABI. The common raw expression
emitter now accepts either ordinary function-frame slots or kernel scratch
slots, preserving the same checked Int and IEEE floating operations.

Each inlined callback keeps its entry fuel tick. Values live across that tick
are stored before it, and nested calls retain their own safepoints.
Filters still control which later callbacks execute. Float folds remain
left-to-right. Existing map-only SIMD paths and the generic representation
fallback remain intact. `FPR_NO_PIPELINE_INLINE=1` selects the previous fused
loop with callback calls; `FPR_NO_VEC_FUSE=1` selects separate passes.

The native differential matrix includes both callback implementations, both
general-inliner settings, both register-allocation settings, one/four runtime
harts, and a fusion off/on/off cache cycle. The x64 probe executes both modes
under Rosetta with fuel/allocation callbacks that deliberately clobber temporary
SIMD registers. Native A64 IEEE/SIMD checks, four-backend emission, worker and
fallback-frame regressions pass.

## Fresh constructor storage can be reused

`compiler/Reuse.hs` proves a narrow local case:

```text
r = {left=n, right=n+1};
{left=r.right, right=r.left}
```

The parent allocation must be fresh in the same function, with 1–64 fields.
Its uses throughout the remainder of its scope must be valid field projections
or tag tests. Whole-value uses, local aliases, closure captures, shadowed
binders and invalid projections decline reuse. A projected child may escape:
it does not alias the parent allocation. Analysis is limited to 256 Core nodes
per candidate continuation.

Every non-error exit must reconstruct the same type, variant and width.
The emitter evaluates all replacement fields into scratch slots in source
order, then overwrites the original fields without an intervening call.
Thus swaps read the original fields, a failed field evaluation leaves the
parent untouched, and shared child objects retain their value semantics.
The original allocation header and layout remain valid.

This is enabled only for 64-bit Base code with scheduler instrumentation and
without ARC. RV32, Builtin and ARC retain their previous construction paths.
Borrowed function arguments and arbitrary existing list nodes are not eligible.
No reference-count heuristic, public ownership annotation or runtime ABI change
is introduced. `FPR_NO_REUSE=1` restores ordinary construction.

Tests cover tuple, record and list-cell results, aliases, borrowed inputs,
shared String children, ordered fields and a failing first field. Core-level
tests additionally exercise closure escape, shadowing, invalid projections,
self-reference, incompatible shapes and analysis budgets. Native tests cover
both inliner/register settings, one/four harts and an off/on/off cache cycle.

The allocation fixture runs 10,000 fresh record constructions followed by a
field swap. It falls from **20,000 to 10,000 allocation requests**, and from
**960,000 to 480,000 allocated bytes**, on the local Mac, Pi and STAR64.
Those are allocation totals, not RSS measurements.

Both new switches participate in generated-unit and executable-run cache keys.
The run cache now also includes the existing vector fusion/SIMD switches, which
were already represented in unit cache keys.

The complete `tests/check_base.py` suite passed after these changes, including
application reloads, contracts and ownership, vector/worker regressions, actors,
I/O, module loading and numeric behavior. A separate executable-run-cache check
observed 20,000 → 10,000 → 20,000 allocations as reuse was switched off/on/off.
The Core proof tests admit 64 fields and decline 65.

## Physical measurements

Linux ARM64 runs on the Pi 4 at `192.168.0.233`; Linux RV64 runs on STAR64 at
`192.168.0.215`. Pinned SSH identities and post-upload executable hashes are
checked. Every mode passes the corresponding correctness tests with one/four
harts; benchmarks use one hart, seven samples per mode, alternating mode order.
Board test files are removed afterward, and QOS services remain installed.

Pipeline benchmark: one million Int values, map `x+1`, filter `>500000`, fold
`acc+2*x` from 7. Input allocation and final freeing are outside the timer.

| Board | Separate passes | Fused callbacks | Inlined callbacks | Less time than fused callbacks |
|---|---:|---:|---:|---:|
| Pi 4 | 98.534 ms | 96.933 ms | 77.704 ms | 19.8% |
| STAR64 | 74.583 ms | 69.664 ms | 52.278 ms | 25.0% |

Constructor benchmark: one million fresh two-field records followed by a swap
and scalar sum. Both variants include allocation-counter instrumentation.

| Board | Reuse off | Reuse on | Less time |
|---|---:|---:|---:|
| Pi 4 | 620.840 ms | 353.230 ms | 43.1% |
| STAR64 | 350.492 ms | 212.371 ms | 39.4% |

These are focused microbenchmarks alongside live services, with unpinned CPU
clocks. They establish the compiler mechanisms and local wins, not a general
QOS application speedup. QOS was not repinned or redeployed.

## Remaining roadmap

| Track | Next implementation | Evidence needed before enabling |
|---|---|---|
| Allocation reuse | Propagate uniqueness through local aliases and branches, then introduce private consuming workers for callers that prove unique arguments | Retained-alias negatives, shared tails/children, message and module boundaries, failure-before-write tests, allocation counts |
| Allocation reuse | Extend consuming workers to record-update loops and list-node rebuilding | Recursive ownership proof; no assumption that local last use means global uniqueness; ARC retain/drop integration before enabling that backend |
| Pipeline fusion | Reduce scratch loads and stores within bounded inlined callback bodies | Same arithmetic/trap/fuel behavior, register-pressure and code-size measurements on A64/RV64/x64 |
| Pipeline fusion | Add captured and record-valued SIMD kernels where their layouts and operations qualify | Scalar/C IEEE parity, lane tails, stable filter compaction, unchanged fold order and target-specific hardware execution |
| Pipeline fusion | Extend producer/consumer fusion to immutable-list pipelines | Purity/failure-order gates and ownership of intermediate nodes, with independent result and allocation checks |

The current scalar fusion and local reuse implementations provide separate
baselines for these steps. General dead-node reuse still requires ownership
evidence beyond a variable's last syntactic use.

The [evidence JSON](evidence/2026-10-20-roadmap-followup.json) records exact
source/compiler/executable hashes, test outcomes, board identities, allocation
ledgers, all timing samples and cleanup status.
