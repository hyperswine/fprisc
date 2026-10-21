# check_base in parallel: 1006 s to about 185 s

Date: 2026-10-21. Kind: measurement and change record. Base: FP-RISC
`a556647` (main), branch `parallel-check-base`. Apple M4,
10 cores (4 performance, 6 efficiency), 16 GiB, macOS, Apple clang.

## The question

`tests/check_base.py` ran its checks strictly one after another: `make
fpr`, then 40 sub-check scripts, then about 55 inline cases, each
compiling FP-RISC programs (`fpr build`, generated assembly, clang) and
running them. A full run took 1006 s here (16.8 min). The load average
stayed around 2 on a 10-core machine, so most of the cores sat idle.

## What changed

`check_base.py` is now a list of independent jobs run on a thread pool
(each job's work is subprocesses, so threads are enough):

- `make fpr` runs first, alone, as before.
- Each sub-check script is one job (`script(path, timeout)`).
- Each inline case is one job (`@case def name(tmp)`). The case bodies are
  the old ones, unchanged. Each case builds into its own temporary
  directory, so two cases can never write the same file.
- Each job's stdout is collected and printed whole, in the order the jobs
  are written. Output is not interleaved. On this machine the stdout of
  every parallel run was byte-identical to the serial run's.
- The first job to fail sets an abort flag. Every command `run()` starts
  leads its own process group, so the failure kills what the other jobs
  started (clang, the programs under test). Those jobs are reported as
  stopped, not judged. The failing job is reported by name on stderr, with
  its traceback, and the `run()` failure message still carries the
  command's stdout and stderr. Exit status 1.
- `-j N` or `FPR_CHECK_JOBS=N` sets the worker count (default
  `os.cpu_count()`). `--serial` (that is, `-j 1`) runs one job at a time
  in the written order, without the warm-up or the reordering below.
  `--times` prints the slowest jobs. `--only TEXT` runs the jobs whose name
  contains TEXT.

With more than one worker:

- One `fpr build` of `tests/base/hello.fpr` runs first, alone. It fills
  `~/.cache/fpr` with the compiled prelude unit and the runtime objects.
  Without it, every job would compile those at the same moment.
- The few longest jobs are submitted first (`LONGEST_FIRST`). This made no
  measurable difference today (see below). It is kept because it costs
  nothing, and it stops a long job added late in the list from becoming
  the whole tail.

## What cannot share the machine, and what was done

I read all 46 scripts the run invokes (the 40 at the top plus the six
that inline cases call). For each one I looked for fixed ports, fixed
temporary paths, shared caches, timing assertions and rebuilds of `./fpr`.

| Hazard | Where | Done |
|---|---|---|
| Timing assertion | `check_live_writer_lifetime.py` asserts `1.5 <= elapsed < 4` s for a writer's shutdown | `alone=True`: runs before the pool starts, with nothing else running |
| Shared compiler cache, non-atomic write | `Compile.hs` wrote each cached unit (`~/.cache/fpr/build/units/*.s`) with `writeFile`. A concurrent build checks `doesFileExist`, so it could link a half-written unit as if it were cached. This bites on a cold cache (a new codegen revision or prelude), which is exactly when check_base is run | fixed: `writeWhole` writes a temp file in the same directory and renames it |
| `cabal exec -- runghc` in this checkout | `check_specialization.py`, `check_reuse.py`, `check_workers.py` | `lock='cabal'`: never two at once (they share `dist-newstyle`) |
| Re-running `make fpr` | `check_specialization.py`, `check_float_inline.py`, `tools/runtime-costs.py` | none needed: the serial first step makes `./fpr` current, so their `make fpr` does nothing |
| Ports | `check_live_writer_lifetime`, `examples/ideal`, `check_pos_reload`, the `load.fpr` case | none needed: all bind port 0 and read back the port they were given |
| Temp paths | all of them | none needed: every script uses `tempfile.TemporaryDirectory`, and the inline cases now get one directory each |
| Other caches | `fpr run`'s cache (`~/.cache/fpr/run`), the Sol cache, runtime `.o` files | none needed: the first two write a temp file and rename it, and clang writes its `-o` output through a temp file too |
| CPU-heavy | `taskstress` runs six 10-hart programs at once | none needed: it only asserts outputs (timeouts are 300 s). It slows its neighbours, which is the point of a stress test |

Many scripts also set their own `XDG_CACHE_HOME`, so they never touch
the shared cache.

## Measurements

The serial baseline is the unmodified script at `a556647`. Every parallel
run uses 10 workers. "Load before" is the 1-minute load average when the
run started. Other sessions and macOS daemons were active the whole time:
`mediaanalysisd` at 260 % and Spotlight's `mds` at 120 % were seen during
one A/B round. So spreads of ±15 % are noise.

| Run | Wall | Load before | Outcome |
|---|---|---|---|
| serial, old script | 1006 s (user 668 s, sys 78 s) | 3.5 | pass |
| parallel, written order | 192 s (user 891 s, sys 104 s) | ~3 | pass, stdout identical |
| parallel, longest first | 216 s | 9.2 | pass, identical |
| A/B round 1: written order / longest first | 218 s / 182 s | 5.8 / 5.7 | pass, identical |
| A/B round 2: written order / longest first | 185 s / 185 s | 2.9 / 9.1 | pass, identical |
| serial, new script (`--serial`) | 1008 s | ~3 | pass, identical |

That is about 5.4x faster (1006 s to roughly 185 s). CPU time rises by
about a third (668 to about 890 s user). Part of that is the six
efficiency cores doing work the performance cores did in the serial run.
Part is jobs competing for memory bandwidth and the shared cache
directory.

**The floor is one job.** `examples/ideal/check.py` takes 157 to 202 s
under parallel load, and the run ends shortly after it does: run wall
time minus its time is about 15 to 30 s (`make fpr`, the warm-up, the
`alone` job). The next longest jobs are `check_mvu_reload.py` (139 to
177 s) and `check_pos_reload.py` (109 to 143 s). Run alone (`--serial
--times`), these three take 119 s, 125 s and 71 s, so contention costs
each of them about 1.4x. Each one runs its builds one after another
inside. More workers will not shorten the run. Splitting these three
into parallel parts would: the total work divided over 10 cores is
about 100 s.

## Using it

```
python3 tests/check_base.py            # parallel, one worker per core
python3 tests/check_base.py --serial   # the old behaviour
FPR_CHECK_JOBS=4 python3 tests/check_base.py
python3 tests/check_base.py --only check_trust --only i64 --times
```

CI (`.github/workflows/ci.yml`, `python3 -u tests/check_base.py`) now
runs in parallel on its runner's cores. `-u` still streams: each job's
output appears as soon as it and every job before it has finished.

## Open

- Split `examples/ideal/check.py`, `check_mvu_reload.py` and
  `check_pos_reload.py` into independent parts (or give them their own
  inner pools). Each one alone is now the length of the run.
- Many sub-checks point `XDG_CACHE_HOME` at a fresh temporary directory,
  so they compile the prelude unit and the runtime objects from cold every
  time. Sharing one warm cache, which is now safe to write concurrently,
  would cut CPU time. The catch: some of them isolate the cache on
  purpose ("native cache context is isolated").
- `tests/check_std.py` (about 3.5 min) runs its checks one after another
  in the same way and could use the same runner.
