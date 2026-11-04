# Compact managed cells (64-bit runtime revision)

Code generation revision 162 makes this the default for 64-bit managed
runtimes. Builtin heaps and RV32 retain their separate contracts. Focused
qualification and all 180 registered Base configurations have passed; the
[execution record](2026-11-04-ZERO-OVERHEAD-EXECUTION.md) describes the two-run
coverage and the corrected test fixtures.

There is one default managed layout: an 8-byte owning-slab prefix, followed by
the existing 8-byte type/variant header and word fields. Managed pointers
remain 8-byte aligned; whole blocks round (prefix + payload) to 16 bytes.
A two-field Cons then occupies 32 bytes instead of 48. Generated field offsets
and tagged-word calls remain unchanged; the allocator/runtime ABI changes.

Object sizes come from the type/variant field-count table for constructors,
and their explicit size fields or fixed C structure sizes for strings, PAPs,
numeric boxes, vectors, and SStrings. SString uses its fixed capacity, not its
current text length. Raw hosted F64 bits are not managed numeric boxes.

Module schema 2 carries a private pointer to the image's constructor table
and its managed prefix size; a mismatched prefix is refused before attachment.
The shared runtime copies numeric rows before publishing an attached module.
The registry uses an immutable-capacity hash index with atomic slot publication
and retained old indices on doubling, so readers need no lock and metadata can
outlive an unloaded sender image. Conflicting layouts are refused. The local
assembly alias prevents ELF interposition from substituting the host table.

Opaque C storage is a separate allocation contract, not a second managed graph
layout. Its size cannot be recovered from arbitrary user bytes. It keeps a
size/slab prefix and is handled by explicitly named raw allocation/free APIs.
Vector directories, columns, raw column storage and shape descriptors use that
contract; the Vector value itself uses the managed layout in its base pool.
The message copier must charge and construct raw vector pieces using the raw
contract as well. No graph walker guesses whether a cell is raw.

The owner remains the word immediately before either returned pointer. Shared
bucket entries are normalized at free time: bucket link at block offset 0 and
owning slab at offset 8, independent of which allocation API later reuses the
block. The big-block list also retains its exact total size. Raw reallocation
continues using allocation capacity, never logical String length or field data.

Audit sites include runtime scopes, equality spill buffers, log staging,
vector scratch arrays, the POSIX module path buffer, and QOS appside request
buffers. C clients which use untyped byte storage must call the raw API.
Managed objects must have initialized headers before being walked or freed.

Qualification scope: all managed object classes and opaque reallocations;
exact bucket reuse across allocation kinds; actor/message/keep/region paths;
slab ownership and escaped lifetimes; dynamic module reload/unload; bounds and
failure behavior; native A64/x64 and RV64 execution; compiler cost; the full
Base suite; and QOS builds/emulator checks against the new ABI. Physical board
results must be reported separately.

## Allocation and ABI contracts

`fpr_alloc` / `fpr_free` handle initialized managed values. Opaque C buffers
use `fpr_alloc_raw` / `fpr_realloc_raw` / `fpr_free_raw`; raw bulk allocations
remain in the base pool, while `fpr_alloc_object_bulk` allocates a managed
Vector header there. Raw capacity must not be inferred from a mutable String
length. QOS storage replies therefore land in raw buffers before construction
of the exactly sized result String. Admission failure initializes the response
header before freeing it; the native process root PAP reserves all arity slots.

Buddy payloads are word-aligned. The new slab start explicitly rounds to 16,
with allowance in refill, copying and fixed-grant bounds. Compact raw buffers
are 16-aligned and managed objects are at least 8-aligned. The old allocator's
16-byte prefix did not itself guarantee 16-aligned pointers from buddy slabs.

Native ABI is 10 for hosted A64, 9 for other compact 64-bit runtimes; the
shared memory plane is version 5. It owns layout registration/lookup so a
process can publish its constructors before spawning, and the kernel can
copy/drop their values after the image exits. Module schema 2 has five header
words: magic, schema, root hash, private layout-table pointer, managed prefix.
Numeric metadata survives detach; no entry points into unloaded image rodata.
The registry allocates outside actor pools and retains old indices when it
doubles. Requested index capacity grows geometrically, but the buddy minimum
block can round small index allocations up to 64 KiB; this startup/growth cost
is separate from bytes per managed cell.

