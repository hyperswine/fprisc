# Retained-access register scoring

Continues the native performance work committed at `d049714` and the
[register-allocation design](2026-10-19-REGISTER-ALLOCATION.md).
Measured compiler: codegen revision 65, GHC `-O1`, Apple M4, macOS.

The new `FPR_RETAINED_REGISTERS=1` experiment improves three loop workloads.
Combining it with `FPR_SELF_LOOPS=1` reduces sum time by 38.5% and SHA time
by 13.0% against both switches off. It does **not** materially close the
recursive Fibonacci gap to C, and it does **not** fix the helpers regression.
Both optimizations remain off by default.

Follow-up: [frame placement and recursive-call costs](2026-10-20-FRAME-PLACEMENT-AND-CALL-COSTS.md)
adds a fuel-bound selection gate, private frame compaction, paired A64 frames,
and controlled helpers measurements. It also records the still-open mixed-local
representation work.

## Implementation and scope

The existing promotion pass counts frame-slot accesses before slot cleanup,
selects up to five slots with at least six accesses, and puts those slots in
callee-saved registers for the entire function.

The experimental mode counts body accesses after redundant loads and stores
are removed. It adds the parameter-store costs separately because the entry
fuel call prevents forwarding across that boundary. Parameters qualify at
four accesses; temporary slots still need six. Register capacity, save/restore
rules, argument evaluation order, arithmetic checks, stack checks and fuel
ticks are unchanged.

This is a smaller experiment toward stage 1 of the design. It is **not** the
proposed Core live-interval analysis, register reuse, or spill-frame compaction.
The original frame slots remain reserved even when promoted. That matters:
Fibonacci's `n` moves into `x19`, but its worker frame grows from 96 to 112
bytes to save the register, and every invocation pays the save/restore.

The mode applies only to scalar-fast, non-ARC, 64-bit Base functions.
RV32 and builtin emission keep their original policy. `FPR_NO_REGISTERS=1`
continues to disable promotion. The new flag is part of both the imported-unit
cache identity and executable-run cache identity.

With frame reuse enabled too, a self-tail iteration avoids reopening the frame
and saving/restoring the promoted registers. The retained
[sum assembly before](evidence/2026-10-20-retained-registers/combined-sum-off.s)
and [after](evidence/2026-10-20-retained-registers/combined-sum-on.s)
show that interaction. Percentages from separate experiments must not be added.

## Measurements

Each experiment used 31 paired rounds, one warmup per binary, one hart, and
alternating forward/reverse execution order. All expected outputs were checked.
No compiler or test suite launched by this task ran during timing. Other host
work and clock frequency were uncontrolled.

Fibonacci, sum and pipeline use internal timers. Byte loops, helpers and SHA
use process wall time, including startup. These are latency measurements,
not energy, power or allocation measurements.

### Register scoring alone

| Workload | Off, median ms | On, median ms | Time reduction | Faster pairs |
|---|---:|---:|---:|---:|
| Fibonacci | 53.498 | 53.318 | 0.34% | 17/31 |
| Sum | 23.154 | 20.470 | 11.59% | 31/31 |
| Pipeline | 2.914 | 2.983 | -2.37% | 12/31 |
| Byte loop | 104.235 | 98.616 | 5.39% | 31/31 |
| Helpers | 174.829 | 179.854 | -2.87% | 8/31 |
| SHA | 142.589 | 133.164 | 6.61% | 31/31 |

[Raw samples, hashes and binary sizes](evidence/2026-10-20-retained-registers/registers.json).

### Register scoring and frame reuse together

The off variant disables both flags; the on variant enables both.
This is a fresh paired comparison, not an incremental measurement against
frame reuse alone.

| Workload | Both off, median ms | Both on, median ms | Time reduction | Faster pairs |
|---|---:|---:|---:|---:|
| Fibonacci | 54.615 | 54.318 | 0.54% | 20/31 |
| Sum | 23.389 | 14.381 | 38.51% | 31/31 |
| Pipeline | 3.020 | 3.000 | 0.66% | 14/31 |
| Byte loop | 105.837 | 100.165 | 5.36% | 31/31 |
| Helpers | 175.743 | 183.155 | -4.22% | 4/31 |
| SHA | 145.593 | 126.692 | 12.98% | 31/31 |

[Raw samples, hashes and binary sizes](evidence/2026-10-20-retained-registers/combined.json).
The small Fibonacci/pipeline changes do not support a reliable improvement
claim. The helpers result remains a regression; its precise hardware-level
cause is not established by these timings.

