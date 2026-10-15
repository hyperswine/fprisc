# Tang Nano performance checkpoint, 2026-10-16

Four selected improvements now have implementations across the adjacent
fprisc and HaskPlayground checkouts:

| Area | Change | Current evidence |
| --- | --- | --- |
| RV32 compiler | Width-correct normalization, preserved-register locals, frame cleanup, direct conditions and checked primitive expansions | RV32/RV64 QEMU differential and independent-reference execution |
| Allocation and indexed memory | Indexed C heap with authenticated constant-time pointer lookup; removal of private `Addr.add` boxes around one memory operation and release | Sanitizer/ownership tests and the physical FP-RISC comparison below |
| SDRAM processor | RV32 pipeline with a 2 KiB cache, ordered masked writes and four-word burst refill | Physical RV32IM at 54 MHz; cache benchmark and 1 MiB/all-bank checks |
| Compressed instructions | Integer C decoding on both widths, mixed-length fetch, links and traps; explicit IMC compiler/build modes | QEMU/RTL on both widths; RV64 candidate physical checks; RV32 physical deployment pending |

Implementation details: [scalar compiler and address fusion](2026-10-16-RV32-SCALAR.md),
[indexed heap](2026-10-16-BUILTIN-HEAP.md),
[SDRAM processor/cache](../../HaskPlayground/boards/tangnano20k/sdram/README.md),
[pipeline history](../../HaskPlayground/boards/tangnano20k/PIPELINE-2026-10-12.md)
and [RV64/C frontend](../../HaskPlayground/boards/tangnano20k/rv64/README.md).
Cross-repository links assume the two checkouts are siblings.

## Physical FP-RISC results on the same RV32IM image

Each comparison kept the 54 MHz SDRAM pipeline FPGA image unchanged, with
compression disabled. The baseline uses the current compiler with RV32 scalar fast paths
and indexed-memory fusion disabled, plus `heap.c` from revision `4bba11b`.
The new mode enables those compiler changes and the indexed heap. Language
semantics, including checked Int overflow, are current in both modes.

| FP-RISC workload | Baseline | New | Observed speedup | Verified runs |
| --- | ---: | ---: | ---: | --- |
| 64×64 integer matrix multiplication | 43.039 s | 8.447 s | 5.10× | One in each mode |
| Build/sum/release 447-node trees eight times | 0.672 s | 0.318 s | 2.11× | One baseline; three new runs, each 0.318 s |
| Build/sum/release 8,191-node trees twice | 33.038 s | 1.476 s | 22.38× | One in each mode; 655,280 B of live objects |

Every run matched its independent output reference and `FPR EXIT 0`.
Timing starts at the received `BEGIN` line and ends at verified exit,
excluding upload and startup, including final UART output. These measure the
**combined compiler/address-fusion/heap change**; they do not isolate each
component or compare processor frequencies. The matrix evidence is one pair,
not a broad benchmark distribution.

The matrix/small-tree pairs used the original pipeline route; the large-tree
pair used the final SDRAM bank-initialization route, SHA-256
`6344f120881e8f4dcad6f16d60106358446f55fffc29a72f6250c36ecf365fab`.
Each pair used the same image in both modes. The large tree exceeds BRAM
capacity, checks every node's sum and verifies allocation recovery after both
rounds. Raw local reports are
`build/tangnano20k-stress/pipeline54-{matrix,tree,tree-large}-{legacy,fast}.json`.
To reproduce on the matching 54 MHz RV32IM SDRAM image, from fprisc:

```sh
python3 tests/check_tangnano20k_stress.py --port "$PORT" --freq-mhz 54 \
  --ram sdram --only matrix --legacy-codegen --baseline-heap-ref 4bba11b \
  --report build/tangnano20k-stress/pipeline54-matrix-legacy.json
python3 tests/check_tangnano20k_stress.py --port "$PORT" --freq-mhz 54 \
  --ram sdram --only matrix \
  --report build/tangnano20k-stress/pipeline54-matrix-fast.json
# Repeat with --only tree; use --repeat 3 for the three new tree runs.
```

