# Self-tail frame reuse: implementation and measured tradeoffs

Date: 2026-10-20. Kind: implementation and measurement record.
Base: `a556647` plus the earlier direct-literal candidate, common to both
measurement modes. Measured compiler: code-generation revision 59, A64 revision 14.
The subsequent constant-pool repair is revision 61; its validation is separated below.
Host: macOS ARM64, Apple clang 21.0.0.

Reusing the frame on a self-tail call reduced median execution time by 10.0%
for sum, 7.6% for the byte loop, and 6.3% for SHA in 31 paired repeats.
Helpers regressed by 2.5%; Fibonacci was essentially unchanged. The feature
remains opt-in with `FPR_SELF_LOOPS=1`. These are local experimental results,
not a default change, deployment, or physical-board performance claim.

This follows the self-tail-loop item in
[the register-allocation design](2026-10-19-REGISTER-ALLOCATION.md) and the
[earlier native cost experiments](2026-10-20-NATIVE-COST-EXPERIMENTS.md).

The later [retained-register experiment](2026-10-20-RETAINED-REGISTER-SCORING.md)
measures this mode together with a different promotion policy at revision 65.
Its combined results and validation are separate from the frame-only numbers here.

## What changed

For an eligible saturated call back to the same function, the compiler replaces
the exact frame teardown and function jump with a local jump after the prologue
and preserved-register saves. Each iteration still:

- Evaluates and stages arguments in the original order.
- Copies argument registers and any per-hart spill cells into parameter slots.
- Executes the original stack-headroom check, where present.
- Decrements fuel and takes the scheduler path at exhaustion.

The call emitter stages all arguments before transfer, so cyclic permutations
and arguments beyond the eight argument registers retain their values. No
frame-relative parameter is overwritten before its incoming value has been
staged. Saved registers remain live across the back-edge and are restored on
the ordinary exit.

The transform requires a 64-bit, scalar-fast, fuel-instrumented, non-ARC
function. Other calls, mutual recursion, non-tail recursion, RV32, and builtin
emission keep their existing paths. Both generated-unit and executable-run
caches include the switch.

The stack-headroom check is deliberately retained on every iteration. Removing
that check is a separate optimization and is not part of these measurements.

## Slot cleanup and bounded fuel segments

The first implementation introduced the back-edge before the existing
peephole pass. Its conservative handling of cycles retained previously dead
stores. This increased the SHA program's reported segment bound from 357 to
358 IR instructions.

The final implementation first cleans up the ordinary invocation, then
replaces its self-tail exit. An ordinary self-tail call already reopens the
same-sized frame at the same slot addresses. Eliminating its teardown/setup
does not make a previously dead slot live. Performing the transform after
cleanup preserves those eliminations without adding a new loop analysis.

WCET analysis recognizes only explicitly supplied, compiler-proven entry
labels as fuel-reset destinations. Arbitrary cycles still report `UNBOUNDED`;
negative tests cover both an unregistered loop and a second loop that bypasses
the registered entry.

Across all six benchmark programs and their imported units, every reported
per-function bound remains finite and none increases. Program maxima remain
174 IR instructions for the first five witnesses and 357 for SHA. The sum
worker's bound falls from 43 to 39. These are compiler IR bounds, not measured
hardware cycle counts.

## Final paired measurements

Both modes use the same compiler and retain the direct-literal candidate.
A64 guard shortening is disabled. Each executable gets one warmup and 15
initial samples. A separate run repeats the same frozen binaries for 31
paired rounds, alternating order and checking every result.

| Witness | Frame reuse off | Frame reuse on | Change in median time |
|---|---:|---:|---:|
| Fibonacci 35 | 55.579 ms | 55.740 ms | 0.3% more |
| Sum 1 through 10 million | 23.866 ms | 21.472 ms | 10.0% less |
| Million-element map/filter/fold | 3.058 ms | 3.021 ms | 1.2% less |
| Existing byte loop | 107.186 ms | 99.014 ms | 7.6% less |
| Existing helpers | 177.829 ms | 182.264 ms | 2.5% more |
| Existing SHA | 146.338 ms | 137.160 ms | 6.3% less |

Sum, byte loop and SHA were faster in all 31 pairs. Helpers was faster in only
seven pairs. The initial 15-sample comparison also showed those three wins
(11.2%, 7.8%, 7.1%) and the helpers regression (4.4%).

Fibonacci, sum and pipeline use internal monotonic timers. Byte loop, helpers
and SHA use process wall time, including runtime startup. All runs use one
hart. No compiler or validation processes from this task ran during these
timings; other host activity and frequency remain uncontrolled.

Fibonacci, pipeline and SHA have byte-identical root assembly between modes.
Their imported units can change. SHA's improvement is therefore evidence
about its linked program, not a changed root function. The small Fibonacci
and pipeline movements do not establish a meaningful speed change.

Linked executable sizes increase by 328–704 bytes in these unstripped builds.
This experiment demonstrates runtime savings for some workloads, not an
executable-size reduction.

The retained C Fibonacci references measured 14.895 ms unchecked and
18.532 ms with signed-63-bit checks in the final initial run. Frame reuse does
not address Fibonacci's non-tail recursion or close that measured gap.
Those C fixtures also lack the actor runtime and FP-RISC panic diagnostics.

