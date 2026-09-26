/* vec_layout.h -- THE Vector storage layout, single source.
 *
 * Shared by vec.c (the ops), runtime.c (deep-copy of vectors into
 * message slabs / retention pools), and machine/unix/gfx.c (the host-side
 * scene walker and GPU tier read app-side vectors raw).  Codegen.hs
 * mirrors the field offsets (vLen/vNcols/vKinds/vFkinds/vCols0 and
 * colBlk0 = base at word offset 1) -- change nothing here without
 * changing them there.
 *
 * A column is ONE contiguous span of machine words (docs/2026-08-25-VEC.md #1).
 * kinds bit i: column i is RAW (untagged machine word, not a V).
 * fkinds bit i: that raw word is IEEE float bits (subset of kinds).
 */
#ifndef FPR_VEC_LAYOUT_H
#define FPR_VEC_LAYOUT_H

#define VMAXCOLS 8

enum { VR_UNSET = 0, VR_INT = 1, VR_BOX = 2, VR_SOA = 3, VR_FLT = 4 };

typedef struct {
  uw cap;   /* words allocated at base (0 for an empty column) */
  uw *base; /* the ONE contiguous span */
} col_t;

typedef struct {
  uint32_t tid, var; /* var = rep (VR_*) */
  uw len, eltid, elvar, ncols, kinds, fkinds;
  col_t *cols[VMAXCOLS];
} vec_t;

#define VREP(x) ((x)->var & 0xffu)

#endif /* FPR_VEC_LAYOUT_H */
