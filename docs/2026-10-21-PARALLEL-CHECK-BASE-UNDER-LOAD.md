# check_base in parallel on a loaded machine: one worker per idle core

Date: 2026-10-21 (evening). Kind: failure record and fix. Base: main at
`d85ec9f` (which merged [the parallel runner](2026-10-21-PARALLEL-CHECK-BASE.md)
on top of `4696b6a` and two later commits), branch `parallel-check-base`.
Same Apple M4: 10 cores (4 performance, 6 efficiency), 16 GiB.

## The failure

After the merge, `python3 tests/check_base.py` failed twice in a row at
`examples/ideal/check.py`. A `fpr build examples/ideal/todo.fpr --cost`
hit that script's own 90 s timeout for a single command. The same build
takes 18 s on its own.

## What it was not

- **Nothing new on main.** Between the green runs (`a556647`) and
  `d85ec9f`, the compiler changed by two allow-list lines in `Safety.hs`.
  The runtime changed only in list equality (`veq`), plus two new std
  modules. The failing build and the programs that later timed out use
  none of it.
- **No cache lock.** No cache takes a lock. The unit cache is now written
  atomically (`66e358d`), so a concurrent build waits for nothing.

## What it was

The machine was not the one the first runs measured. Other programs
were using it: a Kotlin language server (`intellij-server`, 2.6 GB and
growing, 170 % CPU), `kernel_task` at 140 %, WindowServer at 90 %, OBS
recording, VS Code. About six cores were busy before check_base started,
and 11 of the 12 GB of swap were in use. On top of that, ten workers
oversubscribed the cores about threefold and pushed the machine into
paging: about 400,000 swap-outs (about 6.5 GB) during one 4-minute run.

Measured with a per-command log in the ideal check, in that state:

| Command | Alone (load ~22) | Under check_base -j 10 |
|---|---|---|
| `fpr build ideal/wc.fpr --cost` | 4.5 s | 65 s |
| `fpr build ideal/todo.fpr --cost` | 18 s | over 90 s (the guard) |

With the ideal check's guard raised, the next guard fired instead:
`check_mvu_reload.py` runs `mvuscoped` with a 120 s limit. Alone it
takes 51 s of wall time on 10 s of CPU. It is a 20,000-frame actor
ping-pong whose time is mostly wake-up latency, and that latency grows
with oversubscription.

So the hang guards in the sub-checks hold for a machine whose cores
check_base has to itself, as in the first runs (load ~3: every job
stretched about 1.4x). They do not hold when other programs already use
half the cores.

The load average is no measure of this on macOS: it read 22 to 25 while
`top` showed about six cores busy.

## The fix

- `check_base.py` samples idle CPU for 2 s before `make fpr`: `/proc/stat`
  on Linux, `top -l 2` on macOS. The default worker count is the number of
  idle cores, rounded, at least 1 and at most the core count. It says so
  on stderr: `check_base: 4.3 of 10 cores idle: 4 worker(s)`. `-j N`,
  `FPR_CHECK_JOBS` and `--serial` choose as before.
- `examples/ideal/check.py`: its per-command guard goes from 90 s to
  300 s. It is a hang guard, and 90 s against an 18 s build was the
  smallest margin in the run. check_base's own builds get 120 s for 3 to
  10 s of work.

## Runs on `d85ec9f` plus the fix, same loaded machine

| Run | Idle at start | Workers | Wall | Outcome |
|---|---|---|---|---|
| -j 10, guard 90 s (before the fix) | | 10 | 239 s | FAILED: ideal, todo build at its 90 s guard |
| -j 10, ideal guard 300 s | | 10 | 206 s | FAILED: mvu_reload, `mvuscoped` at its 120 s guard |
| default sizing, run 1 | 4.4 of 10 | 4 | 371 s | pass |
| default sizing, run 2 (right after) | 5.9 of 10 | 6 | 247 s | pass |

The two green runs' stdout is identical. It differs from this morning's
serial baseline in one line, the count in `check_trust` (94 to 96 std
modules, from the two modules `bedbb6a` added). On a quiet machine the
sample should give about ten workers, as in the first runs (about
185 s). That is not re-measured here: the machine stayed loaded.

## Open

- Memory is not in the sizing. Idle CPU tracks the observed case, because
  the programs that took the memory also took the cores. A machine with
  idle cores and full memory would still page.
- The guards in the sub-checks are fixed numbers of seconds. A
  `FPR_TIMEOUT_SCALE` that every check honours would make them
  proportional to the machine. That touches most of the 46 scripts.
