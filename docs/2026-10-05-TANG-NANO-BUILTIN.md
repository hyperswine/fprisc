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
  LF. Exit writes the finisher at `0x00100000`, preserving `mtvec` and
  returning control to the UART programming protocol. Success uses `0x5555`;
  failure uses `(code << 16) | 0x3333`. The host still receives `DONE` after
  the existing `FPR EXIT` status text.
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

## Explicit exit continuation

`hal_poweroff` now writes the processor's registered finisher device at
`0x00100000` instead of clearing the trap vector and executing ECALL.
The startup fallback calls `hal_poweroff(1)` if the runtime unexpectedly
returns. Normal exit and panic retain their existing printed status and
`DONE` protocol. This runtime requires the finisher-enabled processor image;
older processor images do not map the new address.

The CSR fixture leaves a nonzero trap vector installed, so its board run
checks that termination bypasses guest trap handling. The host harness also
checks linked `hal_poweroff` for the finisher address/store and rejects ECALL
or trap-vector clearing in that adapter. RAM and stack layout remain unchanged
in this first step 3 slice; registered bus, RAM relocation and boot ROM are
next.

On the finisher-enabled image at 96 MHz, the complete Tang Nano harness
passes the host/link/ISA/loader checks, three smoke runs, three counter/CSR
runs leaving `mtvec` nonzero, all seven panic/refusal cases and recovery.
HaskPlayground's 15 finisher cases, 270 counter assertions, 267 trap assertions,
CPU/UART/memory checks and 34,560 RV32IM reference comparisons also pass.
The final image uses seed 3 and a 144 MHz route target, with an estimated
maximum of 144.61 MHz. Its SHA-256 is
`f25b38e65bec2678de2bb902a1cafa834a4205853efb2e90ae28ec04e3ee9762`.
Loads/stores gain one device-selection stage; ordinary arithmetic stays at
eight clocks. The board is left on this 96 MHz SRAM image; flash is unchanged.

## Registered data bus continuation

HaskPlayground now routes CPU data accesses through registered requests and
responses, with the bus owning RAM timing, UART side effects and finisher
completion. The CPU keeps the faulting PC until completion. Signed byte loads
from UART RX now sign-extend correctly, and an empty read coinciding with a
new byte preserves it for the next read. RAM stays at zero; the runtime ABI,
linker layout and host protocol remain unchanged in this slice.

The complete Tang Nano harness passes at 96 MHz on the new image: all
host/link/ISA/loader checks, three smoke runs, three CSR runs with a nonzero
trap vector, seven panic/refusal cases and recovery. HaskPlayground also
passes 3,852 mixed-width RAM/RX checks, 15 finisher cases, 270 counter and
267 trap assertions, the CPU regression and 34,560 RV32IM comparisons.
All Haskell suites pass, including 30 SimpleRisc properties, and generated
RTL returns `HiDONE`.

The final image uses seed 7, a 144 MHz route target and a modeled maximum of
144.61 MHz, with 8,161 LUT4s, 2,832 flip-flops and 32 BSRAM blocks.
SHA-256: `7ff9d560cff604e7b05983bf68385c02c46b23212cb1e443b264b0bf6ae3afc2`.
The board is left on this 96 MHz SRAM image; flash is unchanged. RAM relocation,
boot ROM and removal of the hardware loader/legacy halt rules remain next.

## Gowin execution timing experiment (2026-10-06)

HaskPlayground's execution stage now registers decoded controls and ALU
operands, then registers candidates and split 16-bit comparison flags before
selecting results. CSR selection is registered separately. Ordinary
instructions take nine clocks, shifts ten and CSR reads eleven. Iterative
multiply/divide retains its unit latency. RAM layout, builtin runtime ABI,
finisher, loader and UART contracts remain unchanged.

The licensed Gowin 108 MHz placement passes internal setup/hold timing:
108.038 MHz estimated maximum, +0.003 ns worst setup slack, zero setup/hold
violating endpoints. The final 111, 114 and 120 MHz trials fail timing and
were not loaded. This is a narrow margin, not a temperature/voltage stress
qualification. HaskPlayground's experiment report records all placements.

