# Tang Nano 20K: Base host, UART virtual device and microSD

The recommended RV32 example configuration is now **`FPR_PRESET=fprisc-48`**:
RV32IMC, CPU/SDRAM 48/48 MHz, 64 KiB cache and conservative collection enabled.
The [preset and example guide](../../docs/2026-10-21-TANGNANO20K-PRESET.md)
has the matching FPGA command, one-command QEMU/board suite, build manifests
and verification limits. Without the preset the legacy defaults below remain.

This is an experimental RV32IM/IMC and RV64IM/IMC Base host, alongside the
established RV32 Builtin target. Both Base variants use cached 8 MiB SDRAM and
a 64 KiB stack. RV64 uses HaskPlayground's `boards/tangnano20k/rv64` image at
27 MHz; RV32 has a physically tested 72 MHz CPU / 54 MHz SDRAM image, with the
48 MHz image retained as a baseline. The 108 MHz attempt failed timing and
the physical instruction check. See the [clock experiment and acceptance
record](../../docs/2026-10-18-TANG-NANO-CLOCKS.md) for current results and the
small timing margin. This is a single execution thread; the Base
actor scheduler, interrupts, processes and dynamic stack growth are unavailable.

The program keeps `profile base.` and uses the ordinary `core/prelude.fpr` and
stdlib. No interpreter or guest logic runs on the computer: only explicit host
services go through the virtual device. The shared compiler/runtime still own
FP-RISC semantics. The board C code supplies allocation, UART and ABI mechanisms.

## Current capability surface

| Facility | Implementation |
| --- | --- |
| Console / successful or failing exit | Local UART / finisher |
| Int | Tagged signed payload: 63 bits on RV64, 31 bits on RV32; checked arithmetic |
| Word, Addr | Full machine-width boxed values; 64 or 32 bits |
| I64 | Boxed full 64-bit values on both targets |
| I32 | Exact wrapping 32-bit values; boxed on RV32, tagged without allocation on RV64 |
| F32 / F64 arithmetic | Software floating point; raw bits on RV64, boxed values on RV32 |
| Whole-file read, exists, replace, append | Rooted host file device over UART |
| On-card sector I/O and small FAT16/FAT32 root files | Explicit `std/tangnano20k/sd` and `fat` modules on the SPI-enabled RV32 SDRAM image; new 8.3 files up to 512 bytes |
| `Sys.env` | Explicit `--env NAME=value` entries; no host environment inheritance |
| `Sys.timeUs` | Host monotonic microseconds |
| `Sys.mtime` | Local cycle counter converted to the shared 10 MHz tick contract |
| `Sys.readLine` | Explicit `--input` lines, then EOF |
| `Sys.args` | Explicit uploader `--arg` values, in order; excludes the program name |
| `Sys.sleepUs` | Local cycle-counter wait |
| Stream files, directory APIs, watch-open | `Err` with a named unavailable capability |
| Actors, IRQ routing, polling/watch operations without a Result error channel | Named panic / failing exit |
| Selective nonblocking `receiveFromNow` | Named unavailable `Err`; no actor or mailbox is fabricated |
| Temporary reclamation | Opt-in `FPR_GC=1`: single-threaded nonmoving conservative collector |
| Unlisted primitives | Link failure; never automatic success stubs |

The allocator is the single-threaded indexed coalescing C heap described in
[the heap record](../../docs/2026-10-16-BUILTIN-HEAP.md). By default, Base's temporary
allocations are not automatically reclaimed. `FPR_GC=1` adds collection on
allocation pressure; the [reclamation report](../../docs/2026-10-20-TANGNANO20K-GC.md)
records its root contract and repeated 512-row classifier acceptance. The
documented desktop WASM suite peaks around 100 MB and does not fit this board.
Full Base scheduling and the full WASM suite are not claimed.

## Build

From fprisc:

For the recommended RV32 configuration:

```bash
python3 tools/run_tangnano20k_examples.py --target qemu
FPR_PRESET=fprisc-48 machine/tangnano20k/build.sh examples/wc.fpr build/tangnano20k-wc
python3 tools/run_tangnano20k_base.py build/tangnano20k-wc/base.bin \
  --freq-mhz 48 --root /path/to/files --arg=notes.txt --arg='two words.txt'
```

