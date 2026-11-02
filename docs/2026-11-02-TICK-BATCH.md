# Batched fuel ticks in scalar self-loop workers

Date: 2026-11-02. Status: on by default; roll back with `FPR_NO_TICK_BATCH=1`
(build-cache suffix `-notickbatch`).

## What changed

Inlining keeps an inlined callee's entry tick (`$fuel`, Core/Typed/Inline.hs)
so fuel still counts calls. Since 3cced47 a scalar worker may contain those
ticks, and a fused List loop paid one tick per inlined callback on top of its
own entry tick: two per element for `list_sum`, four in the `list_map` and
`option_loop` workers. Each tick reloads the thread-local hart pointer, then
decrements and stores fuel and branches (7 RV64 instructions).

`Workers.batchTicks` now drops the inlined callees' ticks from the body of a
scalar worker that calls itself. The worker's own entry tick, emitted by
codegen at its entry and on every self-loop iteration, stays.

## Granularity: exactly what changed

- **Before:** in a self-looping scalar worker, one fuel unit for each loop
  iteration plus one for each inlined callee executed in that iteration.
- **After:** one fuel unit per iteration (and per entry). Calls that are not
  inlined still tick on their own entry. Workers that do not call themselves,
  non-worker code and the boxed wrapper are unchanged.

A loop therefore runs up to (1 + inlined callees per iteration) times more
iterations per fuel quantum, and preemption, deadline and watchdog checks
happen at the same point (every iteration's entry tick) but are reached after
proportionally more iterations. The worker fragment has no loops other than
calls, so the work between two ticks stays bounded by the worker body (≤ 1024
Core nodes, Workers.hs). Fuel is not an exact cost measure for this code: it
was already approximate, and inlining had already removed ticks in non-worker
code.

## Measurements

RV64, static (`fpr compile --system=posix --target=rv64`), fused `list_sum`
worker hot path per element: 36 -> 29 instructions (one tick instead of two).
The `list_map` and `option_loop` workers go from four ticks in the body to one.

x86-64, `tests/bench/unbox`, whole process, median of 9 interleaved runs:

| bench | FPR_NO_TICK_BATCH=1 | batched |
|---|---:|---:|
| list_sum | 35.0 ms | 27.5 ms |
| list_map | 65.1 ms | 33.2 ms |
| option_loop | 100.3 ms | 81.8 ms |
| loop_sum (control) | 28.1 ms | 28.4 ms |

Fused `list_sum` is now at the hand-written loop (`loop_sum`).

## Extension: every self-looping function (same day)

The first cut only reached scalar workers. The fused List loops in
`list_filter`, `list_fold` and `list_length_rev` (and `tree_sum`) are ordinary
specialised functions (`$typed.mono.go.N`), not scalar workers, so they kept
every inlined callee tick (five per element in `list_filter`).

`Core.Opt.Ticks` (new, last pass in `Core.Opt.Pipeline`, `BatchTicks`, gated
on the same `optTickBatch` flag) applies the same rule to any function that
calls itself and has a body of at most 1024 Core nodes: inlined entry ticks
(`let $fuel = ... in body`) are dropped, the function's own entry tick stays.
`Workers.batchTicks` is now the shared implementation. Nested lambdas are not
entered. The pass is last so `ReuseConstructors` still sees the original
calls. `fpr compile` prints `# tick batching: self-loops=N batched=M`
(plus the declined function names, if any). `codegenRev` 147.

Granularity is as above: one fuel unit per iteration; non-inlined calls tick
on their own entry; inlined callees are non-recursive, so the work between
two ticks is bounded by the body size.

x86-64 (hosted on darwin), `tests/bench/unbox`, whole process, median of 9
interleaved runs, speed-up of batched over `FPR_NO_TICK_BATCH=1`:

| bench | speed-up |
|---|---:|
| list_sum | +4.2% |
| loop_sum (control) | +3.8% |
| list_map | +44% |
| list_filter | +13.8% |
| list_fold | +12.4% |
| list_length_rev | +10.8% |
| option_loop | +21.7% |
| tuple_loop | -0.8% (noise) |
| tree_sum | +3.6% |
| string_scan | +0.4% |

Isolating the new pass (against worker-only batching): `list_filter` +7.8%
(5 ticks -> 1 per element; 215.8 -> 193 ms), `list_fold` +12.8%,
`list_length_rev` +5.5%, `tree_sum` +4.5%, the rest within noise. Fused
`list_sum` is at or just below the hand loop (`loop_sum`).
Compile budget (`check_compile_budget.py`) is within baseline
(allocation -1.0% / -3.8% / -2.1%; the peak-live figure for std-live moved
+14.1%, within the check's tolerance).

`tests/check_tick_batch.py` also checks all ten unbox benchmarks for identical
output on and off, and one vs five ticks in the non-worker `list_filter` loop
on RV64. `tests/CorePipeline.hs` covers the pass: batches a self-looping
function, keeps a non-looping function's tick, rollback, and the note.

## Not done

The surviving tick still reloads the hart pointer through TLS on every
iteration (3 of its 7 instructions). Keeping it in a callee-saved register
across the loop is a backend change; I left it alone.

## Evidence

`tests/check_tick_batch.py` (registered with the Base checks): identical output
on and off for the unbox benchmarks, one tick vs two in the RV64 `list_sum`
worker, and a child spinning in a batched worker is still preempted on 1 and 4
harts. `check_deadlines`, `check_printer_watchdog`, `check_scheduler_locality`,
`check_self_loops`, `check_self_loop_x64`, `check_self_loop_rv64` (QEMU),
`check_early_loops`, `check_registers`, `check_case_known`,
`check_list_fusion` and the CorePipeline/TypedIR suites pass.
