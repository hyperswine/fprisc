# QOS A64 apps lost d8..d15 across a park (qsysfail check 12)

The QOS pin trial to 43f02dc (QOS `docs/2026-11-05-FPRISC-PIN-TRIAL-43F02DC.md`,
branch `fprisc-pin-trial-43f02dc`) was a no-go on one new compiler-side failure.
QOS `tests/qsysfail.fpr` check 12 failed at `FPR_HARTS=4` on QOS Portable in
about 80% of runs. The files manager trapped in std/storage `spawnOn` with
`storage actor admission: <9005.0>`. 64 holders each opened a file and ended,
and then the 65th open failed. The trap was first seen with fprisc a7f4fd6 paired
with QOS 6a273c6.

## It was not an admission refusal

`Sys.spawnInbox` admitted the actor and built `Ok actor`. That result's header
word was then overwritten with 0 before the caller read it. The generated
`case` in `spawnOn` loads the 64-bit header and compares it with 3
(`T_RESULT`, variant 0). Any other value takes the `Err` arm with the field at
+8 as `why`. That field was the new actor, so the message printed the actor's
header: 9005 is `T_ACTOR`, and `.0`/`.1` is its scheduling state. The "second
defect" in the trial record (an actor as the Err reason) is the same fault. The
runtime never returned a malformed refusal.

## Cause

On AArch64, `machine/unix/ctx_a64.S` skipped `d8..d15` when built with
`FPR_QOSAPP`, and `FPR_CTX_WORDS` was 16 for QOS apps. The hosted build has saved
them since 98abc0c. The reasoning was that "the runtime's switch paths do no FP".
That reasoning does not hold. AAPCS64 makes `d8..d15` callee-saved, and clang
uses them for integer values in C that has no floating point at all.

a7f4fd6 added an early `r->tid = T_RESULT; r->var = 0;` to `a_spawn_inbox` and
`a_spawn_heap`. The same 64-bit constant is written again after the
reservations, so clang kept it in `d8` across the calls in between. Those calls
can park the spawner: the stack block and the slabs come from the memory actor.
At 4 harts the spawner can resume on another hart. Its `d8` was then that hart's
leftover value, often 0, and `str d8, [x8]` wrote it as the result header. At 1
hart this happened much less often. Waiting longer or rolling back an `FPR_NO_*`
pass made no difference, because the fault is in the runtime's C, not the
generated code. `FPR_COMPACT_CELLS=0` did not help either: the early store is
there in both layouts.

## How it was found

These were debug-only hooks, kept in no commit. The first hook logged every
`a_spawn_inbox` result. Failing spawns had header word 0 with the payload and
slab word intact, and the spawner had moved harts during the call. Watching
`free_block`, `allocation_header`, the buddy and every actor's stack, channel,
charge, ring and slab ranges found no other owner of that address. Making the
page read-only during the ship and a spin showed no foreign writer. Checks after
every admission step showed the header intact until the final three stores. The
disassembly of those stores showed `str d8`.

## Fix

- `machine/unix/ctx_a64.S` saves and restores `d8..d15` in every context,
  QOS apps included. Slots 16..23 hold them, as in the hosted layout.
- `runtime/fpr.h`: `FPR_CTX_WORDS` is 24 for every `FPR_POSIX` AArch64 build.
  QOS A64 apps get their own `FPR_NATIVE_ABI` numbers: 11 for the legacy layout
  and 12 for compact cells. Their hart and acb layouts changed. QOS RV64 native
  processes keep 8 and 9, and QOS's `tools/native-abis.py` reads the RV64 values.
- `tools/bench-a64-context.py` measures the old integer-only sequence through
  `FPR_CTX_A64_BENCH_INTEGER`. That is a measurement switch, and no build sets it.
  The script used to get that sequence from `FPR_QOSAPP`.

Other targets: the x86-64 SysV ABI has no callee-saved vector registers.
Linux RV64 already saves `fs0..fs11`. Bare-metal RV64 and QOS RV64 processes
use the integer `lp64` ABI. ESP-IDF has its own layout.

## Test

`tests/check_ctx_a64_fp.py` is registered in Base. It reduces check 12 at 4
harts with `tests/ctx_a64_fp.c` and `tests/ctx_a64_fp.S`: one context sets
`d8..d15`, parks, and is resumed by the next of 4 threads. Each thread enters
with its own `d8..d15`. This repeats 1000 times. The check builds the switch as
hosted builds use it and as QOS apps use it (`-DFPR_POSIX -DFPR_QOSAPP`), and it
requires every register to survive. It requires the integer-only sequence to
lose them, so the check cannot pass vacuously. It also checks the
`FPR_CTX_WORDS` and `FPR_NATIVE_ABI` values that `runtime/fpr.h` selects. Built
against 43f02dc's `ctx_a64.S`, the QOS-app variant loses all 8000 registers
(exit 100).

## Results (QOS 19e15cf, Portable, `FPR_HARTS=4`)

| fprisc | qsysfail runs | check 12 |
|---|---|---|
| 43f02dc (the trial's matrix, all configurations) | 23 of 70 passed | 47 failures, every one the manager trap |
| this branch | 10 of 10 passed | passed in every run |

The runner is QOS's `docs/evidence/2026-11-05-fprisc-pin-trial-43f02dc/qsysfail-runner.sh`.
QOS's `tools/storage-reliability-check.py` (the trial's "Storage deadlines"
leg: storagedeadlines, storagebudgets, storerpc, qsysfail, filesreclaim and
filepolicy, each at 1 and 4 harts) passed 3 of 3 times on this branch.

Not caused by this change: `tests/check_x64_qos.py` fails the same way on
untouched main (a `rotate63` store assertion in `check_x64_scalar.py`).

## Open

- QOS's lock still pins 1a09f01. A rerun of the pin trial on this fix (and a QOS
  commit whose system.fpr compiles) is the next step on the QOS side.
- The fixed-x28 contract in `ctx_a64.S` is unchanged.
