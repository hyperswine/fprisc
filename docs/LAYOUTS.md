# Typed memory layouts

Kind: reference for what ships. Builtin profile (`profile builtin.`), rv64.
`tests/check_layout.py` is the conformance run; `hal/builtin/heap.fpr` is the
worked example.

## Why

The builtin profile gives systems code raw memory: `Mem.readWord`,
`Addr.add`, a `Word`. `hal/builtin/heap.fpr`, the allocator, was written that
way, and it worked -- but it read like assembly:

```text
_ = wr b 24 (w 1);  _ = wr b 72 (w 1);  rest = rdA b 40;
```

The offsets lived in a comment and in the programmer's head, and every pointer
was an `Addr`, so handing `next` a payload pointer type-checked. Moving the
scheduler and the loaders out of C in that style would have produced code less
readable and less safe than the C it replaced (docs/C-REDUCTION.md).

## What

```text
Block = Layout {
  size : Word,  prev : Block,  next : Block,  used : Word,
  fields : Word,  pending : Block,  layout : Desc,  _ : Word,
  cap : Word,  rc : Word
}.
```

`Block` is a **nominal pointer type**: not an `Addr`, not any other layout.

| Field type | Bytes | Accessors traffic in |
|---|---|---|
| `Word`, `Addr`, `Int` | 8 | that type |
| `U8`, `U16` | 1, 2 | `Int` |
| `U32` | 4 | `Word` |
| another layout's name | 8 | a typed pointer to it, stored as a word |

Offsets run in declaration order at each type's natural alignment.
`f : T @ n` pins a field at byte `n` (it must be aligned; fields may overlap,
for a union). `_` is padding. For a layout `L` and field `f`:

| Generated | Type |
|---|---|
| `L.f`, `L.setF` | `L -> T`, `L -> T -> Unit` |
| `L.fAt` | `L -> Addr` -- the field's address, for `Mem.compareExchange` and friends |
| `L.at`, `L.addr` | `Addr -> L`, `L -> Addr` -- the only way in and out |
| `L.sizeOf` | `Unit -> Int` -- the last field's end, rounded up to a word |
| `L.index` | `L -> Int -> L` -- the i-th `L` after this one |
| `L.null`, `L.isNull`, `L.eq` | the null pointer, the test, pointer equality |

A field may not be named `at`, `addr`, `sizeOf`, `index`, `null`, `isNull` or
`eq`. An export's signature is still written in `Addr` and `Word`: the C
boundary has no layouts, and `L.at` at the top of the function is the cast.

## How: it is sugar, and it is free

The declaration **expands at parse time** (`FPRISC.expandLayout`) into an
empty `Type`, signatures and ordinary one-line definitions over
`Mem`/`Addr`/`Word`. Nothing downstream knows layouts exist: modules qualify
the names, inference checks them against their signatures, representation
inference sees raw primitives, ARC sees nothing to manage.

The one thing a definition cannot express is the cast between `Addr` and the
nominal type. Those bodies are the internal primitive `$cast : a -> b`. `$` is
not an identifier character, so no program can write it, and
`Compile.eraseCast` removes it before Core reaches any backend: `Block.at a`
IS `a`.

Three things make the result cost nothing, and each is general:

- **Accessor bodies contain no call.** A pointer field casts with `$cast`
  directly rather than through the other layout's `at`/`addr`. A body with a
  call in it grows when that call is inlined, and ARC's let-normal form pushed
  such a body past the inliner's limit after one round -- so a setter reached
  through a helper stayed a call.
- **`Inline.hs` takes STRAIGHT bodies**: no branch, nothing applied but
  lowered primitives. Copying one into a site can only remove a call, so it
  gets four times the ordinary size allowance; ARC's let-normal form inflates
  a one-line setter to about 29 nodes against a limit of 24.
- **The builtin target emits one section per function, per static closure
  object, per string literal and for the module table**, so the link's
  `--gc-sections` can drop what nothing refers to. The module table matters
  most: it lists every function of a library unit for a registry the builtin
  profile does not link, and in the shared `.rodata` it survived beside live
  strings and kept every function alive through its rows.

## Measured (2026-09-19)

`heap.fpr` by hand and through layouts, same program, same flags:

| | code + read-only data |
|---|---|
| by hand | 20,636 bytes |
| layouts | 20,200 bytes |

No accessor is in either image. Function by function the layout version is the
same size or smaller (`split` 564 vs 604 bytes, `drain` 292 vs 352, `find`
inlined away) -- it knows offset 0 needs no add, where the hand-written helper
`rd a o` adds it. The allocator's suite passes unchanged: 10,000 ARC cycles, a
6,000-node release, exhaustion refused by name.

The section-per-function change is worth more than layouts did: the same image
was **31,818 bytes** before it. A third of every builtin image was code the
linker could not reach.

## The allocator is FP-RISC by default

With ARC (`ARC=1`) the builtin image links `heap.fpr`; `HEAP=c` forces
`heap.c`, which remains for the legacy manual ABI and for `check_builtin.py`'s
native ASan/UBSan run. Every builtin suite runs on the FP-RISC allocator.
It is slower under QEMU (`check_arc.py` 20 s against 7 s): first-fit with a
linear `find`, the same algorithm as the C, in naive generated code.

The builtin target also emits no module table any more. It links no module
registry, so the table had no reader -- and as a strong global it made two
library units in one image a link error, which the FP-RISC allocator beside a
program's own library immediately was.

## Limits

- rv64 only: a word is 8 bytes. The builtin profile refuses other targets.
- A field's type that names no layout is accepted as an opaque pointer type.
- The unit cache is keyed by a module's SOURCE hash; after a compiler change
  that alters generated code, remove `~/.cache/fpr/build/units`.
