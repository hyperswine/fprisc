# Preserved-register locals and allocation/message costs

Implementation follow-up to native-performance item 4 and the cross-repository
allocation/message measurement item. This implementation batch also contains
the preceding F64 changes; QOS pins the complete compiler/runtime revision.

## Private slots in registers

The ordinary 64-bit generator promotes up to five frequently accessed private
frame slots into `s1` through `s5`. This works on RV64, AArch64 and x64, whose
common preserved-register budget is five. A register becomes the slot's storage
throughout the function, including branches and reuse as argument scratch;
there is no stale memory copy or speculative liveness inference. Calls preserve
these registers, and the actor context switch already saves them.

The prologue saves the caller's registers in additional frame slots before
parameter initialization. Every normal or tail-call teardown restores them
before restoring `s0`. Outgoing arguments are loaded before restoration. Fuel
and stack-growth calls can suspend without losing a local's value. The original
frame-slot space is retained in this first implementation; it removes traffic,
not frame size. Slots need at least six static accesses to qualify, avoiding
save/restore costs for trivial functions. This is conservative slot promotion,
not the proposed lifetime-reusing linear-scan allocator.

ARC, RV32, deep/computed frames and functions already using these registers
retain their existing path. Specialized vector loops retain their own register
convention. `FPR_NO_REGISTERS=1` provides the old slot path and has a distinct
unit-cache key. The `fpr run` executable key now includes the register, F64,
inliner and instrumentation environment modes too.

`tests/check_registers.py` compares effect ordering, CAFs, higher-order calls,
shadowing, mutual/tail recursion, nested primitive staging and IEEE operations
with promotion and helper inlining independently enabled/disabled. Switching
back to promotion checks warm-cache separation. It checks three-backend emission
and executes a register-heavy x64 function under Rosetta against 285 independent
C-reference cases. The base suite runs this gate.

In seven alternating paired executions on the macOS arm64 development host,
with one hart and identical checked output:

| Workload | Registers, best ms | Slots, best ms | Speedup |
|---|---:|---:|---:|
| nbody | 394.7 | 427.6 | 1.083x |
| SHA | 142.4 | 151.1 | 1.061x |
| helpers | 177.0 | 180.9 | 1.022x |
| fib | 58.3 | 58.9 | 1.010x |
| byte loop | 108.5 | 108.7 | 1.001x |

A separate historical ratchet comparison flagged fib/byte-loop regressions
while full suites ran concurrently. The paired quiet measurements above isolate
the register change; the old machine baseline was not rewritten. These modest
results do not establish a broad compiler speedup or eliminate the need for a
better allocator and frame construction.

## Measured runtime costs

`tools/runtime-costs.py` measures 50 million allocate/free cycles at three
sizes, and 200,000 String/Int acknowledgement round trips at three payload sizes
on one and two harts. The two-hart worker is explicitly pinned to hart 1, with
its caller on hart 0. Exact checksums and logical ledger counts are assertions.

`FPR_COST_PROBE=1` builds a separate cached runtime with per-hart relaxed atomic
counters for allocation requests/rounded bytes, copy invocations/bytes and new
message slabs. Ordinary builds contain no counter increments. Snapshotting is
outside the allocation hot path; the report is captured before formatting the
checksum or ledger. Timing comes from ordinary builds, while separate
instrumented builds supply the counters. The cost probe adds overhead and must
not be used as the production throughput score.

Five-run measurements (fastest uninstrumented process wall time; startup is
included) and the complete counters are in
[RUNTIME-COSTS.json](2026-10-01-RUNTIME-COSTS.json).

| Workload | Bytes requested/payload | Harts | Best ms | Operations/sec |
|---|---:|---:|---:|---:|
| allocate/free, 50M cycles | 16 | 1 | 209.155 | 239,057,016 |
| allocate/free, 50M cycles | 256 | 1 | 207.303 | 241,193,377 |
| allocate/free, 50M cycles | 4096 | 1 | 207.551 | 240,904,598 |
| message round trip, 200K | 16 | 1 | 26.667 | 7,500,012 |
| message round trip, 200K | 256 | 1 | 29.303 | 6,825,337 |
| message round trip, 200K | 4096 | 1 | 35.160 | 5,688,208 |
| message round trip, 200K | 16 | 2 | 830.309 | 240,874 |
| message round trip, 200K | 256 | 2 | 841.538 | 237,660 |
| message round trip, 200K | 4096 | 2 | 889.813 | 224,766 |

The allocation test deliberately recycles one block and touches one payload
byte. Its byte ledger is cumulative logical requests, not live memory or memory
bandwidth. It isolates the free-list fast path; it does not measure fresh slab
growth, retained object graphs or FP-RISC constructor overhead.

For messages, 16/256/4096-byte Strings copy 48/288/4128 bytes respectively,
including runtime headers/alignment. Each run has 400,000 copy invocations:
one copied String request and one immediate Int reply per round trip. Packed
message storage uses 73/440/6451 new slabs; the measured interval needs zero
ordinary `fpr_alloc` calls. Same- and cross-hart runs have identical logical
copy counts/bytes. The roughly 25–31x transport gap therefore makes cross-hart
shipping, fences, cache transfer and scheduling a more useful next profiling
target than reducing general allocation in this particular workload. It does
not identify which transport component dominates.

Future measurements should add fresh/retained allocation, nested graphs,
mailbox saturation and many-to-one traffic before redesigning ownership or
claiming these microbenchmarks represent complete applications.

## Compiler publication found during verification

The Makefile copied a newly built compiler directly over `fpr`. Concurrent
launches observed an incomplete executable, and on this macOS host the copied
file could subsequently be killed even while its on-disk signature verified.
The publisher now builds/copies into a unique temporary file and renames it
into place. A failed build retains the prior compiler, and the Setup fallback
no longer hides its build status behind `tail`. This is executable publication
repair, not a claim that concurrent Cabal builds are generally serialized.

`tests/check_compiler_publish.py` passed 47 concurrent compiler launches during
three publications. A subsequent run passed 46 launches and confirmed that
an injected failed build leaves the prior executable intact and runnable.
The two disk test variants use separate build directories,
so changing their flags no longer requires forcing every compiler prerequisite.

## Verification

The full FP-RISC base and standard suites passed, including register
promotion, F64 references, actor stress and killed-sleeper cleanup. Focused
checks also passed the x64 register-heavy C reference, exact instrumented
cost ledgers with ordinary builds at zero, native concurrent disk QEMU
execution and atomic compiler publication. QOS's complete sweep exited 0
with `ALL LEGS GREEN`. Websocket, windowed graphics, actual GPU dispatch and
alternate AArch64 cross-execution remain unavailable platform legs; the legacy
Sol example tally remains informational at 38/47.

## 2026-10-01: the transport component, identified

The cross-hart gap was the OS park and wake on the posix machine (about 90%
of a round trip), not shipping, scanning or cache transfer. See
[XHART](2026-10-01-XHART.md): round trips are now 19.6x faster (0.20 us,
1.5x the same-hart cost).
