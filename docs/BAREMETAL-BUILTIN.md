# BareMetal–Builtin: standalone unsafe execution

This is an initial standalone RV64 implementation, not yet a complete C
replacement. It uses the same syntax, type inference, strict evaluation,
first-class functions, ADTs and linearity checks as other native builds.
There is no implicit prelude, actor scheduler, fuel decrement, QOS process,
filesystem, device service or transaction layer. Cost/termination checking is
not required in this unsafe profile. This does **not** disable type checking.

```
make bare-metal-builtin-run PROG=tests/builtin.fpr
```

The reference board is QEMU `virt`, RV64, 128 MiB RAM, machine mode. Hart 0
runs `main`; other harts park. Returning from `main` exits QEMU successfully;
use `print` for output. The default trap vector reports processor faults and
terminates. ARC builds may provide a checked `machineInterrupt` handler that
resumes execution (see below). This has not been validated
on physical hardware.
The existing `make bare-metal` remains the actor-enabled build.

The compiler flag is `--profile=bare-metal-builtin`. Its module cache is
separate from scheduler-instrumented code. Other ISA targets and RVV are
currently rejected for this profile. Custom preludes may be explicitly
selected, but must only use facilities supplied by the standalone link.

## Word and address API

`Int` remains a signed tagged integer with 63 payload bits on RV64. `Word`
and `Addr` are distinct opaque types that preserve all 64 bits. They are
unboxed in automatic ARC builds: arithmetic, conversions and raw memory accesses
do not allocate. The default manual-ownership ABI still uses heap boxes. `==`/`!=` compare their values; explicit `Word.eq` and
`Addr.eq` are also available. Their current generic printed form is signed
numeric, not a hexadecimal address formatter.

| Operation | Type / behavior |
| --- | --- |
| `Word.fromInt` | `Int -> Word`; sign extends negative numbers |
| `Word.toInt` | `Word -> Int`; keeps the low 63 bits and interprets them as signed |
| `Word.bits` | `Unit -> Int`; 64 on this implementation |
| `Word.and`, `or`, `xor`, `add`, `sub` | `Word -> Word -> Word`; arithmetic wraps modulo 2^64 |
| `Word.not` | `Word -> Word` |
| `Word.shl`, `shr` | `Word -> Int -> Word`; logical shifts, count 0–63 |
| `Word.mask` | `Int -> Int -> Word`; width then bit offset; zero/full-width masks supported |
| `Word.eq` | `Word -> Word -> Bool` |
| `Addr.fromWord`, `Addr.toWord` | lossless conversion between `Word` and `Addr` |
| `Addr.add` | `Addr -> Int -> Addr`; byte displacement, modular address arithmetic |
| `Addr.null` | `Unit -> Addr` |
| `Addr.eq` | `Addr -> Addr -> Bool` |

Invalid shift counts and masks panic instead of invoking C shift undefined
behavior. Mask width and offset must be nonnegative and sum to at most 64.

## Raw memory API

| Operation | Type |
| --- | --- |
| `Mem.read8`, `read16` | `Addr -> Int` |
| `Mem.read32`, `readWord` | `Addr -> Word` |
| `Mem.write8`, `write16` | `Addr -> Int -> Unit` |
| `Mem.write32`, `writeWord` | `Addr -> Word -> Unit` |
| `Mem.alloc` | `Int -> Addr` |
| `Mem.realloc` | `Addr -> Int -> Addr` |
| `Mem.free` | `Addr -> Unit` |
| `Mem.fence` | `Unit -> Unit` |

Accesses are volatile and native endian. Writes truncate to the requested
width. Alignment is checked; validity, mapping, access permissions, device
protocol and lifetime are the caller's responsibility. `Addr.fromWord` permits
arbitrary addresses, including MMIO. Volatile alone does not order hardware;
`Mem.fence Unit` emits RISC-V `fence iorw, iorw`. CSR access, interrupt masking, atomic operations and instruction fencing are
provided by the [opaque machine primitive API](MACHINE-PRIMITIVES.md).

Allocation sizes are bytes. Negative sizes, overflow and exhaustion panic.
`Mem.alloc 0` returns null. Reallocating null allocates; reallocating to zero
frees and returns null. Otherwise it preserves at least `min(old,new)` bytes;
growth may move the allocation. Shrinking may retain capacity. Freeing null is
a no-op. Use the returned address after reallocating and discard old aliases.
Only allocation-start addresses from this allocator may be freed/reallocated.
These operations are for raw buffers, not arbitrary live language objects.

An `Addr` never owns the memory it points to. In the manual ABI, `Mem.free p` frees that
buffer; `Rc.release p` releases only the address box. Likewise `Addr.add`
creates another box, not another ownership claim on the buffer. Word operations
and reads returning `Word` also create boxes. Automatic ARC uses raw `Word`/`Addr` bits instead of these boxes; the manual mode
requires explicit lifetime management.

## Allocator and manual reference counting