The uploader requires the matching 48 MHz FPGA image already loaded.
`--arg=` preserves an empty argument and `--arg=-n` preserves a leading dash.
At most 256 arguments and 65,536 encoded bytes (including lengths) are allowed.
Arguments are UTF-8, exclude NUL, and are never interpreted by a shell.
The host supplies an empty list if no `--arg` options are given. A new guest
asking an older host for arguments receives an explicit unavailable error.

The following commands retain the original RV64 configuration:

```bash
make fpr
machine/tangnano20k/build-softfloat.sh
machine/tangnano20k/build.sh tests/tangnano20k_base.fpr
mkdir -p build/tangnano20k-files
cp tests/fixtures/uart-device/* build/tangnano20k-files/
python3 tools/run_tangnano20k_base.py build/tangnano20k-base/base.bin \
  --root build/tangnano20k-files --freq-mhz 27 --env TEST_UART=connected
```

`FPR_CPU_MHZ` selects the runtime's cycle conversion; it must match the image.
`FPR_SOFTFLOAT_ROOT` may point at an existing pinned SoftFloat checkout.
The build disables native F64 instruction emission using `FPR_NO_F64_INLINE=1`
and defaults to `rv64im`, `lp64`, `medany`, including the software-float library.
The installed toolchain's generic hard-float libraries are not linked.

### RV32 Base

Build HaskPlayground's SDRAM pipeline with its extended SDRAM boot ROM, then
load the matching image into SRAM. The old RV32 `P/R` loader is insufficient
for large Base programs. From fprisc:

```bash
FPR_XLEN=32 machine/tangnano20k/build-softfloat.sh
FPR_XLEN=32 FPR_RVC=1 FPR_CPU_MHZ=72 machine/tangnano20k/build.sh \
  tests/tangnano20k_rv32_host.fpr "$PWD/build/tangnano20k-rv32-host"
python3 tools/run_tangnano20k_base.py build/tangnano20k-rv32-host/base.bin \
  --root build/tangnano20k-rv32-host --freq-mhz 72 \
  --env TEST_UART=connected --input 'hello RV32'
```

`FPR_XLEN` defaults to 64. RV32 selects `ilp32`, a separate SoftFloat archive,
RV32 libgcc helpers and an ELF32 ISA check. IMC requires `FPR_RVC=1` on both
the guest build and FPGA. The shared startup and counter reader select the
word size at compilation. `FPR_QEMU=1` selects a 16550 UART adapter for QEMU
`virt`; use the default zero for physical FPGA images.

RV32 `Int` spans -1073741824 through 1073741823. I64 arithmetic retains all
64 bits; `I64.toInt` returns `Err` when the result does not fit. Use
`I64.hiWord`, `loWord` and `fromWords` for arbitrary 32-bit halves. Legacy
`hi`/`lo` trap if an unsigned half cannot fit an Int. `I32` is implemented
as a distinct type with wrapping arithmetic, signed/unsigned operations,
bit operations and checked numeric conversions. `I32.toInt`/`toIntU` return
`Result Int String` on both word sizes. See [the I32 implementation and checks](../../docs/2026-10-18-I32.md).

RV32 floating literals are immutable static boxes, and floating arithmetic
uses runtime boxes and generic vector callbacks. Integer vector kernels remain
enabled. This changes allocation costs: the 128/64-row classifier passes,
while 512/128 rows with 16 bins exhaust the current 8 MiB heap without
collection. With `FPR_GC=1`, the latter configuration passes ten repetitions
in one process on the RV32 board at CPU/SDRAM 48/48 MHz. The 72/54 MHz
image produces intermittent wrong results with this larger regression and is
not accepted for this workload. See [the original RV32 port record](../../docs/2026-10-18-RV32-BASE.md)
and [the reclamation follow-up](../../docs/2026-10-20-TANGNANO20K-GC.md).

### Optional temporary reclamation

```bash
FPR_XLEN=32 FPR_RVC=1 FPR_CPU_MHZ=48 FPR_GC=1 \
  machine/tangnano20k/build.sh tests/tangnano20k_dtree.fpr "$PWD/build/tangnano20k-gc"
```

`FPR_GC=1` saves the integer registers and scans the active stack, static
application data and reachable heap blocks. It does not move objects or
change their representation. It supports the current single-threaded,
soft-float IM/IMC host; it is separate from compiler ARC and is off by default.
Pointers must remain visible in naturally aligned machine-word slots or
registers. Interior payload and one-past-end pointers are recognized. Packed
or encoded pointers, roots in external/device memory, and concurrent heap
access are outside this mode's contract. Ordinary explicit frees still apply;
collection does not repair use-after-free. Conservative false positives can
retain dead data, and collection pauses are not bounded for real-time use.

