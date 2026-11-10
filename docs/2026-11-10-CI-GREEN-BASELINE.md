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

8. **CI's SimpleRisc pin was older than the presets.** The workflow checked
   out simple-risc `cf42451` (1 November), where `fprisc-72` is placement 0
   with no floorplan. `tools/run_tangnano20k_examples.py` has described
   placement 3 with `fprisc-81.plan` since `9451dca`, and the RV32IM
   `fprisc-81`/`fprisc-84` presets since 8 November, so "Tang Nano preset and
   protocol gates" failed once CI reached it. The pin is `00fbd13`
   (fprisc-84: the RV32IM canon), the commit those presets were written
   against; the Tang Nano steps pass against it here.

9. **x86-64 inline bump allocation overwrote its own slab pointer when the
   cell's destination was spilled** (compiler, x86-64 only). With the pin
   moved, CI reached the host-extra group for the first time and
   `check_finite_field_workers.py` timed out in `parameters-16-regions-boxed`.
   The program runs in 10 ms on arm64; on x86-64 it hangs on Linux and
   faults under Rosetta, from 12 boxed parameters up, and not with
   `FPR_NO_BUMP_ALLOC=1` or `FPR_NO_INLINE=1`.

   The inline bump (`Codegen/Target/X64.hs`) keeps the hart and then the pool
   in r11 and the window's slab in r10. Those are also x64's only two
   allocator scratches, and `Allocate.rewrite` hands a spilled or dead
   definition a scratch. So a spilled cell arrived as r10 and the fast path
   read `movq 32(%r10), %r10`: the cell's end replaced the slab, and the
   bounds test and the header store then used it as a slab. AArch64
   (x16/x17 against scratches x13..x15) and RISC-V (t3..t5 against t0..t2)
   keep the two sets apart and are not affected.

   When the destination is r10 or r11 the cell is now built in rax, pushed
   before the fast path and popped after it on both exits, then moved to the
   destination once r10 and r11 are finished. `codegenRev` 209. The inline
   bump is from 3 November (`0567ca6`), so `e138e65`, the QOS pin, has the
   fault for hosted x86-64 programs with enough live values around a
   constructor; a loaded QOS app keeps the allocator call and is not
   affected. `check_finite_field_workers.py` now asserts on every host that
   the x64 assembly of that fixture builds its spilled cells in the borrowed
   register, and `check_x64_macos.py` runs it.

## The Word pair that no longer fit its heap

With item 5 fixed, `check_pair_raw.py` reached the RawWord program, which
ended in `Builtin: out of memory` at `tot (build 50)` in its 16 KiB heap; the
Int program fit, and both passed at 32 KiB with no live allocation left.

Not a compiler regression. The check declared `Pair = Type (Pair a b)`: `a`
and `b` are type variables of a non-parametric type. On 3 November their
field kinds were inferred by unification from use, which is what the
[experiment](2026-11-03-PAIR-RAWWORD-EXPERIMENT.md) relied on. Since the
generic tagged fallback
([completion record](2026-11-04-ZERO-OVERHEAD-COMPLETION.md), codegen 166)
such variables are uniform slots, so `build` boxed each Word
(`$arc.uniformBoxWord`, one 24-byte cell) on the way into the pair: two extra
cells a pair, and 50 pairs did not fit. `e138e65` behaves the same.

Declared parametric, `Pair a b = Type (Pair a b)`, the specialiser gives the
pair raw Word fields, with no box site, and the program fits 16 KiB again
(37 retain/release sites against 48 for Int fields). The check now declares
it that way.

Its last stage expected a program mixing `IPair` and `WPair` through a List
to be refused as "incompatible representations" under `FPR_NO_TYPE_SPEC=1`.
That refusal is gone by design (the fallback keeps the generic ABI when
cloning is off). The stage now checks what holds instead: raw Word fields
with C2 clones by default and with no clones under `FPR_NO_TYPE_SPEC=1`, and
that the same program with fields left as variables of non-parametric types
does box each Word.

One thing for the language rather than the check: `Pair = Type (Pair a b)` is
accepted silently and costs two allocations per pair against the parametric
spelling. `--remarks` says nothing about it.

