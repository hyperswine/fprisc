# Devices as Sigs: one contract for drivers, boards, capabilities and the C ABI

Date: 2026-11-18. Kind: design direction, for review. Applies to `main` at
`1b7e47ba` (codegenRev 257). Nothing here is built except the two checks under
"What works today".

This is the long-term form of QOS's [device classes proposal](../../qos/docs/2026-11-18-DEVICE-CLASSES.md),
which plugs drivers in through declared classes, instance-addressed device
tables and a `board.toml` in steps that work with today's code. Here the same
ideas are expressed in the language, so that a driver contract, a board, an
app's permissions and the C ABI are one thing rather than four.

## The idea

**A device class is a Sig, a driver is a Struct, a board is a record of driver
instances, and the C ABI is derived from the Sig.**

```
Block = Sig {
  pageBytes : Int,
  pages     : s -> (Int, s),
  read      : s -> Int -> (Result Bytes BlkError, s),
  write     : s -> Int -> Bytes -> (Result Unit BlkError, s),
  flush     : s -> (Result Unit BlkError, s)
}.
VirtioBlk = Struct Block { ... }.   # over Layout register views, as hal/virt/plic.fpr
MemBlock  = Struct Block { ... }.   # the in-memory reference driver
```

`s` is the driver's own state: its register views, queues and cursors. It is
handed in and handed back on every call, following the
[value semantics rule](2026-10-17-VALUE-SEMANTICS.md) (owned values hand
themselves back; no borrowing). The driver owns its device because nobody else
holds `s`.

## 1. Drivers specialize to direct calls

Where a board names the Struct, Struct specialization already turns `d.read`
into a direct call (`read#VirtioBlk`), so a statically configured image pays
nothing for the abstraction. Driver code can be a raw library unit
(`--raw --lib --export`, [layouts](2026-11-03-LAYOUT-TABLE.md),
[allocation-free products](2026-11-05-RAW-PRODUCTS.md)): no heap, no runtime,
fit for interrupt paths. The first-class dictionary is used only where the
driver is chosen at run time.

## 2. The C ABI derived from the Sig

The run-time dictionary of a Struct is a record of functions, which is a
vtable. Give a Sig marked for export a fixed C form:

- **Layout:** the row's labels in canonical order, one function pointer or
  constant each.
- **Types:** only what C can see: `Word`, `U8`..`U64`, `Addr`, raw products,
  byte spans, `Result` as a tagged pair, and the opaque state as an `Addr`.
- **Generated header:** `fpr --abi-header Block` emits `fpr_Block_ops` and its
  row hash.
- **Identity:** the hash of the normalized row is stamped in the image that
  requires it and in the table that provides it.

A C driver then fills `fpr_Block_ops` and is, to FP-RISC, a Struct of `Block`.
QOS Portable's `hal/unix` drivers do the same. QOS's single global HAL version
(today `qos_hal_t` at ABI 24) becomes per-class row hashes compared at load:
changing one class affects only the code that uses it.

**Evolution by extension.** A new operation is a new Sig,
`BlockTrim = Sig {Block | trim : s -> Int -> Int -> (Result Unit BlkError, s)}`,
never an edit of `Block`. Width subtyping already lets a Struct with extra
fields satisfy a smaller Sig (`TypedWide` in `tests/typed_core/structs.fpr`), so
code asking for `Block` keeps working against a `BlockTrim` driver.

## 3. Capabilities are row types

An app states what it needs as a record type:

```
app : {console : Console, storage : Block | r} -> ...
```

The board offers a record of instances, and the app links when the board's row
contains the app's. That is a build-time check where QOS now checks URL strings
(`/services/storage`) at run time. Granting less is passing a narrower record;
an optional grant is an `Option` field; two disks are
`{blk0 : Block, blk1 : Block | r}`, with no registry. QOS's `[permissions]`
TOML sections become checked types.

## 4. A board is a value

```
Board = {
  console = Uart16550 { base = 0x10000000, irq = 10 },
  blk0    = VirtioBlk { base = 0x10001000, irq = 1 },
  net0    = VirtioNet { base = 0x10002000, irq = 2 }
}.
```

This is the `board.toml` of the QOS proposal, typed: a wrong base type, a
missing IRQ or a driver that does not implement its class is a compile error.
The build specializes every instance the record names. The Tang Nano, the Arty
S7, QEMU virt and a Portable host are each one such record; a Portable record
holds host Structs (C tables, or FP-RISC Structs over posix calls).

## 5. Placement and interrupts

A generic service turns messages into Sig calls for any class, so the same
`VirtioBlk` can be linked into an image or hosted as the service actor of QOS's
[multi-board proposal](../../qos/docs/2026-10-11-BUILTIN-KERNEL.md). The board
record chooses; the driver does not change.

Interrupts are messages. A class gains `irq : s -> Int -> s`, or a subscription
in the `std/game` style, and the PLIC already delivers a bound source to an
actor as a plain `Int`. A driver becomes a small update function over device
events, the shape apps already have.

## 6. Conformance written once

A property test written against the Sig, `conforms (d : Block) init`, runs
every driver, C or FP-RISC, against `MemBlock`. Contract rules such as "a read
past `pages` is an error" become refinements on the Sig's fields
([structural refinements](2026-11-13-STRUCTURAL-REFINEMENTS.md)), proved where
the checker can and tested where it cannot.

## What works today

Checked at `1b7e47ba` with `./fpr run`:

- **Linear state through a Sig.** A Sig `Store = Sig { put : s -> Int -> s,
  size : s -> (Int, s) }` with a Struct over `Vector Int`, used through a generic
  `fill (st : Store) s n`, compiles and runs (`size 5`).
- **Linearity inside Struct fields.** A Struct whose `put` drops the vector it
  was handed is rejected: `in Leaky.put: linear variable 'w' used 0 time(s),
  expected exactly 1`.

## What has to be built

1. **Opaque state.** Nothing stops a caller from passing a state it made itself
   (any `Vector Int` is a `Store` state above). The Sig needs an abstract member
   whose values only the Struct can create, such as an `s` introduced by the
   Struct and hidden at the Sig, with creation through an `open` operation the
   board calls.
2. **ABI rows.** Open records use a uniform tagged representation
   ([open record boundaries](2026-11-05-OPEN-RECORD-BOUNDARIES.md)), which is not
   a stable C layout. An exported Sig needs a closed canonical layout and the
   restricted type set above. This is a rule for exported Sigs, not a change to
   ordinary records.
3. **Header generation and row hashing** in the compiler.
4. **Board values at build time.** Specialization is per call site today. The
   build must read a board record and specialize every instance it names, and
   instances must carry their constants (bases, IRQs) into the driver code.
5. **Row-checked app entry.** The app's required row is compared with the board
   record when an image is linked, and recorded in the image for checking when it
   is loaded.

## First experiment

`Block` as a Sig with `MemBlock` and a virtio Struct in the builtin profile, the
generic conformance test, and a header generated from the Sig, then the Spectre
SD card driver behind a C table built from that header. It answers three
questions at once:

- Do FP-RISC drivers specialize with no indirection? (Inspect the selected
  instructions for `read#VirtioBlk` call sites.)
- Does a C driver pass the same conformance test as an FP-RISC one?
- Does the row hash refuse a table built against a different `Block`?

The QOS device classes proposal's steps 1 to 3 (block contract, instances,
Portable generation) can be done first in C and moved onto this when items 1 to
3 above exist. Its declaration file then becomes the Sig.
