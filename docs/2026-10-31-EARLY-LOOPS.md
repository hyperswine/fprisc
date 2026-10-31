# Early self-tail loops: first implementation

Date: 31 October 2026. Reviewed `main` / `origin/main` at `a8ef86b` after
fetching. This is the first implementation slice of
[the current priorities](2026-10-31-PERFORMANCE-AND-PREDICTABILITY-NEXT.md),
not completion of the optimization roadmap. Codegen revision 139.

## Review and choice

The older performance plan mixes proposals with work since delivered. Checked
cross-unit inlining, recursive-caller budgets, reset-safe reuse, scalar vector
and string fast paths, difference-bound discharge, scheduler locality and
persistent-state generations already have implementations and focused evidence.
The latest October 31 document is the appropriate ordering for further work.

Its first item is actionable. More precisely, `Codegen.Lower` already represents
direct self-tail calls as `TBr` to the entry. The selectors turn those into tail
transfers and `Allocate.loopForm` recovers machine loops later. Before selection,
the natural-loop analysis sees an entry-header loop without a preheader, so
invariant motion cannot use it. We do not need a new recursion recognizer to
address this supported subset.

The other recent stream is compiler latency: the source-group indexing and
closed-scheme generalization changes are merged. The latter still scans the
environment and does not eliminate quadratic scaling. The documented next
candidate is a worklist of unresolved operator sites; simply restricting
numeric defaulting to the current SCC is unsafe because later groups can
resolve earlier sites. See [the measured follow-up](2026-10-30-GENERALIZE-CLOSED-SCHEMES.md).
That is independent of this native-code change.

The review also reproduced a correctness defect in `Codegen.Interval`: when a
conditional's true and false edges target the same block, a single predecessor
block was mistaken for proof of either edge condition. A verified W64 IR
fixture computing `maxInt + 1` then lost its overflow check and returned an
out-of-range integer in the evaluator. Edge facts now require distinct true
and false targets. `Interval` tests both outcomes and exact overflow behavior
at W32 and W64, with independent expected results. This fix is unconditional.

The existing `LoopOptimize` differential fixtures also passed tagged external
arguments directly into a raw-Int ABI. They compared matching `Stuck` outcomes
before executing an iteration. A typed entry adapter now calls the raw loop,
and the tests reject `Stuck` and independently check the zero-trip result.
The strengthened loop-motion differential passes.

The full Base run also caught a project-workflow omission already present in
`a8ef86b`: `5a70f90` added `std/test.fpr` without registering it in
`Safety.approvedLibraries`. The module has no unsafe helpers and its reporting
recursion carries `measure checks`. It is now listed with the required entry in
[the safety review](2026-10-15-SAFETY-ALLOW-LIST-REVIEW.md).

## Implemented contract

`FPR_TYPED_IR_EARLY_LOOPS=1` enables `Codegen.LoopForm` at the end of lowering,
before verification and simplification. It defaults off. The flag participates
in unit and executable cache identities. `FPR_TYPED_IR_SELF_LOOPS=0` disables
both early and late self-loop formation.

For canonical direct self-tail branches:

- Create an external entry/preheader with fresh ABI parameter identities,
  the existing stack check and the first fuel tick.
- Keep the original body as the loop header. Transfer changing arguments with
  ordinary typed block parameters and the selectors' parallel-copy machinery.
- Keep a parameter outside the carried tuple only when every back edge passes
  that exact parameter unchanged. This gives invariant motion a dominating
  definition without assuming caller ranges or pointer stability.
- Put each subsequent fuel tick on its back edge, after all argument
  evaluation and before the parallel transfer. No tick is batched or removed.
- Check the reused frame once, as the existing allocator self-loop path already
  does. Non-tail recursive calls still enter and check their own frames.

The transform is idempotent. Nonrecursive functions, ordinary recursive calls,
mutual/indirect tail transfers, noncanonical entries and conditional edges to
the entry retain their existing lowering. Region operations, resets, calls,
loads and trapping argument expressions retain their original order. No new
descriptor-lifetime or memory-hoisting permission is introduced.

The evaluator records stack probes as events. Comparing the old entry-header
IR to the new form therefore excludes only those redundant stack-probe events;
values, exact traps, calls and fuel events must match. Once early lowering has
run, simplifier differentials still require exact equality of **all** events.
Tests also require exactly one stack probe per formed frame (none on fixed-stack
profiles). This makes the existing late-backend frame behavior explicit earlier.

## Validation

