# Indexed C heap for the bare-metal board (2026-10-16)

The board's C allocator no longer walks every live allocation to allocate,
retain, release, reallocate, inspect an exact ARC layout, or count live objects.
This particularly matters for a growing list: the original first-fit allocator
revisited all earlier nodes while building it, then repeated those searches
while destroying it.

`machine/builtin/heap.c` retains its runtime ABI and physical block format:

- Payloads and capacities remain multiples of 16 bytes. The established
  16-byte metadata area immediately before the payload still begins with
  capacity plus 16, followed by the machine-word reference count.
- Every fresh allocation is zeroed across its rounded payload capacity.
  Allocation/reallocation and block-header zeroing and copying use aligned machine words,
  avoiding repeated sub-word read/modify/write traffic on the board.
- Physical predecessor/successor links still allow adjacent free blocks to
  coalesce. Free-list links reuse fields that are unused while a block is free;
  exact ARC field counts, representation descriptors and the destruction
  worklist keep their original meanings while it is allocated.
- Reallocation can grow into its free neighbour, zeroing the newly exposed
  capacity. A moved allocation preserves its exact field count/descriptor,
  existing bytes and exclusive ownership.
- Shared free/reallocation, overflowing size/reference count, invalid payload
  pointers and double free retain explicit refusal paths. ARC destruction is
  still iterative; the separate legacy manual-Rc graph walk remains recursive.

Pointer validation uses a side bitmap of exact live payload starts. Bounds and
alignment are checked before consulting it; a header is read only when that
exact payload is marked live. Copying a plausible header into another object's
payload therefore cannot create an allocation. Merely subtracting the header
size would not provide this property. The bitmap resides at the top of the
supplied arena, outside every allocation, and costs one bit per 16 bytes
(0.78125% of the initial arena, rounded up to 16 bytes).

Free blocks are indexed by two levels of size classes with occupancy bitmaps.
Classes below 256 whole-block bytes have exact 16-byte sizes. Allocating from a
matching head or a larger occupied class takes bounded index work, independent
of the number of live objects. If no larger class exists and the requested
class's head is too small, the allocator searches only the remaining free blocks
in that class. This fallback prevents a false out-of-memory failure without
rounding every large request up to a size-class boundary. Thus checked-pointer
lookup, live counting and coalescing are constant time; allocation has a
free-class-dependent worst case, plus the required payload zeroing work.

Requests whose complete block exceeds the usable arena are refused before
looking up a size class. This also prevents an oversized request from indexing
past a board's bounded free-list table. A refused reallocation preserves the
original allocation, capacity, contents and exclusive ownership.

The implementation remains single-threaded and is not reentrant. Interrupt
handlers must not mutate the heap concurrently with an interrupted allocation.
It has no fixed number of allocation slots and no fixed arena-size cap beyond
the machine address space. The C free-list state uses 1,076 static bytes on
RV32 and 4,200 on RV64, versus 12/24 before. At `-Os`, the complete manual-Rc
allocator object is 3,558/3,742 code bytes, versus 2,062/2,082 before; final
linked images can discard unused functions. The bitmap reservation is additional.
These object sizes use `-ffreestanding -fno-builtin` and the default object
section layout; function/data section flags can change complete-object sizes.

For a board with a known maximum arena, define
`FPR_BUILTIN_HEAP_MAX_BYTES=65536` or `8388608`. The compiler sizes the free-list
index for that bound; heap initialization rejects an aligned arena exceeding it
before writing any supplied memory. Zero, negative, impossibly small and
larger-than-XLEN limits fail at compilation. The generic build retains the full
XLEN index and its original accepted arena range. This option changes indexing
storage only, not allocation sizes, class selection, pointer validation or the
payload ABI:

| Configuration | Static allocator bytes | Complete manual-Rc object code bytes |
| --- | ---: | ---: |
| RV32, generic | 1,076 | 3,558 |
| RV32, 64 KiB maximum | 383 | 3,626 |
| RV32, 8 MiB maximum | 614 | 3,626 |
| RV64, generic | 4,200 | 3,742 |
| RV64, 8 MiB maximum | 1,210 | 3,778 |

The bounded RV64 board index therefore saves 2,990 static bytes. Object symbol
checks show no added bit-count/libgcc dependency; only the panic callback remains
undefined in the allocator object itself.

The board's manual Builtin and RV64 Base host link this C implementation.
`ARC=1 HEAP=c` selects it on the QEMU Builtin target. The default ARC target's
`machine/builtin/heap.fpr` remains the original first-fit implementation and has
not received this optimization.

## Executed checks

Run the complete focused fixture with:

```sh
python3 tests/check_builtin_heap_index.py
```

The new fixture executes under native AddressSanitizer/UndefinedBehaviorSanitizer
and as freestanding RV32IM/RV64IM programs in QEMU. It checks rounded-capacity
zeroing, pointer alignment, guarded and in-place reallocation, preservation of
bytes and exact ARC descriptors, random size/reuse/coalescing behavior, sharing,
raw pointer fields and iterative release of 8,192-node lists. Twenty-one refusal
cases execute independently at each XLEN, including a forged interior header,
invalid/interior pointers, coalesced double free, shared free/reallocation,
overflow, invalid layouts and exhausted/tiny heaps. The native harness also
exhausts its arena, frees differently sized holes in an adverse order, and
requires the fitting hole to remain usable.

The existing manual-Rc sanitizer fixture and 12,000-deep exact-layout ARC fixture
also pass.

Both XLEN fixtures additionally run with actual 64 KiB and 8 MiB bounded arenas,
exercise refusal of oversized arenas and allocation/reallocation requests that
exceed the size-class table, and repeat the complete contracts with the 8 MiB
bound. Each refused oversized reallocation checks the original capacity and
contents, then successfully frees the still-owned allocation. Native sanitizers
run both bounded arena sizes; invalid
configuration compile checks include negative/zero/tiny limits and a limit
larger than the RV32 address space.

The test-only counters report these allocator operations:

| List nodes | Allocation probes | Checked pointer lookups |
| ---: | ---: | ---: |
| 512 | 512 | 1,538 |
| 2,048 | 2,048 | 6,146 |
| 8,192 | 8,192 | 24,578 |

For a reproducible comparison against the original C heap:

```sh
python3 tests/check_builtin_heap_index.py --baseline-ref 4bba11b
```

The following are `mcycle` deltas with QEMU's deterministic
`-icount shift=0,sleep=off`, measuring the same allocation/share/release workload.
They describe emulated guest work; they are **not FPGA cycle counts, elapsed
time, or general FP-RISC program speedups**. The new build also includes the
test-only work counters; the baseline does not. Work scales approximately
linearly with node count after the change, instead of quadratically:

| XLEN / nodes | Original C heap | Indexed C heap |
| --- | ---: | ---: |
| RV32 / 512 | 2,869,932 | 419,602 |
| RV32 / 2,048 | 42,936,492 | 1,677,586 |
| RV32 / 8,192 | 675,061,932 | 6,700,820 |
| RV64 / 512 | 2,993,840 | 449,299 |
| RV64 / 2,048 | 43,432,112 | 1,796,371 |
| RV64 / 8,192 | 677,044,400 | 7,170,033 |

Small allocations still carry the original private header: 32 bytes on RV32 or
64 bytes on RV64, followed by 16 metadata bytes. Specialized slabs/arenas could
reduce this cost, but they need an explicit object-lifetime contract and are
outside this change. Software floating-point/I64 boxing and compiler-generated
allocation behavior also remain separate concerns.
