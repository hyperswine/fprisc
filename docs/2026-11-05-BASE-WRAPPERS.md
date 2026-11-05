# One-field Base workers

Codegen 174 extends the existing guarded field-worker convention to one-field
constructors and let-bound one-field seeds. A recursive `Cell Int` accumulator
can now travel as its payload through a private loop. Public entries keep their
original arity, nominal shape guard and fallback body. A whole wrapper returned
at an ordinary boundary is reconstructed there.

This is Base allocation removal using the existing guarded worker mechanism.
It does not enable the rejected eager type-instantiation experiment, change
the public value ABI, or establish Base-wide canonical type representations.

## Why both exclusions mattered

Worker selection previously required at least two fields. Relaxing that to
one removes the ordinary wrapper loop's constructor cells. Let-bound seed
exposure had its own two-field minimum, however, so an inlined nested wrapper
still allocated once per iteration. Removing that exclusion lets successive
existing worker rounds expose both layers.

Seed exposure binds payload expressions at their original evaluation point
before intervening effects. It substitutes only a fresh constructor used as a
selected call argument. Payload evaluation, failure and fuel calls stay in
order. The existing shadowing, projection-bound, whole-value-use, native-arity,
body-growth and vector-callback exclusions continue to apply. Nullary cells
remain outside this pass.

The field remains an ordinary Base value. Strings and lists therefore retain
their existing region/lifetime behavior; this is not a new raw-pointer or ARC
ownership convention. The existing `FPR_NO_FIELD_WORKERS=1` switch rolls the
change back, and `FPR_NO_TUPLE_SCALARS=1` still controls the broader seed/return
handling. The underlying worker pass retains its existing bounded admission
policy, separate from C2 type-specialization admission.

## Validation scope

`tests/check_base_wrappers.py` compares enabled and disabled workers against
an explicit scalar loop. Constructor-count checks isolate region adapter
allocations; a second set runs with normal region placement and one/four
runtime workers. It covers returned wrappers, strings, heap lists, nested
wrappers, singleton records, Bool/F64 payloads and a different constructor
variant through the original fallback. A separate imported module retains its
ordinary tagged entry.

The failure differentials check both Int overflow limits, division by zero,
strict evaluation of an unused seed and the exact printed prefix before
failure. Successful loops also reach both Int limits without trapping.
Worker unit checks cover one-field parameter/result handling, projection
bounds and payload evaluation before intervening effects. This suite is
registered in Base and the host-extra CI group.

Benchmarking uses normal compiler/runtime settings and an explicit scalar
twin. Its boxed control disables field workers; all other compiler settings
remain at their defaults. Allocation probes and timing executables are separate. Every timed run
checks its result and exit status, with alternating execution order and an
untimed warmup. These are native-host throughput measurements, not scheduling
latency, hardware WCET or static-arena qualification.

## Results

The [native arm64 record](../bench/2026-11-05-base-wrappers.json) reports these
isolated allocation counts for 1,000 steps:

| Workload | Field workers disabled | Enabled |
| --- | ---: | ---: |
| Int wrapper / singleton record / Bool wrapper | 1,001 | 0 |
| Two nested wrappers | 2,002 | 0 |
| Returned wrapper | 1,001 | 1 |
| String payload | 1,001 | 0 |
| Heap-list payload | 1,003 | 2 |
| F64 payload, including output formatting | 1,002 | 1 |
| Explicit scalar loop | 0 | 0 |

The returned wrapper and heap-list cells remain real boundary/payload values;
their remaining allocations are expected. The other-variant fallback retains
one allocation in both modes. Successful output agrees in normal region mode
as well as the isolated cost mode.

At **50 million steps**, default-region instrumentation reports
**50,000,003 → 0** allocations, matching the explicit loop's zero. Separate
uninstrumented executables have median times **196.31 → 44.86 ms**, versus
**44.91 ms** for the explicit loop. Enabled workers win **13/13** alternating
comparisons, a 4.38x median speedup on this workload. No other validation jobs
were running during this benchmark.

All 39 Haskell suites passed, with an additional independent machine-IR check
of the new public entry's valid result and wrong nominal/variant fallbacks.
The [validation manifest](../bench/2026-11-05-base-wrapper-validation.json)
records compiler/source hashes, commands and results. Existing worker regressions passed native one/four-worker execution, separate
switches, dynamic/module entry, exact failures, target emission and bounded
fuel segments. The tuple/record scalar-replacement regressions and registry
tests also passed with the new suite included.
The unchanged compiler budget passes at **1.59/32.75/70.35 GB** for
hello/std-live/pos1. The [16–256-helper C2 gate](../bench/2026-11-05-base-wrapper-specialization-cost.json)
retains exact code/function parity and 1.001–1.002x compiler allocations to
explicit twins. These validation cost runs overlapped each other; their wall
times are not throughput comparisons.

Canonical checked Base layouts and generic boundary conversions, broader owned
aggregate support, scheduling response bounds and physical arena admission
remain unfinished roadmap work.

Codegen 187 adds [checked product-parameter plans](2026-11-05-BASE-PRODUCT-PARAMETERS.md)
for nonrecursive Base helpers, with explicit binder and cache evidence.
