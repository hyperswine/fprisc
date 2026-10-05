# Tang Nano 20K: builtin on SimpleRisc RV32IM

This implements the board-port recipe in
[BAREMETAL-BUILTIN](2026-09-18-BAREMETAL-BUILTIN.md): replace startup, the
linker RAM map, console/exit behavior and raw machine primitives. The reference
RV64 QEMU build remains the default. `BUILTIN_BOARD=tangnano20k` selects the new
board files in `machine/builtin/tangnano20k/` and the compiler's RV32 backend.

The target is the **HaskPlayground SimpleRisc soft processor**, not the BL616
USB bridge or another processor on the board. It needs the current RV32IM,
64 KiB RAM bitstream. The FPGA image is loaded separately; compiling an FP-RISC
program does not synthesize or reconfigure the FPGA.

## Build and run

From the `fprisc` repository, with `riscv64-unknown-elf-gcc` installed:

```sh
make bare-metal-builtin BUILTIN_BOARD=tangnano20k \
  PROG=tests/builtin_tangnano20k.fpr \
  BUILD=build/tangnano20k IMAGE=build/tangnano20k/builtin.elf

python3 tools/run_simple_risc.py build/tangnano20k/builtin.bin \
  --port /dev/cu.usbserial-20250303171 --freq-mhz 96
```

Or use `bare-metal-builtin-run` with the same build arguments and
`SIMPLE_RISC_FLAGS='--port /dev/cu.usbserial-20250303171 --freq-mhz 96'`.
Choose the FPGA UART interface, not the JTAG serial interface. The port path is
an example from the tested board; use the actual connected device.

The tested bitstream from the preceding HaskPlayground hardware run is
`../HaskPlayground/output/tangnano20k/simple_risc.fs`. Reload it into
volatile SRAM when necessary:

```sh
~/Documents/Libs/oss-cad-suite/bin/openFPGALoader -b tangnano20k \
  ../HaskPlayground/output/tangnano20k/simple_risc.fs
```

That artifact is generated locally, not shipped in this repository. To rebuild
the FPGA from source, use HaskPlayground's board build script with
`FREQ_MHZ=96`, then load its `simple_risc.fs`. Match `--freq-mhz` to the image
actually loaded. The UART divider is 868 clocks per bit: 96 MHz needs 110,599
baud. The loader uses macOS `IOSSIOSPEED` for arbitrary speeds. On other systems
it currently accepts only standard termios baud rates. `--baud` overrides the
derived rate. The CPU test is polling UART, 8-N-1.

Expected output:

```text
TANG NANO BUILTIN HOLDS
FPR EXIT 0
DONE
```

`DONE` by itself is not proof of success: SimpleRisc emits it for illegal
instructions and other unexpected halts too. The new runtime prints an explicit
exit marker before ECALL. The host loader returns failure on panic, timeout or a
halt without the successful runtime marker. It handles partial writes and
fragmented reads, keeps one exclusive port session open, and stops the CPU with
Ctrl-C before closing it to avoid the documented BL616 close/reopen wedge.

## Interactive example: factorial over the UART

`examples/tangnano20k_fact.fpr` prints `n?`, reads a decimal line and
answers with `n!` until it reads an empty line. It drives the UART directly
with `Mem.read8` on STATUS (`0x1000_0004`, bit 1 = byte waiting) and RXDATA
(`0x1000_0008`, a load consumes the byte); no C driver is involved. The two
register addresses are built once, because in manual mode every `Word` and
`Addr` value is a heap box. `Int` is 31 bits on RV32, so 12! is the largest
answer; larger numbers and non-digits get an error line.

```sh
make bare-metal-builtin BUILTIN_BOARD=tangnano20k \
  PROG=examples/tangnano20k_fact.fpr \
  BUILD=build/tangnano20k-fact IMAGE=build/tangnano20k-fact/fact.elf

python3 tools/run_simple_risc.py build/tangnano20k-fact/fact.bin \
  --port /dev/cu.usbserial-20250303171 --freq-mhz 96 \
  --prompt 'n?' --input 5 --input 0 --input 12 --input 13 --input ''
```

SimpleRisc's receiver holds one byte, and a byte that arrives while the
program is printing is lost. `--prompt TEXT` therefore sends the next
`--input` line only when TEXT appears in the output, so each line arrives
while the program is waiting for it. The prompt text must not appear anywhere
else in the output, or a line is sent early.

