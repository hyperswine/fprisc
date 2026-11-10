# Register fuel: the counter in x27 on AArch64

Date: 10 November 2026. Kind: implementation record with measurements.
Branch `register-fuel`, base `38ad9f0`. `codegenRev` 210; `FPR_NATIVE_ABI`
13/14 (hosted A64, plain/compact) and 15/16 (QOS A64 apps).

This is step 4 of the [fixed-costs proposal](2026-11-06-FIXED-COSTS-PROPOSAL.md)
and decision 3 of the [performance priorities](2026-11-09-PERFORMANCE-PRIORITIES.md),
taken on 10 November: the fuel counter lives in a register. AArch64 is done
here. RISC-V (s11, the same register number) and the weighting of a tick by
the work it covers are the next two steps and are not in this change.

## The convention

Fuel was the first word of the hart block. A tick loaded it, subtracted,
stored it back and compared: five instructions and a loop-carried store-load
pair, after a `mov x9, x28` to reach the block.

On AArch64 the counter is now x27, and it follows x28's discipline, which was
already in place for the hart register:

- **Generated code never allocates it.** The allocation budget is x19..x26
  (it was x19..x27), and x27 joins the register file's reserved set.
- **C never touches it.** Every C file that runs on an actor's stack was
  already compiled `-ffixed-x27`, because clang saves x27 and x28 as a pair
  (`runtime/fpr.h`, at the hosted AArch64 `fpr_hart`).
  That flag is now load-bearing for x27 itself.
- **The context switch neither saves nor restores it.** `ctx_a64.S` leaves
  slot 12 unused; `FPR_CTX_WORDS` and every other offset are unchanged.

The third point is what keeps the meaning of fuel exactly as it was. The
memory counter was per hart, not per actor: an actor that parked and resumed
went on with whatever the running hart had left, and the three refills
(`trampoline`, `to_sched` after a resume, `fpr_fuel_exhausted`) wrote the
hart's cell. x27 is per hart thread in the same way, the same three places
refill it through `fpr_fuel_set`, and no tick moved. A program therefore
ticks, yields and resumes at the same points with the same counts as before.

Which copy is authoritative: x27, always, on a hart thread. `hart->fuel`
stays in the block for layout (offset 0 is what RISC-V and x86-64 still
use) and is not read or written on AArch64.

The tick is `subs x27, x27, #n` and `b.gt`, with the existing slow path
(`fpr_fuel_save_local`, then `fpr_fuel_exhausted`). `EntryTick` and `TickN`
no longer read the hart at all.

Boundaries checked against the proposal's list:

| Boundary | State |
|---|---|
| Runtime C called from generated code, and back (`fpr_apply`) | `-ffixed-x27`: the counter passes through untouched in both directions |
| Park, yield, migration to another hart | not in the context; the resuming hart's counter is refilled by `to_sched` as its cell was |
| First activation | `trampoline` refills before `fpr_fn_main` or the actor's entry |
| Stack growth | `fpr_stack_grow` is C; untouched |
| libc and other prebuilt code | AAPCS64 callee-saved: restored before it returns, and it never calls generated code |
| QOS A64 apps and QOS Portable's host | same `ctx_a64.S`, already `-ffixed-x27` (`qos-app.mk`); `appside/entry.c` writes `hart->fuel` once and must use `fpr_fuel_set`. Not done here: it lands with the QOS pin |
| Sol hand JIT (`Sol/HandJIT.hs`) | does not use x27 and is not ticked; unchanged |
| Cached and frozen objects | `codegenRev` 210 and the `FPR_NATIVE_ABI` bump: an object built before this uses x27 as a value register and must not link or load with one built after |

That last row is not hypothetical. Before the revision was bumped, a build
reused prelude units from the old compiler and failed with
`call region: left out of order`.

## Cost

One callee-saved register: eight instead of nine. On the benchmarks below no
function gained a spill that cost more than the tick saved; the register
pressure gates (`check_registers`, `check_typed_ir_native`) will say so for
the corpus once their budget lists are updated.

## Measurements

Apple M4, arm64 macOS, whole process, fastest of 9 interleaved runs (medians
in the data file), each compiler with its own build cache. Baseline is main
at `38ad9f0`.

