# Raw data for the 2026-11-14 performance profile

The write-up is [docs/2026-11-14-PERFORMANCE-PROFILE.md](../../2026-11-14-PERFORMANCE-PROFILE.md).

- `raw/times-baseline.json`: the baseline. 5 load-gated, interleaved rounds; FP-RISC plus C/Go/Rust peers.
- `raw/buckets.txt`: time shares (perf cpu-clock) and instruction shares (callgrind), by bucket.
- `raw/callgrind/*.class.txt`: executed instructions in generated code, by class; top functions; call counts.
- `raw/callgrind/csv-charFrom-per-instruction.txt`: per-instruction execution counts for the `charFrom` scan loop.
- `raw/perf/`: perf top symbols, the annotated sim loop, and page-fault sites.
- `raw/experiments/`: the ablation and fix experiments (JSON timings), the app variants that use an accumulator
  `words`/`lines`, and the scratch patch that disables heap release. That patch was used only for the measurement.