`hal/builtin/heap.c` implements the runtime ABI `fpr_alloc`, `fpr_realloc`,
`fpr_free`, plus `fpr_builtin_retain` / `fpr_builtin_release`. The caller supplies
a RAM interval with `fpr_builtin_heap_init(start,end)`. Blocks split and coalesce;
there are no fixed allocation-slot or reference-table capacities. The available
RAM is the limit. Allocation is first-fit, validation searches the block list,
and operations are single-threaded. Interrupt/concurrent access requires external
serialization. The board reserves a 64 KiB main stack, a 64 KiB interrupt stack, and a 4 KiB
fatal-trap stack. Manual RC reclamation recurses
through the graph; automatic ARC uses an iterative worklist within dead blocks.

Every allocation starts with one owning reference. The language exposes:

```
Rc.retain  : a -> a.
Rc.release : a -> Unit.
```

These are **explicit unsafe ownership operations** for the default manual mode.
They are rejected when automatic ARC is enabled to prevent ownership being released twice.
Supported values are acyclic, pointer/tagged-value ADTs, strings, words and
addresses. Constructor fields consume ownership: call `Rc.retain` before putting
a shared child into an additional owning field or preserving an owning alias.
Dropping the last reference recursively releases owned fields. Immediate integers
and image-static values are immortal. Borrowed references must not be released.
A retain returns the same object; it does not copy it. Raw-buffer free/realloc
refuse shared allocations. User code must never use an object after its last
release, including aliases retained only in local variables.

```
xs = [1, 2, 3];
ys = Rc.retain xs;
_ = Rc.release xs;
_ = print ys;
Rc.release ys.
```

Do not pass raw floats, ADTs containing raw floats, actors, vectors, mutable
runtime objects, or function closures to this explicit reclamation API.
Floats currently carry untagged bits; generic traversal cannot distinguish those
bits from references. This restriction is a caller obligation, not a static
proof. Cycles are unsupported. The existing message-lifetime ARC used by actors
is a different mechanism and is not linked into this build.

## Automatic ARC: first-order milestone

```
make bare-metal-builtin-run ARC=1 ARC_CHECK=1 BUILTIN_HEAP_BYTES=16384 PROG=tests/builtin_arc.fpr
python3 tests/check_arc.py
```

`ARC=1` selects compiler `--arc` and runtime `FPR_BUILTIN_ARC` together.
It is opt-in and currently restricted to BareMetal–Builtin RV64. `ARC_CHECK=1`
checks for zero live allocations after releasing the result of `main`.
`BUILTIN_HEAP_BYTES` optionally limits the heap for testing; it cannot exceed the
board's RAM interval. Without it, the runtime uses the available linker-defined RAM.
`Mem.liveAllocations Unit : Int` reports the number of live blocks, including raw
buffers; it is useful for lifetime regression tests, not a language-level cost law.

The supported subset includes first-order functions, recursion, lists, tuples,
records/ADTs, structural sharing, pattern matching, branches, returned subtrees,
strings, raw words/addresses, and raw F32/F64 values (including ADT fields). Programs in this subset need no `Rc` calls.
Each managed local owns a reference. Reading it produces a retained reference.
Raw values are copied as bits and never retained or released. Constructors
consume references into fields; functions consume arguments and return an owned
result. Locals/parameters are released at scope exit. Projections retain a selected managed
field, or copy a raw field, before releasing the temporary parent reference. Branch cleanup occurs on the
selected branch. Tail-call arguments are acquired before cleanup, and cleanup runs
before the jump, preserving constant-stack tail recursion.

`compiler/Arc.hs` lowers lambda-lifted Core into explicit bindings and ownership
calls, renaming locals to avoid shadowing errors. This is conservative insertion:
there is no last-use move optimization or removal of redundant retain/release pairs
yet. Ownership annotations are encoded as internal operations in Core rather than a
complete new typed intermediate representation. ARC builds currently compile the root and imported definitions together so
`compiler/Representation.hs` can unify calling and field representations across
the entire program. Separate ARC unit caching is disabled until representation
signatures can be serialized and checked. The current inference is conservative:
functions and constructor fields need consistent types/layouts across uses.
Representation-polymorphic functions/data require specialization; incompatible
uses are rejected rather than silently sharing an incorrect ABI. Do not manually
mix ARC and manual-ownership object files: their function ownership contracts differ.

Compiler-created objects use `fpr_builtin_alloc_adt(bytes, fields)`. The allocation
records the exact field count, followed by a compiler-installed immutable
descriptor distinguishing managed/tagged, Word, Addr, F32 and F64 fields. Leaf
primitive results record zero fields. Destruction follows only managed fields,
never guessed pointer-looking bits or rounded allocation capacity. Raw fields may
contain any bits, including bits equal to a live heap address. Raw-aware structural
equality and rendering use the same metadata; source-level restrictions on generic
float-containing rendering still apply. Use `F32.str`/`F64.str` for float formatting.
Dropping a graph uses an intrusive worklist in dead allocation headers: no recursive
C call stack, new allocations, or fixed queue length are required.