`FPR_COMPACT_CELLS=0` is a diagnostic rollback. `fpr build` and QOS build
scripts select `FPR_LEGACY_CELLS` in the C compiler as well; custom C build
integrations must do likewise. Compiler/unit/runtime cache identities include
the layout. Module and shared-plane checks reject mixed layouts. There is no
claim of binary compatibility across this runtime revision.

## Evidence

- `check_compact_cells.py` compares actual bump extents with derived sizes,
  covers constructor arities 0–8 and encoded wide tuples (16/64/128 fields), String byte lengths and a large String,
  fixed SString, both boxed-number forms, PAP arities 0–8, Vector, Device and
  Register. RV32 QEMU executes the real legacy allocation-header and free
  paths to pin the owner at value-8. Both layouts reject sizes that overflow
  the complete allocation including slab overhead. It tests managed/raw cross-kind bucket and big-block reuse, owner
  pointers, poisoned padding, raw reallocation and alignment on 1/4 harts.
- `FPR_LAYOUT_CHECK` in compact builds keeps an independent debug map of
  allocator/copier extents, recorded before initialization. Inline bump windows
  stay closed for this check. The map has 262,144 address slots and fails
  explicitly if exhausted; it is absent from normal builds. Legacy checks
  continue comparing with the size preheader. Message tests exercise all five
  traversable classes, and fault injection must panic.
- Dynamic-module tests cover a custom constructor through a message round trip,
  detached metadata lifetime, conflicting/unsorted/overflowing metadata and
  concurrent index growth.
- Foreign-static copying checks exact cell extents and poisoned padding for
  zero-/one-field constructors under both layouts, then verifies byte Strings
  survive image poisoning/unload on one/four harts.
- Native A64 and Rosetta x64 execute normal, cold and rollback allocation paths
  on 1/4 harts. An RV64 QEMU oracle independently checks 4,800 cells, ownership,
  exact physical extents and refill counts under both cold and inline paths.
- Nineteen compact integration jobs passed: fixed heaps, admission, sharing,
  actor death, receive cleanup, vector movement, region adoption and nested
  resets, files, module interfaces and boxed integers. QOS portable and RV64
  QEMU (1/2 harts) preserve 200 KB, 256 KiB and 300 KB storage replies.

The [paired benchmark](../bench/2026-11-04-compact-cells.json) uses one compiler,
normal regions, one native arm64 hart, 8 workload repetitions per process and
21 shuffled samples; List fusion is disabled symmetrically to materialize the
lists. Counters come from separate instrumented builds.

| Workload | Legacy median | Compact median | Allocation bytes at probe size |
| --- | ---: | ---: | ---: |
| Build and sum lists | 65.75 ms | 56.83 ms | 384,352 → 256,224 |
| Map and sum lists | 125.61 ms | 96.27 ms | 768,544 → 512,288 |
| Build and sum trees | 47.33 ms | 45.28 ms | 196,480 → 196,448 |

This final codegen-162 run gives list median reductions of 13.6% and 23.4%.
Compact wins 17/21 and 20/21 paired samples, respectively. Individual samples
are noisy; these are local medians, not guaranteed speedups. Trees win only
12/21 samples (4.3% lower median), so there is no clear consistent tree gain;
three-field nodes still round to 48 bytes. The deterministic byte reduction
is the stronger result. Do not compare absolute times with earlier benchmark
sessions as if host conditions were controlled across them.

Smaller cells reduce retained representation cost; they do not eliminate an
abstraction. These measurements are local host evidence, and the QOS results
are emulator evidence. No physical Pi or Tang Nano deployment was performed
for this revision.

Reproduce after other validation jobs finish:

```sh
python3 tests/bench/unbox/compact_pairs.py --samples 21 --output bench/2026-11-04-compact-cells.json
```