On 2026-10-05, on the 96 MHz bitstream above, the image (10,624 bytes of
code) printed `5! = 120`, `0! = 1` and `12! = 479001600`, refused 13, `abc`
and 99999, and ended with `FPR EXIT 0`.

## Machine and value contracts

- Code loads at address zero. Unified RAM is exactly `[0, 65536)`. Startup sets
  `gp` and `sp`, clears BSS, initializes the hart spill/render context and the
  heap, then calls the generated `main`. No FPU setup. The current processor
  supports Zicsr and direct machine traps; startup/exit clear `mtvec` for the
  legacy host `DONE` protocol.
- The upper 8 KiB is reserved for the downward-growing stack. The linker refuses
  an image leaving less than 4 KiB between BSS and the stack reservation for the
  heap. There is no runtime stack-overflow guard; call depth is the program's
  responsibility. `BUILTIN_HEAP_BYTES` may reduce the heap for tests.
- `Int` is signed with 31 payload bits (range `-2^30 .. 2^30-1`), while `Word`
  and `Addr` preserve all 32 bits. `Word.bits Unit` returns 32. Header fields stay
  at byte offsets 0 and 4; object fields begin at offset 8 and use 4-byte words.
  The existing allocator's 16-byte allocation prefix and alignment are retained.
- This port uses manual ownership and `heap.c`. `Rc.retain` and `Rc.release`
  work for the documented acyclic supported values. Word/address results are
  boxed, raw buffers still need `Mem.free`, and callers manage owning aliases.
  ARC, raw units and C exports remain RV64-only and are refused on RV32.
- F64 is refused before code generation, including imported definitions: a
  64-bit float cannot fit this one-word value ABI. This is not a float or vector
  portability milestone.
- TXDATA is `0x10000000`, STATUS is `0x10000004` (TX-ready bit 0); these are
  SimpleRisc registers, not QEMU's 16550 register layout. Console output preserves
  LF. Exit clears `mtvec`, then ECALL halts this core and returns control to
  its UART programming protocol.
- Byte, halfword and word accesses are volatile, with alignment checked in the
  common builtin adapter. `Mem.fence` emits the supported fence instruction.
  Instruction fencing uses SimpleRisc's coherent instruction/data RAM behavior.
  `CPU.csrRead`/`CPU.csrWrite` dispatch to real instructions for the implemented
  status, trap, scratch and identification CSRs. Unknown CSR numbers panic;
  writes to read-only CSRs raise a hardware illegal-instruction exception.
  Writable `mcycle`/`minstret` halves and their read-only `cycle`/`instret`
  aliases are supported. IRQ, wait and atomic operations still panic
  explicitly. Internal runtime locks
  use a board-only single-core path: there are no interrupts or other harts,
  so a held lock indicates forbidden re-entry. This does not emulate user atomics.
- Unsupported services still fail at link time. No actor scheduler, QOS service
  layer, interrupts or multicore support is supplied by this port.

## Verification on 2026-10-05

```sh
python3 tests/check_tangnano20k.py \
  --port /dev/cu.usbserial-20250303171 --freq-mhz 96
python3 tests/check_builtin.py
```

The new suite checks the linked image for scheduler/fuel/QOS dependencies,
unresolved symbols and unsupported ISA instructions; rejects an oversized image
and unsupported ARC/F64 configurations; and exercises the UART host against a
pseudo-terminal for fragmented output, successful exit, panic, bare halt and
timeout. Without `--port`, it explicitly skips physical FPGA tests.

On the connected Tang Nano 20K, first at 51 MHz and then at 96 MHz with the
revised HaskPlayground processor, repeated compiled FP-RISC runs passed
tail recursion, shared-node release with allocation-count recovery, 32-bit word
width/high-bit shifts/wraparound, byte/halfword/word memory, realloc preservation,
free and fences. Hardware failure cases passed for shift 32, an overflowing
mask, unaligned access, heap exhaustion, CSR, IRQ and atomic operations. A final
successful program load checked recovery after the failures.

