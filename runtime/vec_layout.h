/* vec_layout.h -- THE Vector storage layout, single source.
 *
 * Shared by vec.c (the ops), runtime.c (deep-copy of vectors into
 * message slabs / retention pools), and qos/hal/unix/gfx.c (the host-side
 * scene walker reads app-side vectors raw).  Codegen.hs mirrors the
 * field offsets (vLen/vNcols/vKindsP/vColsP and colBlk0 = base at word
 * offset 1) -- change nothing here without changing them there.
 *
 * A column is ONE contiguous span of machine words (docs/2026-08-25-VEC.md #1).
 *
 * DESCRIPTOR (docs/2026-10-03-VECTOR-DESCRIPTORS.md): the header holds the
 * length, the element identity, the column count, and two pointers --
 * `kinds`, one byte per column, and `cols`, the column directory.  There
 * is no fixed column count and no word-wide bitmap: a record of any
 * width is a vector of that many columns.  `kinds` is allocated to at
 * least VK_PAD bytes and zero padded, so a specialized loop can test the
 * first eight columns' kinds with byte loads off one pointer.
 *
 * kind byte: bit 0 RAW (an untagged machine word, not a V); bit 1 FLOAT
 * (the raw word is IEEE bits); bit 2 NARROW (32-bit float in the word).
 * Physical width is the machine word for every column today; the kind
 * byte is where a narrower column will be described.
 */
#ifndef FPR_VEC_LAYOUT_H
#define FPR_VEC_LAYOUT_H

enum { VR_UNSET = 0, VR_INT = 1, VR_BOX = 2, VR_SOA = 3, VR_FLT = 4, VR_TREE = 5 };

enum { VK_BOX = 0, VK_INT = 1, VK_F64 = 3, VK_F32 = 7 };
#define VK_RAW(k) ((k) & 1u)
#define VK_FLOAT(k) ((k) & 2u)
#define VK_PAD 8 /* kinds is allocated to at least this many bytes, zero padded */

typedef struct {
  uw cap;   /* words allocated at base (0 for an empty column) */
  uw *base; /* the ONE contiguous span */
} col_t;

/* Preorder reconstruction recipe for finite nested products. Leaf nodes
 * name a physical column; product nodes carry their concrete value identity.
 * No V pointers or raw float values occur in this metadata. */
typedef struct { uw arity, tid, var, column; } vec_shape_t;
#define VS_PRODUCT ((uw)-1)

typedef struct {
  uint32_t tid, var; /* var = rep (VR_*) */
  uw len, eltid, elvar, ncols;
  uint8_t *kinds; /* ncols kind bytes (VK_*), >= VK_PAD bytes allocated; 0 until the layout is fixed */
  col_t **cols;   /* the column directory: ncols col_t*; 0 until the layout is fixed */
  vec_shape_t *shape;
  uw shape_len;
} vec_t;

#define VREP(x) ((x)->var & 0xffu)
#define VKINDS_BYTES(n) ((n) > (uw)VK_PAD ? (n) : (uw)VK_PAD)

#endif /* FPR_VEC_LAYOUT_H */