## check_base: the last step, and what is still red

With items 8 and 9 merged, the x86-64 job passes every step up to and
including host-extra on Linux and stops in `check_base`, which stops at its
first failing job. Run here with each failing job set aside in turn until the
rest passed: 227 jobs, 7 failing. All of them fail with the allocation fix of
item 9 removed, so none comes from it, and the ones checked against
`e138e65` (pagination, the ideal examples) already fail there.

Fixed, stale against `5e4f248` (5 November):

- `tests/check_pagination.py` and `examples/ideal/check.py` asserted that
  `UNPROVED` appears nowhere in a `--cost` report. The report now lists every
  imported result-size annotation and says "UNPROVED (no result-size lemma;
  annotation is not used)" for the three in `std/list` it cannot verify
  independently (`sortBy`, `sortWith`, `unique`). Those lines are left out of
  the assertion; a real unproved or over-budget bound still fails it.
- `examples/ideal/measure.fpr`: `factGo` declared `work <= 5 * n + 5`, false
  for negative `n`, and the checker refuses it over the signed domain. The
  bound is `5 * max 0 n + 5`; `fact` still proves `5 * n + 6` from its own
  `n >= 0`.
- `tests/check_typed_units.py` expected unit names to carry `ccore2-`; the
  Core cache identity has been `core4-` since `5e4f248`. It now accepts any
  version.

Still red, each needing a decision or an investigation:

| Job | Failure |
|---|---|
| `examples/ideal/check.py` (`transitions.fpr`) | `update` declares `work <= 25`, derived 29. Why the cost grew by 4 is not known. |
| `examples/ideal/check.py` (`pipeline.fpr`) | `total = xs \|> List.map double \|> List.sum` has no derived bound: `varying-recursive-parameter:$typed_v_2` is opaque, so any declared work bound over `List.sum` fails `--cost`. A regression in cost derivation or a deliberate tightening. |
| `tests/check_x64_scalar.py`, `tests/check_x64_qos.py` | `rotate63`: the stores to hart argument cells 8 and 448 the check expects for the non-looped form are not found. |
| `tests/check_trmc_arc.py` | the `values` program has no `$worker.trmc.` worker with TRMC enabled. |
| `tests/check_trust.py` | `std/fixedmap.fpr`, `std/mutmap.fpr` and `std/vector.fpr` are not on `Safety.approvedLibraries`. An approval, so not added here. |

Also open: the three `std/list` size annotations above are declared and not
used by callers until they have lemmas.

Update, 11 November: both `examples/ideal/check.py` rows are resolved.

- `pipeline.fpr`: the cost pass now proves the recurrence std `map` needs.
  A measured linear recursion whose accumulator is consed onto at every step
  is charged as (steps) x (its recursive paths) plus its exit path once, at
  the accumulator's grown length (`Cost.exitSplit`), so `mapGo`'s final
  `reverse acc` is charged once, over all `len xs` cells, instead of as an
  opaque term on every call. The derived bound is `9·len xs + 14·(len xs + 1) + 13`, which is
  `23·len xs + 27`: the declared `19·len xs + 27` had only been proven by
  pricing that reverse at the empty initial accumulator, so it is corrected.
- `transitions.fpr`: the typed erasure reads a record field and updates a
  record through an always-true shape guard (`if` + tag test, then the field
  or the update, else an error), and the cost pass charges the guard's 2 ops.
  `clampMax`/`clampMin` went from 5 to 9 (one read, one update) and `reset`
  from 3 to 5, so `update` is 29 and `replay` 35 per event. The declared
  bounds follow; they were 25 and 31. Not charging guards the type makes
  always-true would need type information the cost pass does not have.

## Results on this host

62 of 72 checks passed before the fixes in items 4 and 5; with them, the
three contract checks and `check_pair_raw.py` pass. Six checks cannot run here and are CI-only evidence:
`check_rv32_float_constants` and `check_fixed_stack_reservation` (no RV32
SoftFloat archive), `check_typed_ir_x64` in both modes (requires native
x86-64, not Rosetta), and `check_rv64_linux` in both modes (no
`riscv64-linux-gnu-gcc`). `check_base` and the Tang Nano steps were not run.
