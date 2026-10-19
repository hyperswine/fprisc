# Tang Nano 20K CPU and SDRAM clock experiment, 2026-10-18

The processor and its SDRAM now have separate clocks. The requested
108 MHz CPU / 54 MHz SDRAM configuration was built and tried on the board,
but it failed timing and the physical RV32C instruction check. It is not a
working FP-RISC configuration. A 72 MHz CPU / 54 MHz SDRAM fallback passes
Gowin's internal setup and hold checks and all 12 physical acceptance cases,
including FP-RISC and persistent on-card file creation/readback.

The earlier 48 MHz image remains the comparison baseline. No flash image was
changed during this experiment; FPGA programming uses volatile SRAM.

## Implementation

HaskPlayground supplies the processor and board RTL. FP-RISC retains its
existing RV32IMC Base compiler/runtime and the SD protocol/FAT implementation.

- Split compressed instruction assembly from expansion and source predecode,
  with an elastic two-entry expanded-instruction queue before decode.
- Feed the cache from registered full addresses and a registered request slot.
  The CPU still observes a three-logical-clock memory port. Cache misses freeze
  all logical stages while UART, SPI, counters and memory refresh continue.
- Cross between CPU/cache and SDRAM using an ordered, one-operation mailbox.
  Request and response toggles pass through synchronizers; each payload remains
  stable until acknowledged. Four-word memory replies are buffered and replayed
  on CPU clocks.
- Map the cache tag store to synchronous block RAM. One explicit write port
  handles invalidation, clearing and refill; a registered collision guard
  ignores an undefined read-during-write tag. The first two full builds show
  cache usage falling from 1,993 to 317 registers and 3,176 to 324 LUTs, using
  one additional BSRAM.
- Register multiply summation across an additional commit hold, predecode
  memory targets, limit operand forwarding to commit, register decode hazard
  lookahead, and register the iterative divide/remainder result-half choice.
  These changes affect instruction latency, so clock frequency alone does not
  establish application speed.

The board C HAL remains unchanged. SD commands, CRCs and FAT operations still
run in FP-RISC. See the [SD implementation record](2026-10-18-TANGNANO20K-SD.md)
and [I32 implementation record](2026-10-18-I32.md).

## Vendor timing and exact images

Gowin V1.9.12.04 targets GW2AR-LV18QN88C8/I7. Setup uses the tool's
Slow 0.95 V / 85 C C8/I7 model; hold uses Fast 1.05 V / 0 C C8/I7.

| Build | CPU / SDRAM MHz | CPU Fmax MHz | Worst setup slack ns | Setup / hold violations |
| --- | ---: | ---: | ---: | ---: |
| First split-clock trial | 108 / 54 | 79.514 | -3.317 | 1,955 / 0 |
| Synchronous cache tags and CPU cuts | 108 / 54 | 79.757 | -3.279 | 1,549 / 0 |
| Final RTL, 108 MHz placement | 108 / 54 | 82.359 | -2.883 | 2,367 / 0 |
| Same final RTL, 72 MHz placement | 72 / 54 | 72.018 | +0.003 | 0 / 0 |

The final 72 MHz image uses 12,933 logic resources, 5,036 registers and
5 of 46 BSRAMs. Its memory clock domain reports 121.169 MHz Fmax against a
54 MHz constraint. The separate 108 MHz placement reports 116.431 MHz for
that memory domain. The remaining 108 MHz failures are CPU paths.

The 72 MHz result has only **3 ps of reported setup margin**. These are
internal tool checks plus the physical tests below, without board I/O timing
or broad voltage/temperature qualification.

Both placements use frozen CPU RTL SHA256:

```
3b2a9fe155b15806517c575a91c285aa5060f5171861d0ccfd28d270d980fcc0
```

72 MHz FPGA `.fs` SHA256:

```
49bf20aa59d07b6b480fa7ba80885a1468b4a52a7118b8767c0c0b026301ecf8
```

108 MHz FPGA `.fs` SHA256:

```
3f23060d1edb5cb5cdb4dd045c1b0ad28da39db71c340a2386210c2a5b364c8d
```

