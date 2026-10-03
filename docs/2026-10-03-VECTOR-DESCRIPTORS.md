# Vector descriptors: a column directory instead of eight slots

## Follow-up

[VECTOR-LIMITS](2026-10-03-VECTOR-LIMITS.md) adds inferred generic layout
evidence and finite nested float products; the restrictions recorded here
describe the earlier descriptor step.

Date: 2026-10-03. Kind: implementation record. Step 1 of
[2026-10-03-VECTOR-AUDIT.md](2026-10-03-VECTOR-AUDIT.md).

## Before

`vec_t` carried `col_t *cols[VMAXCOLS]` with `VMAXCOLS = 8`, and two
machine-word bitmaps, `kinds` (column is a raw word) and `fkinds` (the raw
word is float bits). A record with more than eight fields fell back to one
boxed column of whole rows; on RV32 the bitmaps were 32 bits wide. The
header was an ABI mirrored by `Codegen.hs`, by the runtime's three deep
copiers, by `Sys.loopWith`'s snapshot, and by qos's host-side scene walker.

## After

```c
typedef struct {
  uint32_t tid, var;            /* var = rep */
  uw len, eltid, elvar, ncols;
  uint8_t *kinds;               /* ncols kind bytes, >= 8 allocated, zero padded */
  col_t **cols;                 /* the column directory */
} vec_t;
```

A kind byte says what a column holds: bit 0 raw word, bit 1 float bits,
bit 2 narrow (`VK_BOX 0`, `VK_INT 1`, `VK_F64 3`, `VK_F32 7`). Physical
width is still the machine word for every column; the kind byte is the
place a narrower column will be described. The directory and the kind
bytes are allocated when the layout is fixed (first push, or `Vec.newAs`)
and freed with the vector. Any record width is a vector of that many
columns; the column-count check is a range check, not a slot count.

Generated loops read column k as `cols[k]` through the directory pointer
(two loads where there was one) and test a used column's kind with a byte
load and `andi 1` off the kinds pointer, one test per used column, which
is what the eight-byte zero padding is for. The lowerings already had
`lbu`. `codegenRev` is 29.

The three copiers (`dc_size`, `dc_dup`, `kp_dup`) size and copy the
directory and the kind bytes; `vec_snap_t` is sized to the vector it
watches and also pins the directory and kinds pointers. qos's
`hal/unix/gfx.c` mirror reads `kinds[0]` and `cols[0]` the same way.

## Layouts from types, for records too

`Vec.newAs` accepts any number of columns. A declared multi-column layout
no longer fixes the element identity to a tuple: it carries the kinds and
adopts the tuple or record shape of the first value pushed, so one layout
string serves both. Inference now derives a float layout for a closed
record of scalars (fields in sorted name order, the order the lowering
constructs them in) as it did for flat tuples, with no width cap. A
nested float product is still refused with a message.

## A planner bug the wide test found

`soaDualMapOn`'s `strip` walked a shape dispatch in the element function by
always taking the first arm. With two record shapes sharing a field
(`{ r | f0 = … }` where both `R2` and `R4` have `f0`), the desugarer emits a
two-arm dispatch, and the record-map kernel was planned from `R2`'s arm for
a vector of `R4` rows; the kernel never materializes a row, so the dispatch
could not run and fell through to its error arm. This predates the
descriptor (the committed compiler fails the same probe). The planner now
takes a shape-test arm only when it is the sole candidate and declines the
site otherwise; the generic tier runs the function on real rows, and the
compile says so. `tests/base/vecwide.fpr` holds seven record shapes that all
share `f0`, which is what exposed it.

## Evidence

`tests/base/vecwide.fpr` (in `check_base`): records of widths 2, 4, 8, 9,
32, 65 and 128 go through push, `at`, `put`, map, filter, `len`, fold, an
actor round trip (the deep copier, both ways) and free, and the sums match
a reference computed in Python; a float record `{x : F64, y : F64, k : Int}`
takes an inferred layout; width-one records stay boxed rows and work.
`tests/check_typed_vectors.py`, `tests/fuse.fpr`, `fvec`, `fvec2`,
`vecedge`, `matvec`, `vecfuse2`, `recfold`, `vecpeek`, `loopwith` and the
rest of `check_base` pass; `qos.py build` and `qos.py test` pass against
this runtime.

## Not in this step

The kernel limits the audit lists for step 2 are unchanged: record-map
specialization still emits at most four output fields and eight callback
parameters, so a nine-field record map runs in the generic tier (and says
so). Columns are words; F32 is not yet a compact column. Nested products
stay referenced values in a boxed column.