| Benchmark | Memory fuel ms | Register fuel ms | Ratio |
|---|---:|---:|---:|
| `fib` (35) | 41.1 | 40.1 | 0.977 |
| `byteloop` | 61.4 | 60.8 | 0.990 |
| `sha` | 46.1 | 46.1 | 1.002 |
| `nbody` | 207.0 | 206.7 | 0.999 |
| `pingpong` | 254.8 | 239.0 | 0.938 |
| `strbuild` | 68.4 | 68.5 | 1.001 |
| `list_sum` | 17.5 | 17.4 | 0.996 |
| `list_map` | 17.5 | 17.4 | 0.993 |
| `option_loop` | 39.1 | 39.0 | 0.998 |
| `tree_sum` | 99.9 | 96.5 | 0.966 |
| `loop_sum` | 21.9 | 22.0 | 1.004 |
| `list_filter` | 95.3 | 81.3 | 0.853 |

This is much less than the proposal's hand-edited `fib` row suggested (0.72
to 0.54 with the counter in x27). That row was measured on top of a cleaned
frame and selection, where the tick was a larger share of what remained, and
on this core the load after the store is forwarded and nearly free. The gain
here is where a function ticks several times per iteration (`list_filter`)
or is small and call-heavy.

It should be larger where a load and a store cost what they look like: the
Pi 4's Cortex-A72, x86-64 (which keeps the memory counter, see below) and
above all the RV32 soft core, where the tick is four instructions and two
memory accesses at an IPC near 0.4. None of those is measured yet.

## What this does not do

- **RISC-V.** s11 is x27 on RISC-V and is the intended register. It needs
  `-ffixed-x27` on every RISC-V C build (virt, builtin, Linux, ESP-IDF, QOS
  Native), the same change in `machine/virt/ctx.S`, `machine/unix/ctx_rv64.S`
  and `machine/esp-idf/ctx.S`, and the allocator's `saved` list cut to
  s1..s10. The Tang Nano board and the ESP32-P4 cannot be run from here.
- **x86-64.** It has five callee-saved registers and its two allocator
  scratches are already contended (see item 9 of the
  [CI baseline](2026-11-10-CI-GREEN-BASELINE.md)). It keeps the memory
  counter.
- **Weighting.** A tick still charges one unit per function entry or loop
  iteration, whatever the size of the code it covers. Charging by block size
  is the next step and changes what a quantum means; it is a separate change.
- **QOS.** The pin, `appside/entry.c` and the pairing sweep.

## Tests changed

- `tests/check_typed_ir_a64_frames.py`: the oracle seeded x19..x28 with
  sentinels and checked them back. x27 is now seeded with one unit of fuel
  and refilled by the oracle's tick hook, so every tick is still hostile.
- `tests/check_ctx_a64_fp.py`: ABI numbers; its C is built `-ffixed-x27`
  like every file that switches contexts.
- Fuel probes written in C (`tests/base/selfloops_probe.c`, `fp_pool.c`,
  `vecfuel.c`, `tests/typed_ir/actor_frames.c`, `runtime_reserve.c` and the
  one inside `tests/check_fixed_stack_reservation.py`) wrote `hart->fuel`.
  They use `fpr_fuel_set` and `fpr_fuel_left`, which are the hart cell on
  the other targets. `check_self_loops.py` caught the first: its exact tick
  count read 0 used of 1,000,000.
- `machine/builtin/contracts/rv64-c-heap-v1.json`: `runtime/fpr.h` hash. The
  header gained the two accessors and the A64 ABI numbers; nothing in the
  RV64 builtin heap.

## Verification

On the Mac (arm64), each run with its own build cache:

- The `native`, `riscv` and `host-extra` groups of `tests/check_ci.py`: the
  only failures are the ones this host cannot run (`check_typed_ir_x64` in
  both modes, `check_rv64_linux`).
- `make unit-tests`: pass.
- `check_base`, run with each failing job set aside until the rest passed:
  218 jobs pass. Set aside were the six already red on main (see the
  [CI baseline](2026-11-10-CI-GREEN-BASELINE.md)) and
  `check_pos_core.py`, whose compile timed out beside five other cold
  builds and which passes alone.
- Three oracles that link generated A64 code against their own C
  (`check_float_trees.py`, `check_captured_simd.py`, `check_a64_fp_pool.py`)
  were built `-ffixed-x28` only. Their C kept values in x27 across calls
  into generated code, which now spends it. They are built `-ffixed-x27`,
  and the two oracle sources seed, refill and read the counter through x27
  on AArch64.

Not verified: Linux AArch64 (the Pi), QOS, and anything on x86-64 or RISC-V
beyond their unchanged emission.