`hal/builtin/arc.c` adapts the audited existing primitives to the owned-call ABI.
They borrow inputs internally; the adapter releases inputs after the call and
retains an aliased result when needed (`str` of a string is one example). Arbitrary
external functions are not admitted without an ownership contract. Retain/release
counts are non-atomic; this runtime remains single-threaded.

The compiler still rejects escaping function values, partial or indirect calls,
explicit `Rc` calls, and primitives
outside the audited list. Plugin exports are also rejected. These are implementation
limits of this experimental ARC mode, not proposed language restrictions. Fully
saturated direct calls produced by lifting are supported when no function value
escapes. All compiled code must satisfy the subset, including unused definitions.

Raw buffers still require `Mem.free`: an `Addr` is a non-owning raw address. Unsafe writes must not manufacture managed
ownership edges or overwrite live managed fields. Cycles are unsupported; there is
no cycle collector. Panic terminates execution without unwinding all live objects.

Next steps are representation specialization for polymorphic uses, ownership-aware
PAPs for lambda-lifted functions and partial application, then last-use moves,
borrowed-call optimization and uniqueness-based reuse. Escape/stack-allocation
analysis is a separate optimization. This milestone does not claim automatic
fallback ARC for the entire language or a complete C interoperability layer.

## Resumable machine interrupts

With `ARC=1`, define `machineInterrupt cause pc value = ...` with three `Word`
arguments and a `Unit` result. Startup installs the runtime entry stub when this
named function exists. No callback registration or separate closure representation
is involved. The arguments are `mcause`, `mepc`, and `mtval`. The handler must
acknowledge its hardware source; returning resumes the interrupted instruction
stream with `mret`. Synchronous exceptions remain fatal.

```
make bare-metal-builtin-run ARC=1 ARC_CHECK=1 BUILTIN_HEAP_BYTES=16384 PROG=tests/builtin_interrupt.fpr
python3 tests/check_raw.py
```

The RV64IMAFD stub switches to a dedicated stack and preserves all integer and
floating-point registers, `fcsr`, the return PC and trap-entry status. Interrupts
stay disabled throughout the handler. Faults inside it use the fatal emergency
stack. `mscratch` is reserved for this stack switch; normal code must preserve it
and `mtvec` while using this facility. Vector state, nesting, NMIs, privilege-mode
switching and multi-hart scheduling are outside this ABI.

`compiler/Interrupt.hs` checks the reachable lifted call graph. Heap construction,
allocation/free/reallocation, managed field projections, printing/string work,
indirect calls, CSR writes, interrupt re-enabling and functions with more than
eight parameters are rejected. The register-only limit avoids the shared `tp`
argument spill area. Raw arithmetic, memory accesses, atomics, CSR reads and
allocation-free float operations are available. Generated fatal match failures
are permitted because they do not allocate or return.

This is an allocation/reentrancy contract, not a proof of all unsafe behavior.
Handlers must not overwrite managed heap objects, allocator state, reserved
stacks or runtime context through raw addresses. Their stack use must fit the
reserved stack. The ordinary allocator and reference counts remain non-reentrant;
user callbacks cannot access them. A manual-ownership build with this reserved
handler name is rejected rather than silently ignoring it.

## Remaining coupling and porting

Common value construction, function application, rendering and arithmetic still
come from `hal/core/runtime.c`, compiled with function/data sections. The standalone
link garbage-collects unused actor code; it does not link `actors.c` or `buddy.c`.
A small `fpr_hart_t` context remains for argument spills and rendering because the
current generated-code ABI uses `tp` for these, even without scheduling. Moving
that common value ABI into a smaller independent header/source is follow-up work.
The frontend still recognizes the wider legacy builtin vocabulary; unsupported
services fail at link time in manual mode. Automatic ARC rejects unaudited
primitives during compilation. Neither mode provides fake service implementations.

To port, replace `crt0.S`, `virt.c` and `link.ld`, supply actual RAM bounds and
console/panic/exit behavior, and adapt the raw machine primitives in `machine.S`. Do not use the QEMU
MMIO addresses or RAM map on another board. The allocator itself has no OS calls.

## Validation

Run `python3 tests/check_builtin.py`. It builds and boots the standalone example,
checks that no scheduler/QOS symbols survived the link, runs failure cases for
invalid shifts/alignment, and runs the heap/refcount tests under host address and
undefined-behavior sanitizers. QEMU success is not physical-board validation.

`tests/check_arc.py` additionally verifies a 16 KiB heap stress run, returned deep
graph destruction, cross-unit ownership behavior, unsupported-feature errors,
and exact layout/shared-edge destruction under sanitizers.

`tests/check_raw.py` checks raw scalar allocation behavior, mixed field layouts,
float equality, imported calling conventions, handler rejection cases, full
register restoration, repeated resumption and fatal faults inside a handler.