The `LoopForm`, `LoopOptimize`, `CompilerOptions`, `TypedIR` and `Interval`
Haskell suites pass. The new suite covers both word widths, hosted/fixed-stack
policies, zero/one/many iterations, two back edges, changing versus invariant
parameters, parallel swaps, integer-limit overflow, division traps, exact fuel,
ordinary recursion and conservative refusal.

`check_early_loops.py` passes off/early/early-plus-motion/off transitions in one
cache. It runs independent 2/7/8/63-value rotations (up to 64 total parameters),
ordered printing, exact fuel counts, nested stack growth and fairness on one
and four harts. A64, x64, RV32 and RV64 emission passes with finite segment
metrics and no late `m3loop` conversion in early mode. This script is registered
in Base; the Haskell suite is included by `check_typed_ir.py`.

The early-enabled compile-budget gate passes unchanged on GHC 9.8.2 / macOS
arm64: hello 1.40 GB allocated, std-live 27.26 GB, POS 63.43 GB. These are
respectively 2.4%, 2.3% and 3.5% below the checked-in baseline; that historical
comparison includes earlier compiler improvements and is not attribution to
this change. No budget threshold was changed.

All **161 registered Base jobs** have successful results across resumed local
runs with early formation enabled. An x64 test's late allocator-conversion
counter assertion was updated for early CFG loops; its cell-transfer checks
and independent execution oracle remain intact. The trust-list failure above
was repaired, and the remaining checks plus affected admission checks rerun.
The `ProjectWorkflow` suite and a safe-profile `std/test` native pass/fail probe
also pass, including exact output/exit status on one/four harts.

Execution includes macOS A64, x64 under Rosetta (independent C ABI oracles and
the real Darwin runtime), and RV32/RV64 under QEMU. Generic native-host x64
execution, Linux x64 production-runtime execution and a POSIX RV64 artifact
check report platform/toolchain skips. These are not physical-board or hosted
CI results. [The validation record](evidence/2026-10-31-early-loops-validation.json)
lists every covered job, resumed-run provenance, checks, skips and fingerprints.

## Measurements and default decision

Seven alternating-order samples after warmup on macOS arm64, one hart, with
the checked-in independent output checked on every run. The saved baseline is
the compiler rebuilt from `a8ef86b`; off/early/motion use the same candidate.
Runtime sampling waited for the regression processes to stop. Medians in ms:

| Fixture | Saved baseline | Candidate off | Early loops | Early + motion |
| --- | ---: | ---: | ---: | ---: |
| byteloop | 110.67 | 106.43 | 104.73 | 108.16 |
| sha | 97.19 | 99.97 | 98.64 | 98.13 |
| helpers | 110.25 | 123.36 | 119.84 | 117.97 |
| floatcmp | 61.46 | 66.23 | 64.01 | 63.37 |

These small same-compiler median differences overlap substantial control
variation. Baseline/off root native headers and line counts match on these
fixtures; neither the timing differences nor header equality prove whole-image
instruction identity. **There is no convincing general speedup claim and no
default-on promotion.** The useful result is exposing the loop structure for
further optimization while preserving behavior.

Early formation raises compiler allocation by 0.71-1.06% against candidate off
on these four cold compiler runs. Combining motion raises it by 3.20-7.83%.
The first fixture's compilation overlapped regression work, so the recorded
compile wall times are observations rather than an isolated time comparison.
Executable size is unchanged for three fixtures; helpers grows from 472,872
to 489,384 bytes (3.5%) in both early modes.

`sumB` now has entry `b9` with four ABI parameters, branching to header `b0`
with only index and accumulator carried. Its frame falls from 64 to 48 bytes,
with no spills. Adding motion raises the frame back to 64 bytes and increases
values live across calls from six to nine. This is a reason to retain separate
formation/motion controls and pursue the planned range/pressure work.

[Raw samples and fingerprints](../bench/2026-10-31-early-loops.json) include
compiler/source hashes, cold compiler allocation, observed build times,
executable sizes and the exact `sumB` native headers. These are local hosted
measurements, not physical-board timings or a hard resource certificate.
They precede the final `std/test` allow-list repair; the measured code-generation
sources are unchanged by that library-registration fix.

## Remaining steps

Early formation is a foundation, not a proof of induction ranges or a reason
to enable invariant motion globally. Next, use the exposed entry/back-edge
structure to prove ranges that survive every iteration. Cross-block sharing
and rematerialization still need pressure measurements. Fuel batching still
needs partial-batch accounting, trap/exit handling and a scheduling bound.
Mutual recursion requires a separate calling contract. Hard elapsed-time
admission remains the design work described in the October 31 plan.