`FPR_HEAP_REPORT=1` prints allocation residency/churn at exit and after each
collection. Residency includes allocator headers and padding, excludes the
bitmap, and does not equal the live language payload. Cumulative counters
have machine-word width. `FPR_GC_STRESS=N` requires `FPR_GC=1` and collects
every N allocations for root-liveness tests; leave it unset for ordinary use.
No GC or statistics work is added to the default manual heap allocation path.

On RV32, `Sys.mtime` returns 10 MHz ticks modulo 2^30 (about 107.37 seconds),
and `Sys.timeUs` returns host microseconds modulo 2^30 (about 17.90 minutes),
matching the positive tagged-Int range. Short elapsed-time calculations must
account for wrap. RPC timeouts and sleeps use the full local 64-bit counter.

`FPR_RVC=1 machine/tangnano20k/build.sh ...` explicitly selects compressed
RV64IMC code for a matching RV64 FPGA image with the C decoder enabled.
The default remains RV64IM. The linked ISA check accepts C only for this
explicit option and continues to reject A/F/D and incompatible ABI libraries.
`FPR_CPU_MHZ` must still match the image. Compression reduces code size;
its effect on board execution time requires measurement.

SoftFloat is pinned to Berkeley SoftFloat revision
`a0c6494cdc11865811dec815d5c0049fba9d82a8`, RISCV specialization, rounding to
nearest-even. [Upstream](https://github.com/ucb-bar/berkeley-softfloat-3).
`SOFTFLOAT-LICENSE` retains its license. The `softfloat.c` bridge supplies GCC's
soft-float ABI and uses the same package for sqrt. Exception flags remain
internal to the software library; RV64IM has no floating-point CSR state.

## On-board microSD

The SPI-enabled RV32IMC SDRAM image exposes the board slot to an FP-RISC
SD protocol driver and a small FAT16/FAT32 file layer. The C HAL is 84 lines
of register and buffer access. The original 48 MHz CPU / 3 MHz SPI test
created and read `FPRTEST.TXT` on an approved 16 MiB test partition, including
binary bytes and overwrite refusal. The 72 MHz CPU / 54 MHz SDRAM image also
passes a new 512-byte `CLKTEST.BIN` creation test, nine exact reads, overwrite
refusal and fresh guest reopening. Its independent nine-sector audit verifies
both files, affected FAT copies, the unchanged MBR/boot sector and preserved
Linux superblock samples. See the [clock report](../../docs/2026-10-18-TANG-NANO-CLOCKS.md)
for exact images, timing margin and the classifier performance regression.

Use `tests/tangnano20k_sd_probe.fpr` for read-only inspection and
`tests/tangnano20k_sd_files.fpr` for a new-file/readback test on a compatible
card. The latter refuses a conflicting existing file. The dedicated
card-specific preparation tool requires explicit approval and a runtime gate;
ordinary tests never format the card.

For the current 72 MHz image, use `tests/tangnano20k_sd_clock.fpr` and pass
`--env SD_DIVIDER=11` to the Base runner for 3 MHz SPI. The read-only probe
also accepts `SD_DIVIDER`; its default 7 corresponds to the older 48 MHz
image. `tests/tangnano20k_sd_clock_audit.fpr` is the read-only, card-specific
audit for the retained test partition.

See the [driver, hardware and validation report](../../docs/2026-10-18-TANGNANO20K-SD.md)
for the required FPGA image, build commands and the initial 512-byte file limit.

## UART protocol

The RV64 loader and extended RV32 SDRAM ROM support `Q`, a little-endian 32-bit count of 32-bit words, image
bytes, then a command. The current image limit is 2 MiB. `P` retains its legacy
16-bit count/64 KiB limit. `H` starts at `0x80000000`; `R` starts at zero.
`V` returns eight lowercase hex digits plus newline: XOR of every uploaded
32-bit word read back through the memory path. The driver verifies this before
`H`. This is an integrity check, not a cryptographic hash. `T` returns `DONE`
without touching SDRAM; `--probe` uses it to check the UART and correct image.

Guest request and host response:

```
@FPR1 ssssssss oo llllllll payload_as_hex cc\n
```

All fields are ASCII, sequence is eight hex digits, operation/status two,
length eight, checksum two (XOR of payload bytes). Request operations:
1 read, 2 exists, 3 replace, 4 append, 5 environment, 6 monotonic time, 8 input.
Status is 0 success or 1 error. Replace/append payload is UTF-8 path, NUL,
contents. Replies are limited to 1 MiB. Each consumed response character is
acknowledged with `+`; the host waits before sending the next. This protects
the one-byte hardware receiver during parsing and allocation. Each awaited
character has a five-second local timeout. Hex encoding keeps binary ETX out
of the UART stream; Ctrl-C still cancels execution and drains an accepted
memory operation.

The host only opens relative paths resolving inside `--root`, including
symlink checks. It does not run commands or inherit environment entries.
The `DONE` halt marker alone cannot pass a test: the runner also requires
`FPR EXIT 0`. An interrupted binary upload may require the board reset button
or reloading SRAM; arbitrary payload bytes cannot also act as reset commands.

## Focused checks

```bash
python3 tests/check_tangnano20k_virtual.py
python3 tests/check_tangnano20k_clock.py # RV64 IM/IMC RTL clock, soft-float and selective-receive refusal
# Optional host software-float check, from the same pinned source:
make -C /path/to/softfloat/build/Linux-x86_64-GCC -j4 SPECIALIZE_TYPE=RISCV
clang -O1 -fno-builtin -fsanitize=undefined,address \
  -I /path/to/softfloat/source/include machine/tangnano20k/softfloat.c \
  tests/tangnano20k_softfloat.c \
  /path/to/softfloat/build/Linux-x86_64-GCC/softfloat.a -o /tmp/board-softfloat
/tmp/board-softfloat
FPR_SOFTFLOAT_ROOT=/path/to/softfloat machine/tangnano20k/build.sh \
  tests/tangnano20k_wasm.fpr "$PWD/build/tangnano20k-wasm"
python3 tools/run_tangnano20k_base.py build/tangnano20k-wasm/base.bin \
  --root tests/fixtures/uart-device --freq-mhz 27 --timeout 180
```

## Physical verification, 2026-10-06

Using the RV64 27 MHz SRAM image described in HaskPlayground's RV64 README:

```
RV64 BASE 4294967297
SOFT FLOAT 9
VIRTUAL ENV connected
UNAVAILABLE REFUSED
VIRTUAL FILE UART write + append
FPR EXIT 0
DONE
```

`tests/tangnano20k_base.fpr` exercises the existing stdlib interfaces against
this host, including file replacement, append and refusal of stream-open.
The WASM probe links the existing `examples/wasm/wasmvm.fpr` and `wat.fpr`
without changes, reads `answer.wat` through the UART virtual file device and
runs its `answer` export (6*7). Hardware returned:

```
WASM BOARD 42
FPR EXIT 0
DONE
```

The WASM image is about 1.2 MiB plus 54 KiB BSS. This proves a small guest on
this host, not all WASM opcodes, the full desktop suite, or a larger benchmark.
The core's 1,628 independent RV64 reference cases and its trap/recovery checks
also passed physically. Focused host software-float checks cover fixed IEEE
bit patterns, conversions, NaNs and sqrt; they are not full TestFloat testing.

The [decision-tree board experiment](../../docs/2026-10-17-TANG-NANO-DTREE.md)
reuses the existing FP-RISC classifier with reduced histogram sizes. Physical
32-, 128- and 512-row training runs pass on the RV64IMC 27 MHz image, including
independent prediction digests and held-out accuracy checks. Its runner and
software-float vector regression are in `tests/check_tangnano20k_dtree.py` and
`tests/check_tangnano20k_softfloat_vectors.py`.

The build checks the linked ELF's ISA attributes and flags. Its default IM mode
refuses C; the explicit `FPR_RVC=1` mode permits C. Both refuse atomic and
hardware floating-point extensions and incompatible ABI libraries. The
host driver validates frame bounds, checksum and sequence; local negative
checks cover unavailable services, missing files and escaping paths/symlinks.

`tests/tangnano20k_unavailable.fpr` deliberately calls `myself 0`. Its expected
result is a named panic and `FPR EXIT 1`; the normal runner must reject it,
confirming that an actor stub cannot pass as a successful program. This check
also passed on the physical RV64 board: `Base: myself unavailable`, failing
runtime exit and host refusal.
