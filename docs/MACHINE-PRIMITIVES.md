# Opaque machine primitives (BareMetal–Builtin RV64)

FP-RISC calls a small hardware interface; hardware-specific instructions do not
need to become new language constructs. The reference implementation is
`hal/builtin/machine.S`, using the ordinary RV64 integer register ABI. Its public
C declarations and preconditions are in `machine.h`.

The raw assembly functions take/return full-width integers and addresses in
registers. They allocate nothing and perform no reference counting. The current
FP-RISC adapters in `unsafe.c` unbox arguments and box Word/Addr results. Both the
manual profile and opt-in automatic ARC profile can call them. ARC adapters consume
owning arguments; the underlying primitive borrows them and returns either a fresh
Word, an immediate Int or an immortal Bool/Unit. No raw register value is passed
to retain/release. This does **not** yet make FP-RISC Word arithmetic allocation-free.

## Language API

Existing `Word.and/or/xor/not/shl/shr`, `Mem.read8/read16/read32/readWord`,
corresponding writes, and `Mem.fence` now call the raw assembly layer. Their
previous types, full-width behavior, truncation rules and alignment checks remain.
The new calls are:

| Primitive | Type | Contract |
| --- | --- | --- |
| `Word.bitSet`, `Word.bitClear` | `Word -> Int -> Word` | Return a fresh word; index 0–63 |
| `Word.bitTest` | `Word -> Int -> Bool` | Test one bit; index 0–63 |
| `CPU.csrRead` | `Int -> Word` | Read a RISC-V CSR, address 0–4095 |
| `CPU.csrWrite` | `Int -> Word -> Unit` | Write a CSR |
| `CPU.irqSave` | `Unit -> Int` | Clear machine interrupt enable; return previous MIE bit (0 or 8) |
| `CPU.irqRestore` | `Int -> Unit` | Restore only MIE from a saved token; reject other values |
| `CPU.irqEnable` | `Unit -> Unit` | Set MIE; caller must have configured interrupt sources/handlers |
| `CPU.wait` | `Unit -> Unit` | Execute WFI; may return spuriously, or wait indefinitely |
| `CPU.instructionFence` | `Unit -> Unit` | Local-hart `fence.i` |
| `Mem.atomicExchange` | `Addr -> Word -> Word` | Atomic 64-bit exchange; return previous value |
| `Mem.compareExchange` | `Addr -> Word -> Word -> Word` | Address, expected, desired; return observed old value, whether or not replaced |

`CPU.irqSave` and `irqRestore` do not allocate boxes: their token is a tagged Int.
Tokens nest correctly when restored in reverse order. These calls do not disable
non-maskable events, configure individual sources, or create a lexical critical
section automatically. Restoring/enabling interrupts can deliver a pending interrupt
before the call returns. They preserve the other `mstatus` bits.

Bit operations are pure. Memory reads/writes, CSR accesses, IRQ controls, atomics,
fences and WFI are observable operations. The current compiler emits real ordered
calls, and the out-of-line assembly loads/stores cannot be optimized away by the C
compiler. A future optimizer must preserve these effects, including reads that may
access devices or CSRs with side effects. Calls alone are not hardware memory barriers;
use the appropriate fence. `Mem.fence` is `fence iorw, iorw`.

Atomics require naturally aligned eight-byte locations in ordinary RAM. Exchange
uses `amoswap.d.aqrl`; compare-exchange uses an LR/SC retry loop with acquire on the
read and release on a successful write (failure performs an acquire read). They
are not a promise that arbitrary MMIO supports atomic operations. Ordering across
the memory/I/O domains requires appropriate fences. The allocator and ARC remain
single-threaded and non-reentrant; adding atomic primitives does not change that.

## CSR dispatch and trap behavior

The CSR number is encoded in the instruction, so a runtime CSR index needs
dispatch. Each access kind has a read-only executable table of 4096 eight-byte
instruction slots. This covers the complete architectural CSR address space without
an arbitrary software allowlist. Each table costs 32 KiB of code if linked; unused
access kinds are discarded. Future constant-argument lowering can remove this cost
for programs using fixed CSR addresses without changing the API.

Out-of-range CSR numbers panic. In-range addresses are executed as requested:
unimplemented, privilege-forbidden or read-only writes raise hardware exceptions.
Read uses CSRRS with zero source; write uses CSRRW with zero destination, avoiding
an unwanted CSR read. The caller remains responsible for privileges, WARL fields
and changing processor state safely. Examples on QEMU virt include `mstatus=768`,
`mie=772`, `mtvec=773`, `mscratch=832`, and `mhartid=3860`.

```text
scratchTest =
  saved = CPU.csrRead 832;
  _ = CPU.csrWrite 832 (Word.bitSet (Word.fromInt 0) 63);
  observed = CPU.csrRead 832;
  _ = CPU.csrWrite 832 saved;
  Word.bitTest observed 63.
```

Startup installs a **fatal fallback trap vector**, with a separate 4 KiB emergency
stack. It prints `mcause`, `mepc` and `mtval` without allocating and exits QEMU with
failure. It does not resume interrupted execution and does not invoke an FP-RISC
handler. A resumable interrupt-handler ABI (register preservation, stack/context
rules and `mret`) is still needed. Writing `mtvec` yourself replaces the fallback;
only point it at a valid target-specific entry stub. Do not call the allocator or
ARC from an interrupt handler while interrupted code may be using them.

Instruction fencing is local to the current hart; it does not synchronize remote
instruction caches. Board setup, exception policies and multicore coordination remain
outside these primitives. Other harts are still parked by the reference boot code.

## Validation

```
make bare-metal-builtin-run ARC=1 ARC_CHECK=1 PROG=tests/builtin_machine.fpr
python3 tests/check_machine.py
```

The tests exercise full-width CSR round-trips, bit indices at the word boundary,
atomic replacement and mismatch paths, nested IRQ tokens, fences, both ownership
modes, and zero live allocations after the ARC test. Negative tests cover argument
ranges, alignment, a real illegal CSR write, and actual CLINT software-interrupt
delivery to the fatal handler. Instruction disassembly is checked for the atomic
and instruction-fence operations. Existing memory and ARC suites remain applicable.

WFI wakeup behavior, multicore contention, resumable interrupt handlers and physical
hardware have not been validated by this suite.

Instruction contracts follow the official RISC-V specifications:
[CSR instructions](https://docs.riscv.org/reference/isa/unpriv/zicsr.html),
[atomic instructions](https://docs.riscv.org/reference/isa/unpriv/a-st-ext.html),
and [the ISA manuals](https://docs.riscv.org/reference/isa/).
