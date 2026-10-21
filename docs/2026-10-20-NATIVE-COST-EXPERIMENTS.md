# Native cost experiments after the C comparison review

Date: 2026-10-20. Kind: implementation and measurement record.
Base: `a556647`, with code-generation revision 57 and A64 lowering revision 14
for these measurements. Measurements are local macOS ARM64, Apple clang 21.0.0.

Follow-up: [Self-tail frame reuse](2026-10-20-SELF-TAIL-FRAME-REUSE.md)
records the next isolated experiment, its slot-cleanup correction and paired
results with the direct-literal candidate held constant in both modes.

The first measured improvement is small and workload-specific: passing raw
integer literals directly to private workers reduces Fibonacci's median time
by 2.6%, but makes the arithmetic sum witness 2.2% slower. This is an isolated
candidate, not a general performance improvement or a production deployment.
Two attempts to shorten A64 overflow checks failed the timing comparison and
are not enabled by default.

## Direct raw literal arguments

Workers represent a raw literal as `$scalar.unbox (CInt n)`. The ordinary
expression emitter already knows this is an immediate value, but `directArg`
did not recognize that expression. Consequently arguments such as `1` and `2`
were evaluated into a staging slot and then loaded immediately before use.

`Codegen.directArg` now admits that same expression on 64-bit scalar-fast
targets, after checking that the source literal fits an Int. It loads the raw
literal into its argument register at transfer time. Ordinary tagged literals
retain their tagged representation. Nonliteral arguments retain their original
evaluation order and staging, and the existing RV32 fallback remains unchanged.
No arithmetic guard, fuel tick or failure path is removed.

The Fibonacci worker's frame falls from 112 to 96 bytes because removing the
literal staging accesses also removes one register promotion and its save and
restore. This is the existing register-slot heuristic reacting to a smaller
body, not a new register allocator.

## Paired measurements

The same sources were built with a frozen pre-literal compiler and the new
compiler. Guard shortening was disabled in both. The frozen compiler includes
the inactive sign-extract experiment; its exact source patch and binary hash
are retained. No compiler/test processes from this task ran during timing.
Other host activity and CPU frequency were uncontrolled.

Each initial comparison has one warmup and 15 samples per executable, with
forward/reverse order alternating. A second experiment executes the same frozen
binaries for 31 paired rounds, reversing pair order each round and checking
every result. Fibonacci, sum and pipeline use an internal monotonic timer;
byte-loop, helpers and SHA use process wall time. All use one runtime hart.

The repeat medians:

| Witness | Before | Direct literals | Change in time |
|---|---:|---:|---:|
| Fibonacci 35 | 54.937 ms | 53.498 ms | 2.6% less |
| Sum 1 through 10 million | 22.468 ms | 22.965 ms | 2.2% more |
| Million-element map/filter/fold | 2.913 ms | 2.932 ms | 0.7% more |
| Existing byte loop | 103.791 ms | 104.196 ms | 0.4% more |
| Existing helpers | 174.293 ms | 173.297 ms | 0.6% less |
| Existing SHA | 141.966 ms | 142.623 ms | 0.5% more |

Fibonacci was faster in all 31 repeat pairs; sum was faster in only five.
The first 15-sample run measured 2.7% less time for Fibonacci and 1.0% more
for sum. Pipeline and helper root assembly is byte-identical between modes;
their linked units can still differ. These witnesses do not support attributing
every small timing shift to changes in their hot loop.

The sum regression matters. Fewer instructions and a smaller frame do not
guarantee lower elapsed time, and this experiment does not isolate instruction
layout, register-allocation changes or CPU scheduling as its cause. The candidate
needs broader workload and target evidence before a general speed claim.

## Guard shortening did not win

The first variant replaced the four-instruction A64 range check with
`eor` and `tbnz`, using an explicit dead-scratch contract and a nearby-target
check. The second used `sbfx; cmp; b.ne`, preserving the original scratch
value and conditional-branch reach. Both preserve the signed 63-bit predicate.

| Guard-only experiment | Fibonacci | Sum loop | Pipeline |
|---|---:|---:|---:|
| Bit test, 15 samples | 0.75% less time | 5.37% more | 3.90% more |
| Sign extract, 15 samples | 0.97% less time | 4.97% more | 2.88% more |

The bit-test implementation was removed. The smaller, semantics-preserving
sign-extract implementation remains available only with
`FPR_A64_FIT_GUARDS=1`. The default uses the original sequence.
The switch participates in generated-unit and executable-run cache keys.
An exact three-instruction match never crosses a label or directive; RV64 and
x64 emission does not depend on this switch.

These results reject the earlier estimate that guard shortening would recover
roughly a quarter of the Fibonacci gap. They do not establish why either shorter
sequence is slower in the sum loop.

## Corrections to the earlier attribution