At 108 MHz the complete Tang Nano harness passes host/link/ISA/loader checks,
three smoke runs, three CSR runs, seven panic/refusal cases and recovery.
The board also passes 3,852 bus/RX assertions, 15 finisher cases, 270 counter
assertions, 267 trap assertions, CPU/UART/memory checks and 34,560 RV32IM
reference comparisons. All Haskell suites pass, including 33 SimpleRisc
properties; generated RTL returns `HiDONE`.

108 MHz image SHA-256:
`77bcc3dcc58aa8a3f9134c2341564090a98b3535d304b70b1dcbbb488c0b2e7a`.
Use `--freq-mhz 108` with the board runner/harness for that image; default
frequency remains 96 MHz. SRAM programming leaves flash unchanged.

The final split-comparison image also passes the complete board and FP-RISC
harness at 96 MHz. Vendor timing reports 96.252 MHz maximum, +0.027 ns setup
slack and zero setup/hold violations. Its SHA-256 is
`e8394da4ec3b4c92bfa338d3900d173591afae765230a6e7a79399c786890d88`.
The board is left on the tested 108 MHz SRAM image; flash is unchanged.

## SDRAM main memory (2026-10-06)

HaskPlayground provides a separate SDRAM processor with a unified 1 KiB cache,
now physically tested at 66 MHz (54 MHz remains the build default).
Its controller passes all 8 MiB with 12,582,912 word comparisons, independent
byte-mask writes and 250 ms retention under refresh. The integrated C core
passes a 1 MiB full working-set check, all four bank ends and the last RAM
word/byte lanes, alongside the CPU/bus/finisher/counter/trap/RV32IM suites.
Vendor internal timing passes at 66 MHz with only +0.038 ns setup slack; SDRAM
I/O signoff and more clock margin are still work to do. This prototype does not meet the roadmap's 96 MHz gate.

`BUILTIN_RAM=sdram` selects an 8 MiB linker map at `0x80000000`, with a 64 KiB
stack reservation. The ordinary board option retains its 64 KiB BRAM map.
The existing complete builtin harness passes on the cached SDRAM core's zero
alias at 66 MHz.
A high-linked fixture allocates 2 MiB, checks 32 samples at 64 KiB intervals
and its last byte, frees it and prints `FPR EXIT 0` followed by `DONE`. This
fixture also passes on the physical cached board at 66 MHz.
A denser 2,048-sample fixture exceeded its 30/60 second budgets after allocation;
its verification loop is not claimed as passing and needs separate profiling.

```bash
make bare-metal-builtin BUILTIN_BOARD=tangnano20k BUILTIN_RAM=sdram \
  PROG=tests/builtin_tangnano20k_sdram.fpr \
  BUILD=build/tangnano20k-sdram IMAGE=build/tangnano20k-sdram/builtin.elf
python3 tools/run_simple_risc.py build/tangnano20k-sdram/builtin.bin \
  --port /dev/cu.usbserial-20250303171 --freq-mhz 66 \
  --ram-base 0x80000000 --timeout 60
```

The runners use the new `H` command for high-address entry, preserving `R`
for existing images. Loader images remain limited to 64 KiB; BSS, heap and
stack may use the rest of SDRAM. `M` clears only the zero-address compatibility
region. The hardware loader, boot ROM and legacy halt cleanup remain roadmap
work. The board is left on the tested cached 66 MHz SDRAM SRAM image, SHA-256
`0d4e7e54fe6e70ea7f268aa8f3ce8337ffa0c8065c3caec4cbdd2365ffc06565`;
flash is unchanged.


The cache uses physical tags and writes through after invalidating the indexed
line, so low/high aliases, loader writes and instruction modifications remain
coherent. A C repeated-read benchmark improves from 54.322 ms uncached at
54 MHz to 36.207 ms cached at 66 MHz, about 1.50x throughput. This is a measured
C workload result, not a general FP-RISC performance claim. The earlier dense
FP-RISC allocation fixture has not been re-profiled. Further clock work should
address the routed processor state path and SDRAM timing/clock-domain separation.

## Separate Base/RV64 host, 2026-10-06

For `profile base.` on the new RV64IM FPGA image, see
[machine/tangnano20k/README.md](../machine/tangnano20k/README.md). That host has
8 MiB SDRAM, software floating point and rooted UART virtual-device services,
with explicit errors for unavailable operations. It builds through its own
script; `BUILTIN_BOARD=tangnano20k` here continues to select the RV32 Builtin
port. Each host requires its matching FPGA image and clock.
