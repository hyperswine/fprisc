# Pi 4B scheduling and memory qualification

The selected reference board ran the codegen-193 ARM64 binaries next to its installed QOS Portable Main session. The Raspberry Pi 4 Model B Rev 1.4 ran Linux 6.6.28-v8 PREEMPT with the powersave governor at 600 MHz. Build inputs have explicit working-tree identities. The candidate bundle, editor compiler, runtime executables, fixtures and device observations are identified by checksums in the [qualification record](../bench/2026-11-05-pi-qos-193.json).

## Scheduling

All 702 executions passed. Of these, 513 ordinary runs timed 256 replies apiece, 171 separate instrumented runs verified actor progress and routing, 16 exercised heap lifetimes, and two deliberately stalled in C to verify watchdog termination. Each positive competitor exhausted fuel inside its probe's measurement window. The ordinary executables had no scheduler probe hook. The full sample set and per-process memory, temperature and clock observations are preserved in the [compressed raw record](../bench/2026-11-05-pi-193-runtime.json.gz).

Across 131,328 ordinary replies the median was 204 µs, p95 was 4,313 µs, p99 was 6,239 µs, and the maximum was 24,561 µs. **24,638 replies exceeded 1 ms.** Each workload and mode contributed 6,912 samples, spanning one and four workers, same-worker and cross-worker delivery, and zero, one or eight competitors. These pooled percentiles describe this balanced experiment. Application latency depends on its actual mix of work.

| Workload | Replies above 1 ms | p99 | Maximum |
| --- | ---: | ---: | ---: |
| Scalar loop | 0 | 412 µs | 940 µs |
| Fused list | 0 | 346 µs | 949 µs |
| List with fusion disabled | 118 | 1,155 µs | 7,038 µs |
| Private unary return | 191 | 1,189 µs | 8,712 µs |
| Boxed unary return | 412 | 1,509 µs | 2,588 µs |
| Guarded helper | 1,991 | 1,990 µs | 3,298 µs |
| Boxed guard-helper comparison | 4,586 | 12,475 µs | 24,561 µs |
| Copy of 4,096 list elements each way | 6,912 | 4,970 µs | 11,423 µs |

Unary returns improved the observed upper percentile while the largest individual delay increased. Every large copy exceeded the threshold. Any application claiming a 1 ms response needs an enforceable bound on copying and other work between yields. A finite run on the Linux scheduler cannot establish a worst-case time bound.

## Memory and QOS

At both one and four workers the isolated heap probe reported **25,157 allocation requests with boxed results and 16,772 with private unary returns**. All 8,385 removable wrappers disappeared. Real list payloads and shared actor-message fields retained their expected values after allocation churn and region exits.

The Pi's editor SDK compiled a 203,537-byte QAR2 plugin and refused invalid source. The complete SDK self-test took 98.18 s and peaked at 142,976 KiB RSS. Main discovered ten shortcuts, including all six onboard plugins. The first test driver expected an older eight-shortcut disk. Its readiness check timed out after the shell had booted. The corrected check derives the expected count from the Main profile and accepts an explicit count for historical disks.

The production-entry Main candidate ran Files, Logs and Browser on real V3D graphics using isolated input and a separate SD-backed disk. The installed desktop kept its original PID and executable. Normal quit drained storage, and a separate boot shut down on SIGTERM. The allocator-enabled Main workload has its own entries in the evidence record. These sampled workloads complement the separate RV64 fixed-arena proofs. Admission of an arbitrary Main application still requires a proved upper bound on its live memory and stack.

The allocator probe ran 16 UI cycles on one worker and 17 on four workers,
for 155.4 s and 156.5 s respectively. After three warmup cycles, both probes
reported **38,400–38,592 KiB reserved** within a configured 256 MiB arena
and **17–19 ARC roots**. Sampled process RSS grew from 43,344 to 45,048 KiB
on one worker and from 43,660 to 45,480 KiB on four. Reserved allocator
storage and resident process pages measure different costs. Both probes
completed the normal storage-draining quit and a second boot with signal
shutdown. Final device readback showed the original installed PID 17227,
zero restarts, the original executable hash and 62,176 KiB free on the root
filesystem.
