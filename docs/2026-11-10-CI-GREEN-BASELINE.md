# CI baseline: what the red x86-64 job was hiding

10 November 2026, at `f4d0113`. `main` had not had a green CI run since
31 October. From 7 November the x86-64 job stopped in "Typed IR direct
backends" on a test helper that no longer compiled (`tests/EmitA64Frames.hs`,
fixed by #60), so every later step was skipped: the RISC-V QEMU oracles, RV64
Linux, the Tang Nano gates, the host-extra group and `check_base`. This note
records what was behind that step once it ran, found by running each check of
the five `tests/check_ci.py` groups on the Mac (arm64, Rosetta for x64, QEMU
for RISC-V) without stopping at the first failure.

## Found and fixed

1. **The GPU pair-sum hook was no longer offered** (compiler, all targets).
   `tests/check_typed_ir_kernels.py` failed with `oracle failure 99` in the
   pair-sum oracle, on Linux x86-64 in CI and under Rosetta here. Only the one
   length the oracle's hook answers (77) was wrong: the CPU strip computed the
   sum and the hook was never called. `isGpuPairSum` (`compiler/Codegen.hs`)
   recognises `acc + column 0 + column 1` after looking through the
   always-true shape guard of a field read, but only where the guard sat above
   the sum as a `let`. The field reads are now inlined, so the body is
   `acc + (if True then c0 else error) + (if True then c1 else error)` and the
   guards are operands of the sum. The recogniser now looks through them
   there too. 0.13.0 emitted the hook; `e138e65` (6 November) already did not,
   so the QOS pin has the same loss. No wrong answer in a real program: with
   no hook the CPU kernel computes the same sum. `codegenRev` 208.

2. **Mach-O x64 oracle assembly used an ELF section name.** The kernel check
   appends the unit's `.Ltirstr` pools under `.section .rodata` (`21af9ab`);
   Mach-O rejects that. It is `.const` on macOS, as `check_x64_scalar.py`
   already does.

3. **The wide-record filter oracle was stale.** The record filter kernel now
   requires its element type, where 0.13.0 required only enough columns. The
   oracle passed `R9`'s identity for a 300-column `WideRow` vector, so the
   kernel correctly took the generic path. The fixture gains `sampleWide`, the
   oracle takes `WideRow`'s identity from it, and a wide-enough vector of the
   wrong element type is now a checked fallback case.

4. **The audited RV64 heap contract did not match `runtime/fpr.h`.**
   `machine/builtin/contracts/rv64-c-heap-v1.json` held the header's hash from
   `5e4f248`; `5421687` (A64 QOS app context and ABI numbers) and `a8fcaff`
   (the `fpr_sort_perm` prototype) changed the header afterwards. Neither
   touches RV64 builtin heap geometry, ownership or allocation demand. With
   the hash updated, `check_static_arena`, `check_static_sequence` and
   `check_scalar_admission` pass under QEMU.

5. **`check_pair_raw.py` looked for a function that is now a worker.** `swap`
   is emitted as `$worker.ret2.$product.swap` and `step` is inlined into
   `loop`. The retain/release count now covers every emitted body of each
   source function.

6. **`make fpr-dev` could not resolve a plan.** `cabal.project.freeze` pins
   `fp-risc -dev` (since `6111dea`), which `-f dev` contradicts. The target
   builds through `cabal.project.dev`, which does not read that freeze.

7. **The nightly reliability job never finished.** Its full size
   (`RELIABILITY_FULL=1`) was cancelled at the job's 40-minute limit on every
   scheduled run from 4 November, in `config_differential.py`, so the full
   configuration differential and the 2000-mutant fuzz have produced no
   result. The limit is 180 minutes on the schedule and unchanged on pushes.
   How long the full size takes is not yet known.

## Open

- **A Pair of Word no longer fits the 16 KiB heap in `check_pair_raw.py`.**
  With item 5 fixed the check reaches the RawWord program, which ends in
  `Builtin: out of memory` at `tot (build 50)`. The Int program fits. Both
  pass at 32 KiB with no live allocation left, so it is peak demand, not a
  leak, and the wrong way round for a representation that should be smaller.
  Not diagnosed; the heap size in the check is unchanged so the check stays
  red on this.

## Results on this host

62 of 72 checks passed before the fixes in items 4 and 5; with them, the
three contract checks pass and `check_pair_raw.py` fails only on the open
item. Six checks cannot run here and are CI-only evidence:
`check_rv32_float_constants` and `check_fixed_stack_reservation` (no RV32
SoftFloat archive), `check_typed_ir_x64` in both modes (requires native
x86-64, not Rosetta), and `check_rv64_linux` in both modes (no
`riscv64-linux-gnu-gcc`). `check_base` and the Tang Nano steps were not run.
