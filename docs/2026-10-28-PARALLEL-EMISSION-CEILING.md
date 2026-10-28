# Parallel unit emission: the measured ceiling

Date: 2026-10-28. Kind: measurement and decision (no code change).
[The compile-time budget](2026-10-26-COMPILE-TIME-BUDGET.md) lists "the
compiler runs single-threaded (no `-N`), and units are emitted one after
another" as the larger, separate item.
[The compile-speed analysis](2026-10-27-COMPILE-SPEED.md) then bound the
emission share itself; this page re-measures that bound on the current
compiler before building anything.

## Measurement

The largest build available: `qos/programs/main.fpr --target=qa64`, 38
dependency units + prelude + root (49 unit files). Cold = fresh output
directory; warm = every unit `(cached)`; emission = cold − warm, the same
method as the compile-speed analysis. Paired runs in
`bench/2026-10-28-parallel-emission-ceiling.json`:

- cold 64.36 s wall / 48.10 s user; warm 57.79 s wall / 44.45 s user →
  **emission ≈ 6.6 s wall (10%), 3.7 s CPU (8%)**. (A first pair ran during
  a load spike and was discarded.)
- warm rebuild with `+RTS -N4`: 58.33 s — the threaded RTS's parallel GC
  does not help the sequential pipeline at all (57.79 s with `-N1`).

So perfect parallel emission — zero cost, impossible — saves at most ~8% of
wall time on the largest cold build in either repository. Warm rebuilds
(the developer's common case: the loop does one `doesFileExist` per unit)
and single-unit programs (the whole bench suite, most user code) gain
nothing. The suite's own compile time would not move either: `check_base`
already parallelizes *across* builds with its idle-core worker pool.

## Decision: deferred

The win does not cover what the change costs. Parallel emission means a
capability pool around the unit loop, and with it: a thread-safety audit of
the shared lazily-forced linked structures every unit reads, per-capability
nursery memory on top of a 1.1 GB residency, `error`/`exitFailure`
propagation semantics out of worker threads, and deterministic ordering of
every diagnostic the loop prints today. All of that is buildable — the
binary already links the threaded RTS with `-rtsopts`, and an
`FPR_EMIT_JOBS`-gated pooled map is a small patch — but it buys ≤8% on one
build shape and 0% everywhere else.

The compile-time item that actually matters is sequential and algorithmic:
the pre-cache whole-program pipeline is ~90% of the cold build
([compile-speed §2](2026-10-27-COMPILE-SPEED.md): the 39× whole-program
`Cost.costProgram` fixpoint inside `Regions.place` and friends). That is
where the next compile-time order of magnitude lives, and no capability
count touches it.

Revisit trigger: a project whose unit count makes emission a larger share
than qos's ~10%, or a pre-cache pipeline cheap enough that emission becomes
the tail.
