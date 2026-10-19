# Tang Nano: repeated FP-RISC programs within 8 MiB

The RV32 Base host now has opt-in temporary reclamation (`FPR_GC=1`). The
existing decision-tree classifier completes ten 512-row training / 128-row
test iterations in one process on the physical SimpleRisc board at CPU/SDRAM
48/48 MHz. Without collection, the first iteration exhausts the heap.

The 72/54 MHz FPGA image is **not accepted for this larger workload**: the
final collector build produces intermittent incorrect trees and prediction
digests there. The strict regression rejects it even though the guest exits
successfully. The lower-clock result is the current physical acceptance
boundary, not a diagnosis or repair of the higher-clock failure.

## Implementation and root contract

The existing coalescing allocator gains nonmoving conservative mark/sweep.
On allocation pressure it collects once and retries, preserving the existing
out-of-memory panic if live data still cannot fit. There is no fixed object
queue: allocated block metadata holds an iterative mark worklist; sweep
rebuilds the free indices and coalesces adjacent dead blocks. The payload
bitmap authenticates candidates before metadata is read. Cycles are reclaimed.

The board adapter saves all integer registers, scans the active stack and
static application data, then traces reachable payloads. Private allocator
bounds and free lists occupy a separate linker section excluded from static
roots. Interior payload and one-past-end pointers retain their objects. C
stack/register roots also recognize allocator-header addresses, including
the ambiguous address which is both one block's end and the next header.

This mode requires the current single-threaded soft-float IM/IMC host and
pointers visible in naturally aligned machine-word slots or integer registers.
Packed/encoded pointers, external/device-memory roots and concurrent heap
access are outside its contract. Explicit frees still take effect. Compiler
ARC and this collector are mutually exclusive. Conservative false positives
can retain dead objects; collection pause time is not bounded. The default
manual heap remains unchanged in ownership behavior and does no GC/statistics
work unless the corresponding build flag is enabled.

This first milestone reclaims temporary boxes; it does not remove boxing,
add actor scheduling, extend host file services or implement autonomous boot.

## Acceptance results

Parameters are 512 training rows, 128 held-out rows, 16 bins, depth 6,
minimum leaf 5. `tests/dtree.fpr` is unchanged. Every iteration must match the
independent Python reference: 55 nodes, depth 6, training 481/512 with digest
354774, held-out 116/128 with digest 434626, root column 0 at
-0.12101956852711737 (within the existing numeric tolerance).

| Check | Result |
| --- | --- |
| Final source, collection off, 512 rows in QEMU | Expected first-iteration OOM; 0 collections |
| Final source, normal collection in QEMU | 10/10 exact classifier results |
| Collect every 101 allocations in QEMU | 2/2 exact results; 4,406 collections |
| Physical CPU/SDRAM 48/48 MHz | 10/10 exact results and successful guest exit |
| Physical CPU/SDRAM 72/54 MHz | Rejected: intermittent wrong tree / predictions |
| Same failing hardware ELF in QEMU, only UART output instructions patched | 10/10 exact results |

The accepted physical run uses a 152,288-byte image, 64 KiB reserved stack,
8,123,712-byte heap arena, 63,472-byte bitmap and 8,060,240 bytes available
for allocator blocks. Its 22 collections reclaim **172,798,624 bytes** across
2,224,756 allocations. Maximum retained blocks immediately after collection
are **243,632 bytes**; final exit residency is 1,038,688 bytes because normal
allocation continues after the last collection. Peak residency reaches the
arena limit by design: ordinary collection starts under allocation pressure.
These byte counts include allocator headers and padding, not just language
payload. Counters have machine-word width and can wrap on longer RV32 runs.

Physical per-iteration time ranges from 12.895 to 13.494 seconds, median
12.920 seconds, including GC reporting inside the measured interval. QEMU
times are functional-test observations, not FPGA performance predictions.
The repeated-process harness also handles RV32's positive 2^30 tick wrap;
each individual measurement must remain shorter than one wrap (~107 s).