The same combined run measured plain C Fibonacci at 14.880 ms and signed-63-bit
checked C at 19.048 ms. FP-RISC at 54.318 ms remains about 3.65 times and
2.85 times those times respectively. C lacks the actor runtime and equivalent
panic diagnostics, and clang changes the recursion shape of the plain version.
These figures describe these fixtures, not a general language-performance ratio.
See the [corrected native-cost analysis](2026-10-20-NATIVE-COST-EXPERIMENTS.md).

## Why this remains experimental

The shared prelude's `modCompatMatch` grows from 174 to 177 in the compiler's
shared-IR instruction bound for a segment between safepoints. That raises the program
maximum in five workloads. SHA's larger maximum remains 357. All functions
retain finite bounds, but finite does not mean unchanged: this fails the
design's no-increase gate.

The [per-function comparison](evidence/2026-10-20-retained-registers/wcet.json)
records increases and decreases for both modes. Together with the helpers
regression, it prevents promoting this heuristic to the default.

Three earlier 15-pair trials are retained to distinguish exploration from the
final measurements:

- [Cleanup-only scoring](evidence/2026-10-20-retained-registers/cleanup-only.json)
  had effectively no timing benefit.
- [Lowering the threshold for all slots](evidence/2026-10-20-retained-registers/lower-threshold.json)
  helped loops but regressed pipeline by 6.4%.
- [Lowering it only for parameters](evidence/2026-10-20-retained-registers/parameter-only.json)
  led to the final opt-in mode.

Their adjacent `.patch` files apply to `d049714`; those are experimental
snapshots, not additional patches to apply to the final implementation.

## Validation

The focused mode test passed independent arithmetic reference results with
registers enabled/disabled on one/four harts, actual promotion in RV64/A64/x64
emission, unchanged RV32/builtin output, and off/on/off imported-unit and
executable-run cache isolation.

With the new flag off, all six benchmark roots and imported units match the
committed revision-61 compiler: [27 assembly-file comparisons](evidence/2026-10-20-retained-registers/default-parity-g61-g65.json),
after normalizing the compiler revision in cache names and encoded interface
metadata. This is normalized assembly parity, not a claim of identical binaries.

The full `tests/check_base.py` suite passed at revision 65 with both flags
enabled. It includes exact overflow/failure reasons, effects, stack growth,
fuel ticks, actor fairness, live reload, ownership, vectors, scalar/wide
workers, register differentials, and runtime stress. Its x64 and RV64/QEMU
self-loop oracles each passed 2,100 independent C-reference cases per loop
mode, including exact fuel resets and constant stack addresses.

The [full log](evidence/2026-10-20-retained-registers/base-g65.log) and
[validation manifest](evidence/2026-10-20-retained-registers/validation.json)
retain the commands, hashes and scope. This also exercises the constant-pool
repair that previously had only focused post-repair validation. The suite's
POSIX RV64 artifact check was skipped because this Apple clang lacks its
RISC-V backend; the dedicated RV64/QEMU execution checks above did run.

No QOS rebuild/deployment, physical Pi/STAR64 test, remote CI or board
acceptance is claimed. A fresh multilib inventory still lacks the strict
RV64IM/LP64 libgcc variant needed for the broader scalar gate; its
[prior linker failure](2026-10-20-SELF-TAIL-FRAME-REUSE.md) was not rerun here.
This limitation is separate from dedicated RV64 execution checks.

## Reproduction and next work

```sh
make fpr
python3 tools/bench-a64-guards.py --retained-registers \
  --output build/retained-local --runs 31
python3 tools/bench-a64-guards.py --retained-registers --with-self-loops \
  --output build/retained-combined-local --runs 31
FPR_RETAINED_REGISTERS=1 FPR_SELF_LOOPS=1 python3 tests/check_base.py
```

Use fresh output directories and the repository's native build dependencies.
To try a program, set the flags when building or running it:

```sh
FPR_RETAINED_REGISTERS=1 FPR_SELF_LOOPS=1 \
  ./fpr build tests/bench/sha.fpr --harts 1 -o build/sha-experimental
```

The next implementation target is a costed placement pass that accounts for
save/restore overhead and reclaims promoted spill space. A lower access-count
threshold alone cannot meet the bounds and regression gates. For the original
C comparison, non-tail recursive call/frame costs remain unresolved; the
loop improvements here should not be presented as solving them.
