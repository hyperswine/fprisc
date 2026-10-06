# Tang Nano 20K: single-core Base host and UART virtual device

This is an experimental RV64IM Base host, separate from the established RV32
Builtin target. It uses HaskPlayground's `boards/tangnano20k/rv64` image, cached
8 MiB SDRAM, a 64 KiB stack and the usual tagged 63-bit FP-RISC Int representation.
The initial CPU clock is 27 MHz. This is a single execution thread; the Base
actor scheduler, interrupts, processes and dynamic stack growth are unavailable.

The program keeps `profile base.` and uses the ordinary `core/prelude.fpr` and
stdlib. No interpreter or guest logic runs on the computer: only explicit host
services go through the virtual device. The shared compiler/runtime still own
FP-RISC semantics. The board C code supplies allocation, UART and ABI mechanisms.

## Current capability surface

| Facility | Implementation |
| --- | --- |
| Console / successful or failing exit | Local UART / finisher |
| Int, Word, Addr, I64 | Native 64-bit values / existing runtime |
| F32 / F64 arithmetic | Software floating point; no hardware FPU |
| Whole-file read, exists, replace, append | Rooted host file device over UART |
| `Sys.env` | Explicit `--env NAME=value` entries; no host environment inheritance |
| `Sys.timeUs` | Host monotonic microseconds |
| `Sys.readLine` | Explicit `--input` lines, then EOF |
| `Sys.args` | Empty list in this initial host |
| `Sys.sleepUs` | Local cycle-counter wait |
| Stream files, directory APIs, watch-open | `Err` with a named unavailable capability |
| Actors, IRQ routing, polling/watch operations without a Result error channel | Named panic / failing exit |
| Unlisted primitives | Link failure; never automatic success stubs |

The allocator is the existing single-threaded coalescing heap. Base's temporary
VM allocations are not automatically reclaimed. The documented desktop WASM
suite peaks around 100 MB and does not fit this board. Full Base scheduling,
garbage collection and the full WASM suite are not claimed.

## Build

From fprisc:

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
and compiles **every** C/software-float object for `rv64im`, `lp64`, `medany`.
The installed toolchain's generic hard-float libraries are not linked.

SoftFloat is pinned to Berkeley SoftFloat revision
`a0c6494cdc11865811dec815d5c0049fba9d82a8`, RISCV specialization, rounding to
nearest-even. [Upstream](https://github.com/ucb-bar/berkeley-softfloat-3).
`SOFTFLOAT-LICENSE` retains its license. The `softfloat.c` bridge supplies GCC's
soft-float ABI and uses the same package for sqrt. Exception flags remain
internal to the software library; RV64IM has no floating-point CSR state.

## UART protocol

The RV64 loader adds `Q`, a little-endian 32-bit count of 32-bit words, image
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

The build checks the linked ELF's ISA attributes and flags, refusing libraries
that declare compressed, atomic or hardware floating-point extensions. The
host driver validates frame bounds, checksum and sequence; local negative
checks cover unavailable services, missing files and escaping paths/symlinks.

`tests/tangnano20k_unavailable.fpr` deliberately calls `myself 0`. Its expected
result is a named panic and `FPR EXIT 1`; the normal runner must reject it,
confirming that an actor stub cannot pass as a successful program. This check
also passed on the physical RV64 board: `Base: myself unavailable`, failing
runtime exit and host refusal.