The native ASan/UBSan tests cover reachable/unreachable cycles, deep graphs,
byte-interior and one-past roots, allocator-header roots, pressure, realloc,
manual frees, forged headers, coalescing and genuine live-data OOM. RV32 and
RV64 QEMU tests use the production linker and register/root adapter with a
collection before every allocation. They check stack, static and caller/callee
register roots; deliberately omitting a caller-register save must fail.
The existing allocator suite passes, including manual Rc, deep ARC, bounded
heaps and 21 negative cases per RISC-V word size. All ten RV32IM/IMC Base
numeric, Int, Word, host and record/vector fixtures pass with collection
every seven allocations.

## FPGA boundary and unresolved 72 MHz failure

Both images use the integrated E2-retimed core from HaskPlayground `32bdeff`,
RVC and a 64 KiB banked write-update cache. The accepted fresh 48/48 MHz build
uses 135-degree SDRAM phase and placement option 2. Gowin reports 55.269 MHz
Fmax, +2.740 ns worst setup slack and zero setup/hold violating endpoints
under the supplied constraints. Its bitstream is:

```
HaskPlayground/output/tangnano20k/gc-validation-c48-20261020/impl/pnr/sdram_test.fs
SHA256 032849eeb6fe291eb8b73038ed0ef88f9ffacfe24e1e834342672683ac539f40
```

The rejected 72/54 MHz image has SHA256
`5eb222ff39eee54dd53d45a69e1dee94481dd585dcb903c8f3000a56f91b7e3c`
and previously passed the smaller regression suite with only +0.008 ns
internal setup margin. An earlier collector revision passed ten iterations
on it, but the final revision did not. We retain the final failure as evidence
rather than promoting the earlier, less-complete root implementation.

For isolation, the failing hardware ELF was copied and only 12 bytes of
`hal_putc` were changed to emit through QEMU's UART. All other guest bytes
and addresses stayed fixed; all ten runs passed. Together with the 48 MHz
physical pass, this narrows the failure toward the physical execution profile,
but does not prove a timing root cause: clock ratio, placement, memory/CDC
behavior and time-dependent conservative roots differ too. A follow-up must
isolate those variables before qualifying the 72 MHz workload.

Neither build has complete SDRAM I/O/PVT qualification. Reported internal
STA and one board's physical tests do not establish external memory margins
across voltage/temperature. Only volatile SRAM and UART guest RAM were
programmed. The board is left on the accepted 48/48 MHz image, idle after
successful completion; flash and SD contents were not changed.

## Reproduction and evidence

With the matching 48/48 MHz image loaded:

```sh
FPR_GC=1 FPR_HEAP_REPORT=1 python3 tests/check_tangnano20k_dtree.py \
  --hardware --xlen 32 --freq-mhz 48 \
  --train 512 --test 128 --bins 16 --depth 6 --min-leaf 5 \
  --repeat 10 --timeout 600 --output build/tangnano20k-gc-repeat

python3 tests/check_tangnano20k_gc.py \
  --classifier-report build/tangnano20k-gc-repeat/results.json

# Functional check without the board:
FPR_GC=1 FPR_HEAP_REPORT=1 python3 tests/check_tangnano20k_dtree.py \
  --qemu --xlen 32 --freq-mhz 48 \
  --train 512 --test 128 --bins 16 --depth 6 --min-leaf 5 \
  --repeat 10 --timeout 600 --output build/tangnano20k-gc-qemu

FPR_GC=1 FPR_GC_STRESS=7 python3 tests/check_tangnano20k_rv32_base.py
python3 tests/check_builtin_heap_index.py
```

`FPR_GC_STRESS=N` is diagnostic only; leave it unset for ordinary execution.
The classifier gate requires at least ten exact 512-row runs, bounded peak
residency, post-collection retained data below 1 MiB and reclamation exceeding
ten arena sizes. A successful process exit alone cannot satisfy it.

Tracked [evidence](evidence/2026-10-20-tangnano20k-gc/manifest.json) includes
source/artifact hashes, accepted and rejected UART logs, QEMU results,
sanitizer/root/allocator regressions and the exact-ELF UART patch record.
Full build outputs remain under `build/tangnano20k-memory-20261020/`.

## Next steps

1. Isolate and repair the 72/54 MHz regression before widening its acceptance.
2. Use allocation counters to target scalar boxing and vector numeric kernels.
3. Add program arguments, stream reads and directory operations to the UART
   host, with explicit capability/refusal tests.
4. Bring up single-core actors and useful trap/stack/heap diagnostics, then
   connect the existing SD support to a standalone program/data workflow.