Reports are in sibling HaskPlayground under
`output/tangnano20k/sdram-pipeline-c{108,72}-m54-sd-fpr-trial3/impl/pnr/`.
Source hashes, timing-file hashes, guest hashes and retained physical evidence
are in [the evidence record](evidence/2026-10-18-tangnano20k-clocks.json).

## Verification before programming

The final Haskell suite passes 64 SimpleRisc properties. Generated CPU/cache
RTL passes high RAM, masked stores, instruction coherence, compressed fetch,
integer multiplication/division, precise traps, counters, SPI MMIO and UART
Ctrl-C during a long memory hold. Both the common-clock and clock-crossing
versions reject a deliberately corrupted backend word.

The real SDRAM controller's functional pin model also passes at simulated
108 MHz CPU / 54 MHz memory, 135-degree SDRAM clock phase and 5.4 ns DQ
output-access delay. It executes the extended ROM's T/Q/V/H upload, XOR
readback, guest execution and trap `DONE`. This simulation passes even though
the physical 108 MHz image fails, demonstrating why RTL simulation alone
does not establish frequency support.

The cache regression additionally poisons same-address tag read/write results
with `X`: reads and 121 ordered masked writes still match an independent RAM
model. Removing the collision guard deliberately fails. The standalone clock
bridge checks include independent clock rates, stalls, reset and read ordering.

## Physical 108 MHz result

The UART diagnostic passed. The next RV32C instruction check failed: it emitted
repeated ROM `DONE` markers and zero readbacks instead of `RV32C BOARD HOLDS`.
The run stopped before FP-RISC or SD file tests, and the working 48 MHz image
was restored before the 72 MHz experiment. A responsive UART is not sufficient
evidence that the processor executes guest programs correctly.

Logs: `build/tangnano20k-clock108/board/{uart,rv32c}.log` and `results.json`.

## Physical 72 MHz acceptance

The runner completed all 12 cases with `complete: true` and `passed: true` in
`build/tangnano20k-clock72/board/results.json`:

| Check | Physical result |
| --- | --- |
| UART diagnostic and RV32C instruction/trap fixture | Pass |
| High-address RAM test | Pass: 1 MiB working set, all banks, last word and byte lanes |
| FP-RISC I64 and software F32/F64 numerics | Pass, `FPR EXIT 0`, `DONE` |
| Full I32 integer and wide-bridge suite | Pass, `FPR EXIT 0`, `DONE` |
| Rooted UART host file/environment/input/time services | Pass, `FPR EXIT 0`, `DONE` |
| Decision tree, two fresh runs | Both match the independent reference |
| SD file creation and fresh guest reopening | Both exact-payload/overwrite-refusal checks pass |
| Read-only raw-sector audit and independent Python decoder | Both pass |

### Application comparison

The immediate pre-change 48 MHz baseline ran the 128/64-row decision tree
with 8 bins, depth 5 and minimum leaf size 2 in **4,856,153 microseconds**.
It produced 23 nodes, 124/128 training hits and 61/64 test hits, matching the
independent Python prediction digests and root split. Both 72 MHz repetitions
passed the same correctness checks:

| Configuration | Guest elapsed microseconds |
| --- | ---: |
| Previous 48 MHz image | 4,856,153 |
| Final 72/54 MHz image, run 1 | 6,608,712 |
| Final 72/54 MHz image, run 2 | 6,608,709 |

The mean 72 MHz runtime is 6,608,710.5 microseconds, **36.1% longer** than
the old 48 MHz result. The higher CPU clock does not provide an application
speed improvement for this workload. Additional dependency waits, the
multiply commit cycle and clock-crossing refill latency are architectural
contributors inferred from source changes; their individual costs were not
measured with per-stage hardware counters. Upload time is excluded from these
guest `Sys.mtime` measurements.

### Larger bounded workload

A further physical run used 512 training rows, 128 test rows, 16 bins,
maximum depth 6 and minimum leaf size 5. It reached `DTREE DATA READY`, then
reported `Base panic: Builtin: out of memory`, `FPR EXIT 1` and ROM `DONE`.
The success runner correctly rejected that run. It did not complete classifier
construction or prediction checks.