The existing RV64 QEMU builtin suite also passed, including invalid-operation
panics, separate profile caches and the C heap/refcount tests under ASan/UBSan.
The 96 MHz FPGA build uses eight clocks per ordinary instruction, one-hot
control, registered register-file reads/writeback, RAM input/output and
load/store alignment. Seed 2 routed at an estimated 149.08 MHz; actual hardware
passed five exact C arithmetic runs, UART echo/reset/clear recovery, memory
stress and 30,720 RV32M reference checks before this builtin suite. The loader
and test suite now default to 96 MHz; use `--freq-mhz 51` for older 51 MHz images.

This does not establish arbitrary program stack bounds, ARC on RV32, or support
for facilities absent from SimpleRisc.

Larger memory and compute workloads, measured execution times, and the 98.72%
heap / explicit-exhaustion checks are recorded in
[the board stress results](2026-10-05-TANG-NANO-STRESS.md).

## Later clock sweep

The processor now passes the expanded CPU and workload tests at 114 MHz after
registering the barrel shifter. 117 MHz produced incorrect sieve results and
120 MHz failed an ALU check. The earlier 96 MHz results above describe their
original coverage; the expanded ALU test subsequently exposed shift errors
in that older image. See [the clock retest](2026-10-05-TANG-NANO-CLOCK-SWEEP.md)
for current evidence and commands. Match `--freq-mhz` to the loaded bitstream.

## Machine-mode continuation

The processor and this runtime now build with `rv32im_zicsr_zifencei`.
`tests/builtin_tangnano20k_csr.fpr` exercises the software-visible CSR adapter;
`tests/check_tangnano20k_csr.py --port /dev/cu.usbserial-20250303171
--freq-mhz 96` builds it and requires three exact success runs on the board.
The full Tang Nano harness includes the same fixture and retains the unknown
CSR refusal test. Trap-handler execution and `mret` are tested by
HaskPlayground's `boards/tangnano20k/c/traps.c` and `check_traps.py`.
At 96 MHz, the full harness passes the host/link/ISA/loader checks, three
builtin smoke runs, three CSR runs, all seven refusal cases and recovery.
The final CSR fixture leaves `mtvec` nonzero to test runtime exit cleanup;
the focused CSR harness passes all three physical runs with that fixture.
Matching HaskPlayground image SHA-256:
`a2e89522be688958329a7f96be16d72840813ad5dd1820c2bcc5cac70a17f81c`.
The C trap-handler test in HaskPlayground passes 89 assertions on each of
three board runs. The counter continuation below completes the planned
step 1 scope.

These results used the current fprisc compiler/runtime, including the I64
work committed separately as `8c5bd0a`. The CSR target changes do not modify
the compiler/runtime. The target harness accepts the updated F64 refusal
diagnostic wording while still checking the 64-bit ABI restriction.

## Split counter continuation

The CSR adapter now supports writable `mcycle`/`mcycleh` and
`minstret`/`minstreth`, and read-only `cycle`/`cycleh` and
`instret`/`instreth` aliases. Counter aliases use the same hardware access
rules; attempted writes trap. Unknown CSR numbers still panic in the adapter.
The updated FP-RISC fixture writes the halves, forces cycle rollover, checks
high aliases and increasing retirement, then leaves its trap vector installed
to verify exit cleanup.

On the final matching 96 MHz processor image, `tests/check_tangnano20k.py
--port /dev/cu.usbserial-20250303171 --freq-mhz 96` passes all host/link/ISA
checks, three builtin smoke runs, three updated CSR fixture runs, seven
refusal cases and recovery. HaskPlayground's C counter fixture passes 270
assertions and its trap fixture passes 267 assertions; the CPU regression and
30,720 RV32M / 3,840 RV32I comparisons also pass.

Matching image SHA-256:
`3c29163eb1375600f2b5e22ac953f68c6af0c487ac39d12e202e603275b58958`.
It uses placement seed 2 and a 144 MHz route target (estimated maximum
147.19 MHz), with actual operation checked at 96 MHz. The first placement's
higher-than-96 timing estimate did not prevent physical failures; see
HaskPlayground's `boards/tangnano20k/MACHINE-MODE-2026-10-05.md` for both
placements and the 72 MHz diagnostic checks.

TIME, interrupt sources and official architecture-test coverage remain later
roadmap work. This is not a full Zicntr or higher-clock claim.