Keep the loaded FPGA image and clock unchanged between these commands.
The [board target guide](2026-10-05-TANG-NANO-BUILTIN.md#scalar-heap-and-compressed-code-options-2026-10-16)
documents build modes and the separate compressed comparison options.

### Larger allocation workload

`tests/tangnano20k_stress/tree_large.fpr` builds, checks and releases an
8,191-node balanced tree twice. Its sum is 33,550,336, with exactly 8,191 live
allocations at peak and allocation-count recovery after each release. The
RV32 object blocks occupy 655,280 bytes, excluding the heap's side bitmap
and static state. This exceeds BRAM capacity: the default BRAM suite omits
it and an explicit BRAM request is refused before opening the UART.

Use `--ram sdram --only tree_large --timeout 240` with the same baseline/new
options above. The SDRAM full suite includes it. Current and baseline-heap
RV32IM images are prebuilt in `build/tangnano20k-stress/sdram-im-{fast,legacy}/tree_large/`.
Both images physically passed with the times recorded above.

## Hardware and code-density measurements

The repeated-read/coherence C microbenchmark changed from **2,389,660 cycles**
on the earlier cached serial processor to **362,612 cycles** on the new
SDRAM pipeline at the same 54 MHz: 44.253 ms to 6.715 ms, or 6.59× throughput.
This compares the complete hardware/cache change; it is not the FP-RISC
matrix result and does not isolate burst refill alone. From HaskPlayground:

```sh
SDRAM_FREQ_MHZ=54 SDRAM_RVC=0 boards/tangnano20k/sdram/build.sh pipeline
# Program the generated SRAM image before running board checks.
python3 boards/tangnano20k/sdram/check_cache.py --port "$PORT" --freq-mhz 54
python3 boards/tangnano20k/sdram/check_core.py --port "$PORT" --freq-mhz 54
python3 boards/tangnano20k/sdram/check_burst.py --freq-mhz 27 48 54 66
```

The standalone physical burst tester also passed all 8 MiB at 48 and 54 MHz,
with 12,582,912 comparisons per run, including byte masks and refresh retention.
The burst check command above uses the controller's functional pin model; it is not an
electrical timing test. Pipeline cache/CPU RTL checks also cover masked-write
ordering, coherence, physical clocks during memory holds and Ctrl-C recovery.

The checked scalar QEMU fixture's linked text shrinks **20.7% on RV32**
(24,000→19,022 bytes) and **19.2% on RV64** (24,828→20,054 bytes) with C.
Both compressed fixtures execute the same checked results. This establishes
code density, not those percentages as execution-speed improvements:

```sh
# From fprisc; no FPGA or UART needed.
python3 tests/check_riscv_scalar.py
python3 tests/check_builtin_heap_index.py
python3 tests/check_tangnano20k_bram.py
python3 tests/check_tangnano20k_clock.py
```

## Board acceptance and remaining boundaries

An RV64 C candidate physically passed 1,628 independent I/M/W reference cases
and its compressed trap/recovery fixture. Base UART services/software float
and the existing WASM parser/VM returning **42** passed on an earlier C
candidate. The final candidate passed the local-clock/software-float/selective
receive refusal probe; the full Base/WASM probes have not been repeated on
that final candidate. [Base host instructions](../machine/tangnano20k/README.md).

**RV32 compressed physical acceptance remains pending** while its board
deployment is debugged. Decoder, QEMU and RTL success do not establish a
working compressed FPGA system; the performance table above uses RV32IM.

RV64 remains a serial processor at 27 MHz, not the new RV32 SDRAM pipeline.
Both hosts have 8 MiB RAM; RV32 Builtin retains manual ownership and its
31-bit Int/absent F64 and I64 limits. RV64 Base is single-threaded, uses software
floating point, and does not automatically reclaim arbitrary temporary
allocations. The small WASM guest does not establish the full desktop suite.
Internal Gowin timing checks and board tests do not provide SDRAM I/O
setup/hold signoff or process/voltage/temperature qualification. The 54 MHz
pipeline result does not meet the roadmap's 96 MHz SDRAM gate.
