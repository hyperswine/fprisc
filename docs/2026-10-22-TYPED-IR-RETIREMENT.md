# Can the legacy path be retired? An inventory, and the steps taken

Date: 2026-10-22. Kind: assessment and implementation record.
Base: main `e243970` (the [QOS work](2026-10-22-TYPED-IR-QOS.md)).
Branch `typed-ir-retire`.

Update after `8a5de33`: [typed scalar and fused column kernels](2026-10-22-TYPED-COLUMN-KERNELS.md)
now replace part of the legacy kernel emitter across all four direct targets.
Update after `6951653`: [record/SoA map, filter and fold](2026-10-22-TYPED-RECORD-KERNELS.md)
also lower through the typed CFG on supported numeric layouts.
Update after `12b7d24`: [the remaining kernel forms](2026-10-22-TYPED-KERNELS-COMPLETE.md)
(`mapAs`, write-back folds, F32, NEON, RVV, the GPU hook) lower too: the
fused-kernel row below has no legacy consumer left on the hosted targets.
Update after that: [the typed backend is the default](2026-10-22-TYPED-IR-DEFAULT.md),
with `FPR_TYPED_IR_BACKEND=legacy` as the rollback; the answer below's first
two conditions are met, and the translators now serve only the rollback and
the x86-64 QOS apps.

The [complete migration goal](2026-10-23-TYPED-IR-COMPLETION.md) now includes
replacing builtin/GC/ARC consumers and deleting the remaining generator.

The tables below describe the inventory at `8a5de33`; the linked record gives
the current support boundary and the user-approved retirement acceptance.

Update: [A64 has now been retired](2026-10-22-A64-RETIREMENT.md), following
a fresh full default Base and QOS sweep. The inventory below is historical;
[x64 retirement](2026-10-23-X64-RETIREMENT.md) then adds typed QOS x86-64
access and removes `X64.hs` too. The RISC-V generator retains its remaining
consumers.

"The legacy path" is two things with very different futures.

- **The translators**, `compiler/A64.hs` and `compiler/X64.hs` (about 1,040
  lines), turn the generator's RISC-V text into AArch64 and x86-64. This
  project set out to replace them ([plan](2026-10-20-TYPED-NATIVE-IR-PLAN.md)).
- **The RISC-V text generator** in `compiler/Codegen.hs` (most of its 4,500
  lines), with `Peephole.hs` and `RV64.hs`. On RISC-V targets it is not a
  translation at all: it is the native backend, and for several profiles
  the only one.

## What this branch did

1. **The last function-level fallback is gone.** In-place constructor reuse
   (`$reuse.fresh`, the legacy `# reuse fresh constructor`) lowers to a new
   operation, `OReuse`: every field is evaluated, then stored into the
   uniquely owned object, which is the result. Its effect class, `Writes`,
   keeps the simplifier from moving, merging or dropping it.
   `tests/check_reuse.py` with the backend on, in strict mode: every
   function native, exactly 10,000 allocations with reuse and 20,000
   without, 1 and 4 harts, the failure order unchanged.
2. **Translation-free units.** A unit with no legacy function and no
   vector kernel now emits its data (function-value objects, the module
   table, strings, floats, nullary objects, the constructor table) in the
   target's own spelling (`Common.dataSyntax`: identity for ELF; for Mach-O
   exactly the legacy translator's data rules) and is never translated. Its
   assembly starts `# typed IR: no translation`.
