# Frame placement and recursive-call costs

Continuation of [retained register scoring](2026-10-20-RETAINED-REGISTER-SCORING.md).
Measured on Apple M4/macOS, codegen revision 66; the final paired-frame
implementation uses A64 lowering revision 15. All new modes are opt-in.

The combined candidate reduces median Fibonacci time by 10.2%, sum by 38.4%,
helpers by 9.8%, and SHA by 15.5% in these fixtures. Pipeline shows no reliable
gain. These are elapsed-time results, not energy-efficiency measurements.

## Build and CI

Linux x86-64 CI already existed in `.github/workflows/ci.yml`: an Ubuntu runner
with a Debian trixie container, native Base checks, and RISC-V cross checks.
The five latest inspected `main` runs were successful, including
[39392099600](https://github.com/hyperswine/fprisc/actions/runs/39392099600).
That is evidence about `main`, not this change.

The existing job now explicitly runs `cabal build` before `make fpr`. It also
runs the worker, register and self-loop suites with the experimental modes
enabled on native x86-64, in addition to the ordinary umbrella checks.
This performance branch also has a push trigger: the available GitHub CLI
account could read runs but received HTTP 403 for manual workflow dispatch.

On macOS, the old local-project example pointed at LLVM directories.
The current native dependency problem is Homebrew's keg-only `libarchive`
pkg-config metadata. Package-level `pkg-config-options` did not make Cabal's
solver find it in a fresh build directory. The updated example selects
`tools/pkg-config-homebrew`, which supplies that metadata path before invoking
the real pkg-config. It supports `/opt/homebrew` and `/usr/local`.

The ignored `cabal.project.local` in this worktree now uses that configuration.
The main `fprisc/` checkout also has a local wrapper in ignored `.cabal-tools/`,
preserving its existing `network == 3.2.7.0` constraint. Fresh dependency
resolution and `env -u PKG_CONFIG_PATH cabal build` succeeded in both checkouts:
[main build](evidence/2026-10-20-frame-placement/cabal-main.log),
[performance worktree](evidence/2026-10-20-frame-placement/cabal-worktree.log).
To configure another macOS checkout, install `pkgconf`, `libgit2`
and `libarchive` with Homebrew, then copy `cabal.project.local.example` to
`cabal.project.local`, preserving any existing machine-specific constraints.
Linux does not need this local override.

## The five work items

### 1. Helpers regression: reproduced, not fully explained

`tools/bench-helper-matrix.py` measures only the loop with an internal monotonic
clock, checks the result, and rotates/reverses execution order. It compares
register scoring and self-loop reuse independently, then the new placement
modes. All binaries are built before measurement.

The initial revision-65 run had a much slower overall time scale, about
264–267 ms, and did not reproduce the regression. A later revision-66 run
measured 173.813 ms with both old switches off, 180.709 ms with retained
registers, and 179.819 ms with both old switches on. Compaction alone measured
172.605 ms; bounded selection plus compaction and self loops measured 175.841 ms.

Aligning every generated function entry to 64 bytes still left retained
registers slower: 171.653 ms off versus 181.878 ms with retained registers.
This rules out entry alignment alone as a sufficient fix. It does not isolate
internal branch layout, register dependencies, cache behavior or host scheduling.
The original scoring heuristic remains a regression on this workload.

Raw data: [initial](evidence/2026-10-20-frame-placement/helpers-initial.json),
[matrix](evidence/2026-10-20-frame-placement/helpers-matrix.json),
[aligned matrix](evidence/2026-10-20-frame-placement/helpers-aligned.json).
The paired-frame optimization below improves helpers independently.

### 2. Cost-aware selection: a fuel-bound acceptance gate

`FPR_COSTED_REGISTERS=1` generates the original and retained-scoring choices
from the same compiler state. It selects the retained choice only if its
segment maximum, exit-tail bound and C-call count are all finite and no larger
than the original choice. Otherwise it restores the original body and compiler
state, including label and constant-pool state.

This includes save/restore and early-exit costs in the existing control-flow
instruction analysis. It fixes the previous fuel-bound regression, including
the shared prelude maximum. It is not yet a weighted hardware cost model,
profile-guided allocator, or live-range register allocator. Helpers demonstrates
that passing this gate does not guarantee lower execution time.

The mode chooses between the two policies itself; it does not require
`FPR_RETAINED_REGISTERS=1`. `FPR_NO_REGISTERS=1` still disables promotion.
Generating both choices adds compiler work while this experiment is enabled.

### 3. Frame compaction: implemented for fixed private slots

`FPR_COMPACT_FRAMES=1` runs after slot cleanup and register promotion. It
renumbers the remaining directly addressed private slots densely, including
saved registers, and reduces the aligned frame allocation. It preserves a
distinct location for every retained slot; no lifetimes are merged.

Computed/escaping frame pointers, unsupported frame operations, and deep
frames retain their original layout. The first version applies to 64-bit
non-ARC Base functions. RV32 and builtin emission stay unchanged.
Stack-growth and fuel checks remain. A deep-recursion test's frame falls from
80 to 32 bytes while retaining correct execution through stack growth.

### 4. Recursive-call cost: paired A64 frames implemented

A benchmark-only assembly experiment first paired adjacent FP/LR stores and
the exact ordinary return sequence. Fibonacci fell from 54.517 to 48.850 ms.
With independent 64-byte entry alignment, it fell from 54.284 to 48.750 ms.
[Prototype samples](evidence/2026-10-20-frame-placement/pairs-prototype.json).

`FPR_A64_FRAME_PAIRS=1` now implements those exact matches in A64 lowering.
It checks the signed scaled STP offset, never crosses a label or an intervening
saved-register restore, preserves the old frame address before loading the
caller FP, and never pairs the reserved hart register x28. There is no
writeback addressing. Arithmetic, fuel and stack checks remain.
The pre-lowering WCET annotation stays conservative.

In a separate fresh compiler comparison, pairing alone reduced Fibonacci time
by 10.0%, sum by 5.0%, byte-loop by 5.6%, helpers by 10.6%, and SHA by 3.3%.
Pipeline's 0.4% difference was not consistent across pairs.
[Compiler samples](evidence/2026-10-20-frame-placement/pairs.json).

### 5. Untagged locals in mixed functions: fixture and narrower diagnosis

`tests/bench/mixed_locals.fpr` retains a String parameter, computes four integer
operations through local bindings, and returns a tuple. Its checked native
output is `kept string 314`. The current worker pass excludes this mixed
signature, as expected.

The [retained assembly](evidence/2026-10-20-frame-placement/mixed-locals.s)
also corrects an overly broad premise: addition and subtraction already operate
directly on tagged integers. The multiplication path unpacks its operands,
checks the fast-path range, and repacks its result. A blanket conversion of
every arithmetic local to raw form is therefore not automatically cheaper.

No mixed-local representation rewrite is enabled by this change. The next
implementation should target arithmetic regions with repeated multiplication
or other measured conversion traffic, box at general-value boundaries, and
preserve exact overflow/division failures, effect order, managed roots across
calls, shadowed operators and foreign-value fallback. This work item is
started through an executable witness and source diagnosis, not completed.

## Combined measurements

The final comparison enables bounded selection, frame compaction, self-loop
reuse and A64 frame pairing together. The baseline disables all four.
It uses 31 paired rounds, one warmup, one hart, alternating execution order,
and checks every result. No task-owned compiler or test run overlapped timing.
Other host activity and frequency were uncontrolled.

| Workload | Baseline ms | Combined ms | Less time | Faster pairs |
|---|---:|---:|---:|---:|
| Fibonacci | 54.747 | 49.190 | 10.15% | 31/31 |
| Sum | 23.356 | 14.390 | 38.39% | 31/31 |
| Pipeline | 2.998 | 3.023 | -0.83% | 16/31 |
| Byte loop | 105.733 | 100.537 | 4.91% | 30/31 |
| Helpers | 177.720 | 160.262 | 9.82% | 30/31 |
| SHA | 146.155 | 123.559 | 15.46% | 31/31 |

Fibonacci, sum and pipeline use internal clocks. Byte-loop, helpers and SHA
use process wall time. The separate helpers matrix above uses an internal
clock. Results from separate experiments must not be added.

The same run measured C Fibonacci at 14.746 ms plain and 18.270 ms with
signed-63-bit checks. FP-RISC remains about 3.34x and 2.69x those times.
C lacks the actor runtime and equivalent diagnostics; this is a fixture
comparison, not a general language ratio.

[Combined samples and hashes](evidence/2026-10-20-frame-placement/combined.json);
[placement without pairing](evidence/2026-10-20-frame-placement/placement.json).

## Validation and acceptance limits

- Focused frame tests pass arithmetic, mixed managed values, one/four harts,
  deep stack growth, self loops, direct-frame fallback, three-backend bound
  checks and four executable-cache modes.
- Paired-frame tests pass 2,001 independent native C call/return cases, ELF
  assembly, Mach-O execution, immediate limits, label barriers, non-A64
  emission parity, and off/on/off unit and executable caches.
- [Structural comparison](evidence/2026-10-20-frame-placement/wcet.json)
  finds no per-function segment/exit-tail/C-call increases in all six
  benchmarks and their imports. The old 174-to-177 prelude regression is gone.
- With all flags off, [27 root/import assembly comparisons](evidence/2026-10-20-frame-placement/default-parity.json)
  match revision 65 after normalizing only compiler/lowering revisions and
  interface metadata. This is assembly parity, not binary identity.
- [Builtin RV64 emission](evidence/2026-10-20-frame-placement/builtin-parity.json)
  is identical with all four experimental flags off/on.
- The full Base suite with all four experimental modes enabled passed:
  [297-line log](evidence/2026-10-20-frame-placement/base-g66.log),
  [validation manifest](evidence/2026-10-20-frame-placement/validation.json).
  This includes exact arithmetic/failure reasons, managed ownership, live apps,
  vectors, scalar/wide workers, 200,000-frame stack growth, 577 MiB heap growth,
  actor scheduling and cleanup. Dedicated x64 and RV64/QEMU self-loop oracles
  each passed 2,100 C-reference cases per loop mode. The separate POSIX RV64
  artifact check skipped because Apple clang lacks a RISC-V backend.

All new switches participate in imported-unit and executable cache identity.
No default is changed. No physical Pi/STAR64 validation, QOS deployment,
strict RV64IM toolchain repair, power measurement or production acceptance is
claimed here. The branch's [Linux run on `e8038d5`](https://github.com/hyperswine/fprisc/actions/runs/39413199551)
has passed direct Cabal build and is still running its tests at the time of
this [status snapshot](evidence/2026-10-20-frame-placement/linux-ci-status.json).
That is not a completed Linux-suite pass. The subsequent evidence-only commit
skips a redundant CI run; compiler and test sources are the ones in `e8038d5`.

## Reproduction

```sh
cp cabal.project.local.example cabal.project.local # macOS/Homebrew
env -u PKG_CONFIG_PATH cabal build
make fpr
python3 tools/bench-helper-matrix.py --placement --output build/helpers-local --runs 31
python3 tools/bench-helper-matrix.py --placement --align 64 --output build/helpers-aligned-local --runs 31
python3 tools/bench-a64-guards.py --frame-pairs --output build/pairs-local --runs 31
python3 tools/bench-a64-guards.py --placement --with-self-loops --with-frame-pairs \
  --output build/combined-local --runs 31
FPR_COSTED_REGISTERS=1 FPR_COMPACT_FRAMES=1 FPR_SELF_LOOPS=1 \
  FPR_A64_FRAME_PAIRS=1 python3 -u tests/check_base.py
```