This section supersedes the numerical attribution and checked-C claim in
[The gap to C on fib](2026-10-20-FIB-GAP-TO-C.md).

- The ordinary C version has one recursive call site and an accumulating loop.
  The checked signed 63-bit version has two recursive call sites and no such
  loop in the recorded clang assembly. Overflow checking changes which
  optimization occurs, not just the cost of an instruction sequence.
- Ordinary signed C overflow is undefined, not wrapping by default. An explicit
  policy such as `-fwrapv` changes that contract; see
  [Clang's overflow documentation](https://clang.llvm.org/docs/OverflowBehaviorTypes.html).
- The half / quarter / quarter division was a hypothesis, not measured
  attribution. Counting the recursive arm as the cost of every activation also
  overcounts: `fib(35)` has 29,860,703 source activations, including 14,930,352
  leaves that skip all three guarded arithmetic operations.
- The stack-check and fuel variants retained the frame, so they do not establish
  that frame cost is only a few percent. The earlier 1.30x hand-allocation result
  is an observation for that fixture, not a ceiling for other programs.

The initial direct-literal timing run measured C Fibonacci at 15.080 ms
unchecked and 18.560 ms with signed 63-bit checks, against FP-RISC at 55.695 ms
before and 54.211 ms after. All use internal timers and check `9227465`.
The C implementation lacks actor scheduling, growable stacks and FP-RISC panic
diagnostics. These are explicit comparison points, not a decomposition of
the remaining cost.

The linked [register-allocation design](2026-10-19-REGISTER-ALLOCATION.md) is now
present on this base after its merge. Its historical hand-edited 65/50/19 ms
experiment was not reconstructed here; this page supplies a separate repeatable
compiler comparison.

## Validation

- `tests/check_workers.py`: C arithmetic oracle, exact overflow/division
  failures, independent worker/inliner modes, strict effects, managed fields,
  stack growth, allocations, one/four harts and shared-module calls. Its new
  emission witness requires raw literal operands to load directly.
- `tests/check_a64_guards.py`: 100,009 native boundary/random cases against an
  independent C reference for both the range predicate and scratch result;
  exact panic comparisons, one/four harts, generated-unit off/on/off checks,
  executable-cache entry separation, ELF assembly and Mach-O execution.
- Existing pipeline, vector-kind/SIMD/IEEE, register and wide-worker suites pass.
  Their coverage includes x64 execution through Rosetta and cross-target
  emission. The new private-worker suite does not constitute physical RV64
  execution.
- The final cache revision was bumped after these semantic tests. Worker and
  A64 guard/cache suites were rerun after that bump.

The complete Base suite and physical Pi/STAR64 runs were not performed.
QOS was not repinned or deployed. Compiler/runtime ABI interfaces are unchanged;
generated code caches are invalidated by the codegen/A64 revisions.

## Reproduction and retained evidence

From the worktree, after `make fpr`, using fresh output directories:

```sh
python3 tests/check_a64_guards.py
python3 tests/check_workers.py
python3 tools/bench-a64-guards.py --output build/new-guard-trial --runs 15
python3 tools/bench-a64-guards.py --output build/new-literal-trial \
  --before-compiler build/fpr-before-raw-literals --runs 15
```

The first benchmark compares guards off/on in one compiler. The second compares
the frozen compiler to the current compiler with guards off in both.
Result keys `off` and `on` mean before and after in that second mode.
The frozen compiler is retained locally in `build/fpr-before-raw-literals`;
its source is `a556647` plus the saved sign-extract patch. Both guard-only
patches apply to that base, not on top of each other.

[Evidence directory](evidence/2026-10-20-native-costs/) contains:

- [Bit-test samples](evidence/2026-10-20-native-costs/bit-test.json) and
  [exact compiler patch](evidence/2026-10-20-native-costs/bit-test.patch).
- [Sign-extract samples](evidence/2026-10-20-native-costs/sign-extract.json) and
  [exact compiler patch](evidence/2026-10-20-native-costs/sign-extract.patch).
- [Direct-literal samples and hashes](evidence/2026-10-20-native-costs/direct-literals.json)
  and [31-pair repeat](evidence/2026-10-20-native-costs/direct-literals-repeat.json).
- [C source](evidence/2026-10-20-native-costs/fib-c.c),
  [driver](evidence/2026-10-20-native-costs/fib-driver.c) and
  [assembly](evidence/2026-10-20-native-costs/fib-c.s).
- [Validation record](evidence/2026-10-20-native-costs/validation.json) and
  [frozen-binary repeat driver](evidence/2026-10-20-native-costs/repeat-frozen.py).

Full generated assembly, binaries and caches remain under the local
`build/a64-guards-measurement-2`, `build/a64-guards-sbfx` and
`build/direct-literals-measurement` directories.
