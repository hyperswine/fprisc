# Private register-product returns

Codegen 170 extends the hosted Base pair-return optimization to wider products.
This removes the returned constructor cell at eligible calls. It is a native
calling-convention foundation for the wider aggregate roadmap; it does **not**
finish deterministic builtin product storage, raw fields, or generic adapters.

## Contract

| Target | Private result fields | Registers | Larger results |
| --- | ---: | --- | --- |
| AArch64 | 2–8 | x0 through x7, in field order | Original tagged entry |
| RV64 | 2–8 | a0 through a7, in field order | Original tagged entry |
| x86-64 | 2 | rax, rdx | Original tagged entry |

This table records codegen 170. Codegen 183 subsequently extends x86-64 to
[eight result words](2026-11-05-X64-PRODUCT-RETURNS.md), with executed backend
and actor-runtime qualification. The earlier measurements below remain tied
to their original compiler.

These are private generated-code conventions, not platform C aggregate ABIs.
Other source profiles, including builtin/ARC/raw, QOS and RV32, retain their
previous admission rules. Every component of these hosted products is still a
runtime value word. Eliminating the container does not unbox its scalar fields.

The original entry remains available. A private `$worker.retN.<function>` is
created only when every successful result has the same nominal constructor,
variant and field count, including through saturated self/mutual tail calls.
Only callers that inspect the known constructor and its fields use that entry.
Escapes, unknown consumers and unsupported widths use the tagged entry. The
existing hosted worker body-size bound is unchanged; it is separate from the
C2 builtin specialization admission policy. `FPR_NO_PAIR_RETURNS=1` rolls back
both pair and wider product workers, and continues to participate in cache keys.

`TProduct n` is a function result contract, never an SSA operand or argument.
`OCallProduct` defines the first value; the immediately following `OResult 1`
through `OResult (n-1)` define the remaining values. Verification requires the
complete ordered packet: no missing field, intervening operation, duplicate
SSA definition or foreign product entry. All packet operations retain their
effects even if a returned field is unused. `TRetProduct` evaluates and returns
fields in source order. Selection combines the packet into one multi-result
call, with every result register removed from the call's clobber set.

The transfer checker checks exact register order before and after allocation,
not just the number of results. Unsupported widths and runtime-C product calls
are refused instead of truncating a register list. All three selectors retain
the original scalar-return path. AArch64 and RV renderers and operand validators
accept the wider private returns; x86-64 continues to reject widths above two.

## Evidence and reproduction

- `cabal test all --test-show-details=direct`: all 39 suites passed, including
  product-width admission, aliases, evaluator results, packet corruption,
  target result order, staged arguments and clobber checks.
- `python3 tests/check_product_returns.py`: native source-program allocation,
  1/4-worker execution, 96 live returned fields across calls/effects, mutual
  tail calls, effect/trap differentials, tagged escapes and target fallback.
  The isolated allocation matrix disables competing scalar/field/inlining
  optimizations and pending call regions; its cost builds also disable loop
  regions. This isolates constructor allocations from per-slab region adapters.
- `python3 tests/check_product_returns_rv.py --require-execution`: 2–8 fields,
  2,100 independent C-oracle results per width (14,700 total) in RV64 QEMU.
  The real emitted worker and reader are linked without an allocator; the
  fuel shim overwrites all volatile argument/temporary registers. This is an
  independent backend harness, not production-runtime or physical-board proof.
- `python3 tests/check_ret2.py`: existing pair output, actor/preemption and
  three-target emission regressions.
- `python3 tools/bench_product_returns.py --record bench/2026-11-05-product-returns.json`:
  default optimizer settings, separate allocation-instrumented binaries and
  uninstrumented timings, one worker, alternating rollback/default order.

The source-program suite includes a nine-field boxed fallback. x86-64 width
admission is inspected in emitted code; wider execution is qualified on native
macOS arm64 and RV64 QEMU. This milestone does not add a new physical Pi/Tang
qualification or claim a scheduling-latency bound.

## Regression and compiler-cost results

The final native product, RV64 oracle, legacy pair/actor, scalar-wrapper and
strict ARC suites passed. The registry tests passed with both new suites
registered; the RV CI configuration requires execution rather than accepting
a missing emulator. All 39 Haskell suites passed on this source revision.

The existing compiler budgets passed without changes: hello 1.59 GB allocated,
std-live 32.73 GB and pos1 70.33 GB. The tightest allocation margin remains
std-live at +9.4% against its baseline, below the existing +10% ceiling. This
is a limit to preserve, not additional headroom to assume.

The [16–256-helper specialization comparison](../bench/2026-11-05-product-return-specialization-cost.json)
retains exact code-byte and function-count parity with explicit monomorphic
twins. Compiler allocations were 134.7/239.2/454.1/918.0/1,956.7 MB; ratios to
explicit twins were 0.999–1.000x. This is a regression check on the preceding
C2 work, not a measurement of the new hosted return-worker cloning cost.

## Default-settings performance

The [500,000-call record](../bench/2026-11-05-product-returns.json) and
[5,000,000-call record](../bench/2026-11-05-product-returns-5m.json) use normal
optimizer and region settings, one native macOS arm64 worker, and separately
built instrumented allocation probes. No compiler build or regression suite
was running during the timing samples. Each pair alternates execution order;
timings include process startup. Both records identify the final compiler hash.

| Fields | Calls | Allocations, rollback → enabled | Median ms, rollback → enabled | Faster paired samples |
| --- | ---: | ---: | ---: | ---: |
| 3 | 500,000 | 500,367 → 0 | 7.049 → 6.731 | 10/13 |
| 4 | 500,000 | 500,367 → 0 | 7.263 → 7.105 | 13/13 |
| 8 | 500,000 | 500,610 → 0 | 8.947 → 8.542 | 13/13 |
| 3 | 5,000,000 | 5,003,661 → 0 | 31.039 → 28.323 | 13/13 |
| 4 | 5,000,000 | 5,003,661 → 0 | 34.938 → 33.072 | 12/13 |
| 8 | 5,000,000 | 5,006,098 → 0 | 51.829 → 47.489 | 13/13 |

The extra rollback allocations are the normal per-slab region adapters. The
longer workloads reduce the share of startup noise and show median reductions
of 8.75%, 5.34% and 8.37%, respectively. The saving is removal of returned
constructor cells, while runtime improvement is modest and workload-specific.
These timings are neither a universal speedup nor a scheduling-latency bound.
Reproduce the longer run with `--count 5000000` on the benchmark command above.

## Remaining work

Pending call-region boundaries can still wrap a producer in a real tagged
lifetime/copy contract, preventing this call-site rewrite. The pass does not
remove those wrappers. Source-shape coverage and the zero-allocation claim must
therefore be read with the stated controls and default-settings benchmark.

The next representation task is connecting the product convention to checked,
per-definition builtin layouts: raw field kinds, product arguments, ownership,
layout conversions, and generic/foreign fallback. The current tagged-word
return packet alone does not establish that contract. Scheduling response-time
qualification and physical peak-live/stack arena admission remain open.

## Follow-up: checked builtin values

Codegen 171 connects this convention to checked builtin scalar-product values,
including private product parameters, joins and explicit boxed boundaries.
See [the contract and execution record](2026-11-05-BUILTIN-PRODUCTS.md). The
codegen-170 measurements above remain historical results for the hosted pass;
they do not automatically measure the builtin follow-up.