## Validation

- Native ARM64: off/on/off switches, registers enabled/disabled, one/four
  harts, cyclic argument rotation at arities 3/8/9/64, exact fuel accounting,
  observable effect order, stack growth under mixed tail/non-tail recursion,
  an allocation-free busy actor yielding to its parent, and warm cache isolation.
- x64 under Rosetta and RV64 under QEMU: each mode passes 2,100 independent
  C-reference argument-permutation cases, exact fuel-reset counts, and constant
  stack depth through repeated scheduler-stub calls.
- RV32 and builtin output remains byte-identical between modes.
- A SHA/prelude WCET ratchet compares every function after normalizing the
  cache-mode component embedded in specialization names.
- The full `tests/check_base.py` suite passed with frame reuse enabled at
  revision 59. Its existing POSIX RV64 artifact check skipped because Apple
  clang has no RISC-V backend. The [complete log](evidence/2026-10-20-native-costs/self-loops-base-g59.log)
  is retained.
- After the constant-pool repair at revision 61, the focused native checks,
  all 640 WCET bounds, x64/RV64 execution oracles, and the broader RV32 QEMU
  scalar gate passed again.

No Pi, STAR64, or QOS deployment was performed. The remaining strict RV64
scalar gate requires an RV64IM/LP64 `libgcc`, which this installed toolchain
does not provide. Its fallback library has the double-float ABI, and the
linker rejects mixing it with the test's soft-float objects. The available
RV64IMAC/LP64 library would broaden the required ISA; the gate was not weakened
to use it. The dedicated RV64 loop oracle does not need these library helpers
and passes independently.

## Additional correctness repair found during validation

The existing RISC-V scalar gate initially failed to link soft-float helpers.
Its `-nostdlib` link omitted `libgcc`; the harness now explicitly requests that
library and supports `--bits 32` or `--bits 64` for independent target runs.

With the RV32 dependency present, the gate exposed an undefined `.Lnul_0_0`
constant in generated code. The frozen pre-frame-reuse compiler reproduces
this failure. Indexed-memory lowering synthesizes a `Unit` result after the
original program's constant scan, so the emitted reference can lack its
definition. Inlining a reference to an elided constructor function has the
same coverage problem.

Revision 61 records actual nullary references during emission and includes
those constants in the pool, once each. The regression test covers lowering
that creates `Unit`, elided constructors, duplicate references, unused
constructors, local shadowing, and the ordinary Base-call boundary.

This repair is separate from the measured speed change. The full Base suite
was not repeated after it. All six measured programs and their imported units
were re-emitted with revisions 59 and 61: all 27 assembly-file comparisons match after
normalizing compiler revisions in cache namespaces and interface metadata.
The [comparison hashes](evidence/2026-10-20-native-costs/self-loops-base-parity-g61.json)
and final focused/runtime checks support that narrower validation boundary.

## Evidence and reproduction

The [final samples](evidence/2026-10-20-native-costs/self-loops.json),
[31-pair repeat](evidence/2026-10-20-native-costs/self-loops-repeat.json), and
[per-function WCET comparison](evidence/2026-10-20-native-costs/self-loops-wcet.json)
retain hashes and raw measurements. The sum worker assembly is retained
[before](evidence/2026-10-20-native-costs/self-loops-sum-off.s) and
[after](evidence/2026-10-20-native-costs/self-loops-sum-on.s).

The [compiler patch](evidence/2026-10-20-native-costs/compiler-through-self-loops.patch)
is cumulative from `a556647`, including the earlier literal and optional A64
guard changes, through the measured revision 59.
The [constant-pool repair](evidence/2026-10-20-native-costs/builtin-nullary-repair.patch)
applies afterward; [validation metadata](evidence/2026-10-20-native-costs/self-loops-validation.json)
distinguishes the measured and final compilers.
The [initial trial](evidence/2026-10-20-native-costs/self-loops-initial.json)
and its [compiler patch](evidence/2026-10-20-native-costs/self-loops-initial.patch)
predate the corrected cleanup ordering and must not be substituted for the
final results.

From this worktree, with the repository's native build dependencies available:

```sh
make fpr
python3 tests/check_self_loops.py
python3 tests/check_self_loop_x64.py
python3 tests/check_self_loop_rv64.py
python3 tests/check_riscv_scalar.py --bits 32
FPR_SELF_LOOPS=1 python3 tests/check_base.py
python3 tools/bench-a64-guards.py --self-loops --runs 15 --output build/self-loops-new
python3 docs/evidence/2026-10-20-native-costs/repeat-frozen.py build/self-loops-new
```

Use a fresh benchmark output directory. On this host, builds used
`PKG_CONFIG_PATH=/opt/homebrew/opt/libarchive/lib/pkgconfig:/opt/homebrew/lib/pkgconfig`;
validation caches were kept under the worktree with `XDG_CACHE_HOME`.

The next promotion gates are resolving the helpers regression, supplying the
strict RV64 toolchain for the broader scalar gate, and collecting physical-target
evidence.
