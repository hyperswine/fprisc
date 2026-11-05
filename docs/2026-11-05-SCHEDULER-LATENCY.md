# Competing-actor latency qualification

The codegen-174 compiler now has a repeatable native-host qualification for
request/reply latency under CPU competition. This establishes measured
behavior and exercised preemption. It does **not** establish a maximum slot
time, a hard deadline, hardware WCET or static-arena admission.

## What the test proves

`tests/check_scheduler_latency.py` builds scalar, one-field wrapper,
four-field product and list-reduction competitors. Controls disable field
workers, list fusion or tick batching. A further workload copies a
4,096-element list in both directions through the actor message runtime and
checks its length and sum after each reply.

Each competitor finishes 10,000 steps before sending its ready message,
then continues CPU work without explicit yields. The parent waits for all
ready messages and warms up the responder before opening the measured
window. An independent instrumented execution must show **every competitor
exhausting fuel and completing a dispatch slot inside that window**. A ready
message alone cannot satisfy this check. The runtime fuel quantum is 2,000.

The matrix has zero, one and eight competitors, with one hart, four harts
and a local responder, or four harts and a responder on hart 1. The parent
is pinned to hart 0. Local competitors are pinned to hart 0; remote-case
competitors alternate between harts 0 and 1. Probe dispatch masks verify
the parent/responder placement and competitor pinning. Receive spinning is
explicitly disabled with `FPR_BLOCK_SPIN_NS=0`, so these results qualify the
parking path rather than claiming coverage of every spin policy.

Ordinary-runtime executions separately measure `Sys.timeUs` around each
send/receive pair. Reply checking and output happen outside that interval;
output is deferred until the window closes and competitors are stopped.
Both instrumented and ordinary runs verify every reply and the accumulated
checksum. All executables are built before measurement starts. No other
validation jobs were running during the recorded timing run.

## Probe contract

`runtime/sched_probe.h` supplies three compile-time hooks: dispatch, return
and fuel exhaustion. Ordinary builds expand them to nothing and have no
observer state, clocks or branches. The harness checks that their callback
symbol is absent from each ordinary executable. Instrumented builds use a
distinct compiler wrapper/cache key with `FPR_SCHED_PROBE` defined for both
the runtime and fixture HAL; a final-link-only `--cflag` would not instrument
the cached runtime.

The observer in `tests/base/scheduler_probe.c` uses fixed per-actor counters,
an owner-hart dispatch timestamp, monotonic clocks and atomics. It does not
allocate, print or enter the actor runtime from a hook. It refuses out-of-range
actor/hart identities rather than silently dropping observations. A return
is observed before the scheduler releases the actor's running flag, so a
migrating actor cannot have two active slots at once.

Only completed slots starting after the begin marker and admitted before
the end closes observation contribute duration samples. Fuel events use
the same admission window. End waits for already-admitted observer updates
before a stable report is read. Boundary-straddling slots are excluded;
fuel events and slot counts therefore need not match. Reported slot maxima
include probe overhead and host scheduling effects. They are diagnostic
samples, **not uninstrumented `T_slot` bounds**. Per-actor fuel evidence applies
to instrumented executions; ordinary executions use the same source and
warmup protocol without those counters.

## Recorded results

The [native macOS arm64 record](../bench/2026-11-05-scheduler-latency.json)
covers **81 configurations**, each with one probe run and three ordinary
runs of 1,000 replies: **243,000 ordinary reply samples**. These observations
show how removing allocations affects a competing actor, separately from
single-loop throughput. The following rows use one hart and eight competitors:

| Competitor | Median reply | p99 reply | Largest sampled reply |
| --- | ---: | ---: | ---: |
| Scalar loop | 10 µs | 11 µs | 45 µs |
| Wrapper, field workers enabled | 10 µs | 14 µs | 69 µs |
| Wrapper, field workers disabled | 21 µs | 36 µs | 144 µs |
| Four-field product, workers enabled | 16 µs | 33 µs | 85 µs |
| Four-field product, workers disabled | 36 µs | 89 µs | 166 µs |
| Fused list reduction | 10 µs | 25 µs | 68 µs |
| Unfused list reduction | 19 µs | 44 µs | 123 µs |
| Fused list reduction, tick batching disabled | 5 µs | 6 µs | 34 µs |
| Scalar loop with large request/reply copies | 149 µs | 233 µs | 351 µs |

The unbatched list result exposes a real throughput/responsiveness tradeoff:
retaining more fuel checks yields more frequently. The harness verifies that
the rollback changes emitted fuel call sites (615 to 806 over the RV64 linked
closure), so this is not merely setting an inactive switch. These runs were
grouped by configuration rather than randomized paired timing experiments;
the table is an observation, not a statistical speedup guarantee.

Across the final matrix, no reply exceeded the observational 1,000 µs
threshold; the largest was **666 µs**, with a large cross-hart copy and no
competitors. An [earlier inspected summary](../bench/2026-11-05-scheduler-latency-exploratory-summary.json)
had **eight exceedances and a 2,651 µs maximum**, with one competitor in
the worst case. The earlier raw record was overwritten by this rerun after
tightening probe-close admission, so only its inspected summary is retained.
The ordinary workload/runtime did not change between those runs. Both
observations matter: host outliers vary, and the final maximum must not be
presented as a bound. The threshold is configurable and records exceedances;
it is not an admission limit or a hard-deadline claim.

An intentionally unbounded C entry prints an entry marker and spins without
yielding on hart 0. The same-hart requester then fails to respond. A three-second
host watchdog detects this on both one- and four-hart configurations and kills
and reaps the process. This negative control proves that the harness notices
starvation and demonstrates why unknown C calls cannot enter a time-bounded
subset. It is not a language-level recovery mechanism for such calls.

## Logical bounds and remaining admission work

Each of the nine generated variants also passes the existing
`native-insns-v1` auditor over its root and every linked RV64 assembly unit.
All functions have reports; the largest per-function selected segment is
445 instructions. Field-worker presence and the tick-batching difference
are checked independently. The reports do not compose call/return paths,
bound runtime C duration, or translate instructions into elapsed time.
RV64 here is emission/audit evidence; execution timing is native arm64.

The new suite is registered in Base and host-extra CI. The existing
scheduler-selector/locality and tick-batching suites pass with the ordinary
runtime, and all eight registry tests pass. The
[validation manifest](../bench/2026-11-05-scheduler-latency-validation.json)
binds this qualification to its compiler/runtime/probe/test hashes.

Remaining work before time or static-arena admission:

- Compose selected instruction bounds through calls and returns for an
  explicitly admitted subset, including the actual fuel policy.
- Supply size-dependent bounds or explicit refusal for message copying,
  allocation, queues, locks, foreign calls and other non-preempting runtime work.
- Include scheduler admission/scan costs and all relevant interrupt work.
- Derive physical peak-live heap and stack requirements, including conversion
  graphs, descriptors, scratch buffers and runtime storage, then enforce them.
- Qualify a target timing model and execute the admitted workloads on physical
  hardware before making a hardware WCET claim.

Reproduce the recorded host sample with:

```sh
python3 tests/check_scheduler_latency.py --rounds 1000 --repetitions 3 \
  --record bench/2026-11-05-scheduler-latency.json
```

The default CI invocation uses 128 replies per configuration and one ordinary
run. Its gates are output, exercised preemption, placement, report coverage,
bounded test completion and the negative control, never a noisy latency ceiling.