3. **Loaded posix modules under the backend.** A module (`--module`, live
   reload) reaches external symbols through the GOT; the legacy PIC pass
   (`posixPic`) ran only over translated text. It now also runs over the
   typed text and translation-free units (it works on target syntax and
   leaves its own output alone). Found by running the whole Base suite with
   the backend on (`check_pos_reload.py`, a live module's link).
4. **ESP-IDF stays on the legacy generator.** An ESP-IDF host reads its hart
   from `fpr_esp_hart`, which the typed RISC-V backend does not know, so the
   backend is no longer selected for `--host=esp-idf` (`rvSelectionRev` 6).
   With the backend on, ESP-IDF output is byte-identical to legacy.
5. **The legacy-text test sweep, for the Base suite.** Run with the backend
   on for every build, without stopping at the first failure, the Base
   suite had twelve scripts that read legacy text or test legacy-only
   switches. Each now names the legacy backend (drops
   `FPR_TYPED_IR_BACKEND`) at the narrowest point, so its behaviour checks
   still run under whichever backend is selected:

   | Script | What is legacy | Pinned |
   |---|---|---|
   | `check_reuse` | the `# reuse fresh constructor` marker | the marker assertion |
   | `check_workers` | `li a1, 1` at a worker call (no staging) | that compile |
   | `check_a64_guards` | `FPR_A64_FIT_GUARDS` (`sbfx`); the typed overflow check happens to use the same line | the text compiles |
   | `check_a64_frame_pairs` | `FPR_A64_FRAME_PAIRS` | the script |
   | `check_self_loops` | `FPR_SELF_LOOPS`, and an exact tick count that includes a legacy uninlined `Unit` entry (typed: one entry fewer; values, stack, effects and fairness agree) | the script |
   | `check_self_loop_x64`, `check_self_loop_rv64` | the legacy self-loop label in lifted text | the script |
   | `check_retained_registers` | `FPR_RETAINED_REGISTERS` | the script |
   | `check_frame_placement` | `FPR_COMPACT_FRAMES` | the script |
   | `check_consuming_reuse` | the `# private consuming workers` marker | the marker compiles |
   | `check_wide_params` | `mv sN, a6` promotion markers | the text compiles |
   | `check_registers` | promotion markers, and a legacy body lifted into a C harness | those compiles |

## Measured

On AArch64 (Mach-O, this Mac), with `FPR_TYPED_IR_BACKEND=mixed`:

| Measure | Result |
|---|---|
| Function compilations across every example, std test and benchmark (cold cache, the per-unit `typed-ir: coverage` lines summed) | 65,900 of 65,904 native; the four are `examples/swarm.fpr`'s uses of the record-vector primitive `Vec.mapAs` (`benchRun`, `records`, `swarmOf`, one lifted function). Before this branch, the reuse sites were the other fallbacks |
| Unit and root assembly files across examples, std tests and benchmarks | 1,156 of 1,157 translation-free; the one left is `examples/swarm.fpr`'s root, with its vector kernels and the four functions above |
| fprisc `check_base.py` with the backend on for every build | 105 of 105 jobs, after the sweep below |
| QOS `check-all.sh` with the backend on for every build | every leg passed; two sweeps had timing failures under load, each failed leg passed alone (see Validation) |

## What still keeps each part alive

| Consumer | Needs | Keeps alive | Size of the remaining work |
|---|---|---|---|
| Fused vector kernels (`emitSpecs`: map, filter, fold, write-back fold, record SoA, matrix-vector, pipelines; the unboxed `fpr_ufn_` clones; NEON lanes on A64, RVV on RISC-V) | typed kernels in the IR, with vector operations, at the legacy kernels' speed | both translators, for any unit with a kernel | the largest item: about 1,000 lines of hand-written kernel text and its NEON forms |
| The default | promotion per target with a rollback switch, and the tests that pin legacy behaviour moved to name the legacy backend explicitly | the translators for every build that does not opt in | the decision; the Base suite's test sweep is done on this branch (twelve scripts, above); scripts outside the Base suite are not swept |
| x86-64 and RISC-V QOS apps (`qx64`, `qrv64`) | done: `qx64` in the [x86-64 retirement](2026-10-23-X64-RETIREMENT.md), `qrv64` in [typed QOS RISC-V apps](2026-10-23-TYPED-QRV64.md) | nothing | 0 (no RISC-V QOS run environment here: emission and QEMU oracles) |
| Builtin and ARC profiles (bare metal, Tang Nano, drivers) | a typed lowering of their ownership, allocator and root contracts | the RISC-V generator | large; a separate project |
| ESP-IDF host (RV32 P4) | done: [typed ESP-IDF](2026-10-23-TYPED-QRV64.md) (QEMU oracle; the board not run) | nothing | 0 |
| RISC-V posix modules (`--module` on rv64) | done: [typed RV64 modules](2026-10-23-TYPED-RV64-MODULES.md) | nothing | 0 |
| Legacy opt-in modes (self loops, retained and costed registers, compact frames, frame pairs, fit guards), `Peephole.hs`, the `# wcet:` bound | nothing: they exist only for legacy emission | themselves | retire with the generator's users; QOS documents the `# wcet:` metric, and its admission contract needs the native metric's migration first |

## The answer today

- **The translators can be retired for hosted AArch64 and x86-64 and for
  QOS AArch64 apps** once three things land: typed vector kernels, the
  default promotion (the Base suite's test sweep is done here), and (for
  `X64.hs`) x86-64 QOS apps. Nothing else in the inventory uses them.
  Retiring a translator also retires its legacy-only switches (fit guards,
  frame pairs, self loops, retained and costed registers, compact frames)
  on that target, and the target legs of the twelve pinned scripts with
  them; their RISC-V legs stay.
- **The RISC-V text generator cannot be retired soon.** It is the only
  backend for the builtin and ARC profiles, the ESP-IDF host and RISC-V
  modules, and the typed IR has no lowering for those contracts yet.
- **Recommended order:** typed vector kernels (the long pole, and a
  performance gate: they must match NEON); then promote the default on
  AArch64 hosted and QOS, with an explicit legacy value as the rollback
  (today the switch accepts only `1` and `mixed`, and unset means legacy);
  then retire `A64.hs`. x86-64 follows with its QOS
  apps and a native timing run.

## Validation (this Mac, arm64; QOS `587fdb1` worktree)

- **fprisc `check_base.py`**: 105 of 105 legacy; 105 of 105 with
  `FPR_TYPED_IR_BACKEND=mixed`. Finding the twelve legacy-text scripts
  took a driver that runs every job without stopping at the first failure;
  `check_base` stops at the first, which is how earlier typed sweeps
  missed all but one of them.
- **A race in the suite, fixed:** `check_typed_ir_a64.py` and
  `check_typed_ir_x64.py` (no shared lock) both compiled their GHC unit
  tests into `build/ghc-tests` and could collide on `Main.o`. Each backend
  now has its own directory; the two pass when run at the same time.
- **Focused, each legacy and typed:** `check_workers`, `check_reuse`,
  `check_typed_ir_rv`, `check_typed_ir_a64`, `check_typed_ir_coverage`,
  `check_posix_modules`, `check_pos_reload`, and every pinned script.
- **ESP-IDF:** `machine/esp-idf/examples/console.fpr` compiled with
  `--host=esp-idf --target=rv32` is byte-identical with the backend unset
  and set. Not run on the board.
- **QOS `check-all.sh` with `FPR_TYPED_IR_BACKEND=mixed`**, against this
  compiler. First sweep (load average about 9, Spotlight indexing): five
  legs failed on timing (a block request timeout, a socket receive
  timeout, a missing capture, a shutdown, an owner deadline). Each passed
  alone: Qlog routing (108 s), liveboard, Graphics.qa, Main Profile
  (547 s), preferences. Second sweep, started right after the Base runs
  (load about 9): 161 of 162; the one, the two-app disk leg, printed
  nothing within its 60 s boot timeout, and passed 3 of 3 alone (13 to
  14 s each). So every leg passed with this compiler; no sweep was fully
  green in one run, and the cause of the timing failures is load, judged
  by those reruns, not shown by a quiet-machine sweep.

Not verified: CI (dispatched with the commit), native x86-64 and RISC-V
Linux (CI's legs), the ESP32-P4 board, QOS on a Pi, and performance (no
timing taken; translation-free units change only data spelling and the
removal of the legacy pass over them).