This guest has 8,059,264 usable heap-block bytes after its arena bitmap,
firmware and 64 KiB stack reservation. The observed failure is the Base heap
limit; this run supplies no evidence of a clock or SDRAM hardware failure.
Automatic reclamation of Base temporary allocations remains unavailable.
The 153,288-byte guest SHA256 is
`e36e70336ddd17f91b3b9ae502890ed8cd054e856240dbb96167e096511c1c00`.
The raw failure log and reference/result record are retained in
`build/tangnano20k-clock72/large-dtree/{failure.log,results.json}`.
A final UART diagnostic passed after the panic. The board remains on the
same 72/54 MHz SRAM image; the diagnostic is retained in
`build/tangnano20k-clock72/post-large-uart.log`.

### SD persistence and independent sector audit

The clock fixture preserved the existing 60-byte binary `FPRTEST.TXT` and
created `CLKTEST.BIN` with 512 bytes, byte `i = (i * 73 + 19) mod 256`.
It read the file nine times, refused overwrite and reread the original file.
A fresh guest run printed `CLOCK SD EXISTING FILE VERIFIED` and passed the
same nine reads, original-file check and overwrite refusal. Both completed
with `CLOCK SD FILE HOLDS 512 BYTES 9 READS`, `FPR EXIT 0` and `DONE`.
The 72 MHz run uses divider 11 to keep SPI at 3 MHz; 108 MHz uses divider 17.

The independent read-only audit bypassed FAT and dumped nine raw sectors.
Python decoded both affected FAT copies and the root entries, verified both
complete binary payloads, required an unchanged MBR and FAT boot sector, and
compared the original Linux superblock sectors at LBAs 8,194 and 8,195.
This proves preservation of those sampled Linux sectors; it is not a reread
of the complete Linux partition. The earlier approved 16 MiB FAT16 partition
remains the only file-test destination.

`FPRTEST.TXT` remains in cluster 2, and the new file occupies cluster 3. The
512-byte file SHA256 is
`8d35978b98877da24dc6904f1a27aaf031f9103991d3ed868ae7dc938a6a00fd`.
The decoded physical result is retained under
`build/tangnano20k-clock72/board/sd-sectors/results.json`.

Before physical testing, the seeded native SD model passed file creation and
fresh-process reopening. Creation issued exactly four expected sector writes;
the fresh run issued zero. The read-only audit issued nine reads and zero
writes, and 16 independent corruption/refusal checks passed.

## Reproduce the 72 MHz guests

Build and program the matching HaskPlayground 72/54 image first. For each
guest, set the runtime clock to the actual CPU clock:

```bash
FPR_XLEN=32 FPR_RVC=1 FPR_CPU_MHZ=72 machine/tangnano20k/build.sh \
  tests/tangnano20k_sd_clock.fpr "$PWD/build/tangnano20k-clock72/sd"
python3 tools/run_tangnano20k_base.py build/tangnano20k-clock72/sd/base.bin \
  --freq-mhz 72 --env SD_DIVIDER=11 --timeout 180
```

For a read-only audit after the file fixture:

```bash
FPR_XLEN=32 FPR_RVC=1 FPR_CPU_MHZ=72 machine/tangnano20k/build.sh \
  tests/tangnano20k_sd_clock_audit.fpr "$PWD/build/tangnano20k-clock72/sd-audit"
python3 tools/run_tangnano20k_base.py build/tangnano20k-clock72/sd-audit/base.bin \
  --freq-mhz 72 --env SD_DIVIDER=11 --timeout 180 \
  > build/tangnano20k-clock72/sd-audit/physical.log
python3 tests/check_tangnano20k_sd_clock_audit.py \
  --log build/tangnano20k-clock72/sd-audit/physical.log \
  --out build/tangnano20k-clock72/sd-audit/decoded
```

The card-specific audit expects the retained baseline sectors under
`build/tangnano20k-sd/audit`. Its `--self-test` mode exercises the independent
decoder without a board. Guest builds check their linked RV32IMC soft-float
ISA and ABI. Physical Base success requires both `FPR EXIT 0` and ROM `DONE`.
