/* vec.c — the LINEAR SoA vector, CONTIGUOUS columns.
 *
 * Storage model (docs/2026-08-25-MEMORY.md v2)
 * ---------------------------------
 * A Vector is columns; a column is ONE contiguous span of machine
 * words, grown by realloc-by-doubling (fpr_realloc: the freed
 * predecessor recycles exactly through the pool's ladder, so the
 * doubling sequence reuses its own history).  Push is amortized O(1);
 * the copy a growth pays is attributed to the push that grew, which
 * keeps the WCET story compositional.  Indexing is base + i — no
 * block directory, no per-index log2 — and the compiler's
 * specialized/vectorized loops stride the whole column as one run.
 * (The old VList block directory is gone: it existed only because the
 * allocator had no realloc.)
 *
 * Layout is fixed by the FIRST push (the Sol PoC rule, verbatim):
 *   Int                    -> 1 unboxed column           (rep VR_INT)
 *   tuple/record, any width -> one column per field, each unboxed
 *                             if that field was an Int   (rep VR_SOA)
 *   anything else          -> 1 boxed column             (rep VR_BOX)
 * Unboxed columns hold RAW (untagged) machine words — the layout the
 * generated column loops and the RVV lanes consume with zero
 * marshalling.  Boxed columns hold V values as-is.
 *
 * LINEARITY IS WHAT MAKES THIS SOUND: `Vector 1 = ...` in the prelude
 * makes the checker enforce single ownership, which licenses in-place
 * mutation (push/set/map return the same reference as the "new" vector)
 * and licenses the compiler's specialized loops to write columns
 * directly.  Record values carry their field count in `var`; tuple
 * arities come from their typeids. Nested float products carry a recipe.
 */
#include "fpr.h"
#include <limits.h>

#define VL_B0 16 /* words in a fresh column's first allocation */

/* The layout lives in vec_layout.h (single source, shared with the
 * runtime's deep copier and the host-side gfx walker; Codegen.hs
 * mirrors the offsets).  VR_FLT there is a DECLARED rep, never
 * inferred: a float V is its bit pattern, so the runtime cannot tell
 * one from a pointer -- fix_layout's first-push rule is undecidable
 * for floats (the documented v1 hazard, turned into an API instead of
 * a guess).  Vec.newAs declares the layout up front. */
#include "vec_layout.h"

/* ---- column access ---------------------------------------------------- */

static inline uw *vl_slot(col_t *c, uw i) { return &c->base[i]; }

static void col_grow(col_t *c) {
  uw ncap = c->cap ? c->cap * 2 : (uw)VL_B0;
  c->base = (uw *)fpr_realloc((V)c->base, ncap * sizeof(uw));
  c->cap = ncap;
}

static col_t *col_new(void) {
  col_t *c = (col_t *)fpr_alloc(sizeof(col_t));
  c->cap = 0;
  c->base = 0;
  return c;
}

static void col_free(col_t *c) {
  if (c->base) fpr_free((V)c->base); /* >8KiB: bigfree LIFO */
  fpr_free((V)c);
}

/* ---- vector object ---------------------------------------------------- */

static vec_t *vchk(V v, const char *who) {
  if (ISINT(v) || TID(v) != T_VEC) fpr_cpanic(who);
  return (vec_t *)v;
}

/* ---- ownership: ONE owner, real copies (2026-08-25-MEMORY.md v2 phase 3) ------
 * The CoW rc that used to ride var's high bits is GONE.  `send` deep-
 * copies vectors into the message slab like every other value (no
 * exceptions), `Vec.dup` is an honest copy, and mutation needs no
 * ownership test anywhere -- which makes the compiler's specialized
 * column loops (which write storage directly) sound BY CONSTRUCTION
 * instead of "documented unsound on shared vectors".  It also closes
 * the lifetime hole CoW had: a shared handle's storage died with the
 * SENDER's pool (poolReset/death frees slabs regardless of rc); a
 * receiver's copy is its own. */
static void vfree(vec_t *x); /* fwd */
static col_t *col_new(void);
static col_t *col_copy(col_t *c, uw len) {
  col_t *n = col_new();
  if (len) {
    uw cap = VL_B0;
    while (cap < len) cap *= 2;
    n->base = (uw *)fpr_alloc(cap * sizeof(uw));
    n->cap = cap;
    __builtin_memcpy(n->base, c->base, len * sizeof(uw));
  }
  return n;
}
/* the descriptor: a directory of ncols column pointers and ncols kind
 * bytes (zero padded to VK_PAD), allocated when the layout is fixed */
static void vdir_alloc(vec_t *x, uw ncols) {
  if (ncols == 0 || ncols > ((uw)1 << 30) || ncols > ~(uw)0 / sizeof(col_t *)) fpr_cpanic("Vec: column count out of range");
  x->ncols = ncols;
  x->cols = (col_t **)fpr_alloc(ncols * sizeof(col_t *));
  x->kinds = (uint8_t *)fpr_alloc(VKINDS_BYTES(ncols));
  for (uw k = 0; k < VKINDS_BYTES(ncols); k++) x->kinds[k] = VK_BOX;
  for (uw k = 0; k < ncols; k++) x->cols[k] = 0;
}
static void vdir_free(vec_t *x) {
  if (x->cols) fpr_free((V)x->cols);
  if (x->kinds) fpr_free((V)x->kinds);
  x->cols = 0;
  x->kinds = 0;
  x->ncols = 0;
  if (x->shape) fpr_free((V)x->shape);
  x->shape = 0; x->shape_len = 0;
}
static int vhas_float(const vec_t *x) {
  for (uw k = 0; k < x->ncols; k++)
    if (VK_FLOAT(x->kinds[k])) return 1;
  return 0;
}
static void vshape_like(vec_t *x, const vec_t *src) {
  x->shape_len = src->shape_len; x->shape = 0;
  if (src->shape_len) {
    x->shape = (vec_shape_t *)fpr_alloc(src->shape_len * sizeof(vec_shape_t));
    __builtin_memcpy(x->shape, src->shape, src->shape_len * sizeof(vec_shape_t));
  }
}
/* copy the descriptor (kinds, element identity, rep) of src into a fresh empty x */
static void vdir_like(vec_t *x, const vec_t *src) {
  vshape_like(x, src);
  x->var = (uint32_t)VREP(src);
  x->eltid = src->eltid;
  x->elvar = src->elvar;
  if (src->ncols) {
    vdir_alloc(x, src->ncols);
    for (uw k = 0; k < src->ncols; k++) x->kinds[k] = src->kinds[k];
  }
}
static vec_t *vcopy(vec_t *x) {
  vec_t *n = (vec_t *)fpr_alloc(sizeof(vec_t));
  n->tid = T_VEC;
  n->var = (uint32_t)VREP(x); /* rc 0: sole owner */
  n->len = x->len; n->eltid = x->eltid; n->elvar = x->elvar;
  n->ncols = 0; n->kinds = 0; n->cols = 0;
  vshape_like(n, x);
  if (x->ncols) {
    vdir_alloc(n, x->ncols);
    for (uw k = 0; k < x->ncols; k++) {
      n->kinds[k] = x->kinds[k];
      n->cols[k] = x->cols[k] ? col_copy(x->cols[k], x->len) : 0;
    }
  }
  return n;
}
/* one owner: writes need no ownership test, release IS the free.
 * vfree no-ops on slab-resident pieces (fpr_free ignores ownerless
 * slabs) and really frees pool-resident ones, so it is the universal
 * release for local, message-copied, and post-receive-grown vectors
 * alike.  fpr_vec_release stays exported: the deep copier's root-drop
 * path (dc_release) uses it. */
void fpr_vec_release(V v) { vfree((vec_t *)v); }

static V h_new(V unit) {
  (void)unit;
  vec_t *x = (vec_t *)fpr_alloc(sizeof(vec_t));
  x->tid = T_VEC;
  x->var = VR_UNSET;
  x->len = 0;
  x->eltid = x->elvar = x->ncols = 0;
  x->kinds = 0;
  x->cols = 0;
  x->shape = 0; x->shape_len = 0;
  return (V)x;
}

/* Vec.range lo hi: bulk construction at native speed -- one Int column
 * filled by this loop instead of one interpreted/generic Vec.push per
 * element (the fill loop dominates ML-scale pipelines; range + a
 * specialized map is the fast spelling of "generate n samples").
 * Empty range (hi < lo) leaves the layout UNSET, exactly like Vec.new. */
static void fix_layout(vec_t *x, V v); /* fwd */
static V h_range(V lov, V hiv) {
  if (!ISINT(lov) || !ISINT(hiv)) fpr_cpanic("Vec.range: bounds must be Ints");
  sw lo = UNTAG(lov), hi = UNTAG(hiv);
  vec_t *x = (vec_t *)h_new((V)&fpr_unit);
  if (hi < lo) return (V)x;
  fix_layout(x, lov); /* one raw Int column */
  col_t *c = x->cols[0];
  uw n = (uw)(hi - lo + 1);
  while (c->cap < n) col_grow(c);
  sw v = lo;
  uw *slot = c->base;
  for (uw i = 0; i < n; i++) *slot++ = (uw)v++;
  x->len = n;
  return (V)x;
}

static uw tuple_arity(uw tid) {
  if (tid == T_TUP2) return 2;
  if (tid == T_TUP3) return 3;
  if (tid >= T_TUP4 && tid <= T_TUP8) return 4 + (tid - T_TUP4);
  if (tid > T_TUPN && tid < T_TUPN_END) return tid - T_TUPN;
  return 0;
}

/* records: the compiler puts the FIELD COUNT in var (unused for shapes
 * -- one shape per tid), so a record VALUE is self-describing and a Vec
 * of records gets SoA columns by the same first-push rule as tuples.
 * Shape tids live in the content-addressed 0x00010000+ window
 * (FPRISC.hs shapeIdFor).  Any width: the descriptor is sized to it. */
static uw value_arity(V v) {
  uw tid = TID(v);
  uw t = tuple_arity(tid);
  if (t) return t;
  if (tid >= 0x00010000 && tid < 0x00010000 + 0x0FF00000) {
    uw ar = ((hdr_t *)v)->var;
    return ar >= 1 ? ar : 0;
  }
  return 0;
}

/* fix the layout from the first pushed value (the Sol rule) */
static void fix_layout(vec_t *x, V v) {
  if (ISINT(v)) {
    x->var = VR_INT;
    vdir_alloc(x, 1);
    x->kinds[0] = VK_INT;
  } else {
    uw ar = value_arity(v);
    if (ar) {
      x->var = VR_SOA;
      x->eltid = TID(v);
      x->elvar = ((hdr_t *)v)->var;
      vdir_alloc(x, ar);
      for (uw k = 0; k < ar; k++) {
        V f = *(V *)((char *)v + 8 + k * sizeof(uw));
        x->kinds[k] = ISINT(f) ? VK_INT : VK_BOX;
      }
    } else {
      x->var = VR_BOX;
      vdir_alloc(x, 1);
    }
  }
  for (uw k = 0; k < x->ncols; k++) x->cols[k] = col_new();
}

static void put_cell(vec_t *x, uw k, uw i, V f) {
  int raw = VK_RAW(x->kinds[k]) != 0, flt = VK_FLOAT(x->kinds[k]) != 0;
  /* a float column stores the V verbatim -- it ALREADY is the bit
   * pattern.  No ISINT check is possible (nor meaningful): the width
   * came from the declaration, not from the value. */
  if (raw && !flt && !ISINT(f))
    fpr_cpanic("Vec: Int column got a non-Int (layout is fixed by the first push or by Vec.newAs)");
  *vl_slot(x->cols[k], i) = (raw && !flt) ? (uw)UNTAG(f) : (uw)f;
}

static V get_cell(vec_t *x, uw k, uw i) {
  uw raw = *vl_slot(x->cols[k], i);
  int unb = VK_RAW(x->kinds[k]) != 0, flt = VK_FLOAT(x->kinds[k]) != 0;
  return (unb && !flt) ? TAG((sw)raw) : (V)raw;
}

/* Vec.newAs spec -- DECLARE the column layout instead of inferring it.
 * One char per column: 'i' Int (raw, tagged on read), 'd' F64, 's' F32
 * (both raw float bits), 'b' boxed (any V).  One char = a flat vector;
 * multiple chars = an SoA vector; parentheses describe nested products.
 *
 *   Vec.newAs "d"    a Vector of F64        (raw contiguous doubles)
 *   Vec.newAs "iddd" SoA rows (Int, F64, F64, F64)
 *
 * This exists because floats are raw bits: the first-push rule that
 * classifies Int/tuple/boxed cannot see a float at all, and guessing
 * would dereference a double as an object header.  Declaring is the
 * honest fix, and it doubles as the hook the specialized column loops
 * read to pick float instructions. */
static uint8_t layout_kind(char c) {
  switch (c) {
    case 'i': return VK_INT; case 'd': return VK_F64;
    case 's': return VK_F32; case 'b': return VK_BOX;
    default: fpr_cpanic("Vec.newAs: invalid layout leaf");
  }
  return VK_BOX;
}
/* Parse bounded, finite products without C recursion. The descriptor
 * comes from checked types, but malformed internal/foreign evidence still
 * fails loudly before any element is inspected. */
static void tree_layout(vec_t *x, str_t *sp) {
  uw leaves = 0;
  for (uw i=0; i<sp->len; i++) if (sp->bytes[i] != '(' && sp->bytes[i] != ')') {
    (void)layout_kind(sp->bytes[i]); leaves++;
  }
  vdir_alloc(x, leaves);
  x->shape = (vec_shape_t *)fpr_alloc(sp->len * sizeof(vec_shape_t));
  uw *stack = (uw *)fpr_alloc(sp->len * sizeof(uw));
  uw depth=0, col=0, nodes=0, roots=0;
  for (uw i=0; i<sp->len; i++) {
    char c=sp->bytes[i];
    if (c == ')') { if (!depth) fpr_cpanic("Vec.newAs: unmatched product close"); depth--; continue; }
    uw n=nodes++;
    if (depth) x->shape[stack[depth-1]].arity++; else roots++;
    x->shape[n] = (vec_shape_t){0,0,0,VS_PRODUCT};
    if (c == '(') stack[depth++]=n;
    else { x->shape[n].column=col; x->kinds[col++]=layout_kind(c); }
  }
  if (depth || roots != 1) fpr_cpanic("Vec.newAs: malformed product layout");
  for (uw n=0; n<nodes; n++) if (x->shape[n].column == VS_PRODUCT && !x->shape[n].arity)
    fpr_cpanic("Vec.newAs: empty product layout");
  fpr_free((V)stack);
  x->shape_len=nodes; x->var=VR_TREE;
  for (uw k=0; k<x->ncols; k++) x->cols[k]=col_new();
}
static V h_newAs(V specv) {
  if (ISINT(specv) || TID(specv) != T_STR)
    fpr_cpanic("Vec.newAs: spec must be a String like \"d\" or \"iddd\"");
  str_t *sp = (str_t *)specv;
  if (sp->len == 0) return h_new((V)&fpr_unit); /* inferred non-float evidence */
  if (sp->len >= (uw)(T_TUPN_END - T_TUPN))
    fpr_cpanic("Vec.newAs: spec must name at least one column");
  vec_t *x = (vec_t *)h_new((V)&fpr_unit);
  if (sp->bytes[0] == '(') { tree_layout(x, sp); return (V)x; }
  vdir_alloc(x, sp->len);
  for (uw k = 0; k < sp->len; k++) {
    switch (sp->bytes[k]) {
      case 'i': x->kinds[k] = VK_INT; break;
      case 'd': x->kinds[k] = VK_F64; break;
      case 's': x->kinds[k] = VK_F32; break;
      case 'b': x->kinds[k] = VK_BOX; break;
      default: fpr_cpanic("Vec.newAs: spec chars are i (Int), d (F64), s (F32), b (boxed)");
    }
  }
  if (sp->len == 1) {
    x->var = VK_FLOAT(x->kinds[0]) ? VR_FLT : (VK_RAW(x->kinds[0]) ? VR_INT : VR_BOX);
  } else {
    /* the KINDS are declared; the element identity (a tuple or a record
     * shape of that many fields) is taken from the first value pushed,
     * so one declared layout serves tuples and records alike */
    x->var = VR_SOA;
    x->eltid = 0;
    x->elvar = 0;
  }
  for (uw k = 0; k < x->ncols; k++) x->cols[k] = col_new();
  return (V)x;
}

/* an EMPTY vector with the same declared layout -- what map/filter must
 * build for a declared (float-bearing) source, since h_new + first-push
 * inference cannot recover a float layout from a float value. */
static V h_new_like(vec_t *src) {
  vec_t *x = (vec_t *)h_new((V)&fpr_unit);
  vdir_like(x, src);
  for (uw k = 0; k < x->ncols; k++) x->cols[k] = col_new();
  return (V)x;
}

static void tree_put(vec_t *x, uw *cursor, uw row, V value) {
  vec_shape_t *n=&x->shape[(*cursor)++];
  if (n->column != VS_PRODUCT) { put_cell(x,n->column,row,value); return; }
  if (ISINT(value) || value_arity(value) != n->arity)
    fpr_cpanic("Vec: nested product shape differs from declared layout");
  if (!n->tid) { n->tid=TID(value); n->var=((hdr_t *)value)->var; }
  if (n->tid != TID(value) || n->var != ((hdr_t *)value)->var)
    fpr_cpanic("Vec: nested product identity differs from first push");
  for (uw k=0; k<n->arity; k++) tree_put(x,cursor,row,*(V *)((char *)value+8+k*sizeof(uw)));
}
static V tree_get(vec_t *x, uw *cursor, uw row) {
  vec_shape_t *n=&x->shape[(*cursor)++];
  if (n->column != VS_PRODUCT) return get_cell(x,n->column,row);
  hdr_t *v=(hdr_t *)fpr_alloc(8+n->arity*sizeof(uw));
  v->tid=(uint32_t)n->tid; v->var=(uint32_t)n->var;
  for (uw k=0; k<n->arity; k++) *(V *)((char *)v+8+k*sizeof(uw))=tree_get(x,cursor,row);
  return (V)v;
}
static V h_push(V v, V vec) {
  vec_t *x = vchk(vec, "Vec.push: not a Vector");
  if (VREP(x) == VR_UNSET) fix_layout(x, v);
  for (uw k = 0; k < x->ncols; k++)
    if (x->len == x->cols[k]->cap) col_grow(x->cols[k]);
  switch (VREP(x)) {
    case VR_TREE: { uw cursor=0; tree_put(x,&cursor,x->len,v); break; }
    case VR_INT:
      if (!ISINT(v)) fpr_cpanic("Vec.push: Int vector got a non-Int");
      put_cell(x, 0, x->len, v);
      break;
    case VR_FLT: /* declared width; the value carries no evidence */
      put_cell(x, 0, x->len, v);
      break;
    case VR_BOX:
      put_cell(x, 0, x->len, v);
      break;
    case VR_SOA: {
      if (x->eltid == 0 && !ISINT(v) && value_arity(v) == x->ncols) {
        x->eltid = TID(v); /* a declared layout meets its first value */
        x->elvar = ((hdr_t *)v)->var;
      }
      if (ISINT(v) || TID(v) != x->eltid)
        fpr_cpanic("Vec.push: tuple shape differs from first push (or from the declared column count)");
      for (uw k = 0; k < x->ncols; k++)
        put_cell(x, k, x->len, *(V *)((char *)v + 8 + k * sizeof(uw)));
      break;
    }
  }
  x->len++;
  return (V)x;
}

/* reconstruct row i as a value — the deliberately slower escape hatch */
static V row_at(vec_t *x, uw i) {
  switch (VREP(x)) {
    case VR_TREE: { uw cursor=0; return tree_get(x,&cursor,i); }
    case VR_INT:
    case VR_FLT:
    case VR_BOX:
      return get_cell(x, 0, i);
    default: {
      hdr_t *t = (hdr_t *)fpr_alloc(8 + x->ncols * sizeof(uw));
      t->tid = (uint32_t)x->eltid;
      t->var = (uint32_t)x->elvar;
      for (uw k = 0; k < x->ncols; k++)
        *(V *)((char *)t + 8 + k * sizeof(uw)) = get_cell(x, k, i);
      return (V)t;
    }
  }
}

static V mktup2(V a, V b) {
  hdr_t *t = (hdr_t *)fpr_alloc(8 + 2 * sizeof(uw));
  t->tid = T_TUP2;
  t->var = 0;
  *(V *)((char *)t + 8) = a;
  *(V *)((char *)t + 8 + sizeof(uw)) = b;
  return (V)t;
}

static V h_len(V vec) {
  vec_t *x = vchk(vec, "Vec.len: not a Vector");
  return mktup2(TAG((sw)x->len), (V)x);
}

/* 0-based, like `!` and every position (docs/2026-10-02-ZERO-BASED.md) */
static V h_get(V iv, V vec) {
  vec_t *x = vchk(vec, "Vec.get: not a Vector");
  if (!ISINT(iv)) fpr_cpanic("Vec.get: index not an Int");
  sw i = UNTAG(iv);
  if (i < 0 || (uw)i >= x->len) fpr_cpanic("Vec.get: index out of range");
  return mktup2(row_at(x, (uw)i), (V)x);
}

static V h_set(V iv, V v, V vec) {
  vec_t *x = vchk(vec, "Vec.set: not a Vector");
  if (!ISINT(iv)) fpr_cpanic("Vec.set: index not an Int");
  sw i = UNTAG(iv);
  if (i < 0 || (uw)i >= x->len) fpr_cpanic("Vec.set: index out of range");
  switch (VREP(x)) {
    case VR_TREE: { uw cursor=0; tree_put(x,&cursor,(uw)i,v); break; }
    case VR_INT:
    case VR_FLT:
    case VR_BOX:
      put_cell(x, 0, (uw)i, v);
      break;
    default:
      if (x->eltid == 0 && !ISINT(v) && value_arity(v) == x->ncols) {
        x->eltid = TID(v);
        x->elvar = ((hdr_t *)v)->var;
      }
      if (ISINT(v) || TID(v) != x->eltid) fpr_cpanic("Vec.set: tuple shape differs");
      for (uw k = 0; k < x->ncols; k++)
        put_cell(x, k, (uw)i, *(V *)((char *)v + 8 + k * sizeof(uw)));
  }
  return (V)x;
}

static void vfree(vec_t *x) {
  for (uw k = 0; k < x->ncols; k++)
    if (x->cols[k]) col_free(x->cols[k]);
  vdir_free(x);
  fpr_free((V)x);
}

static V h_free(V vec) {
  vfree(vchk(vec, "Vec.free: not a Vector"));
  return (V)&fpr_unit;
}

/* ---- schemes: the generic (interpreted) tier -------------------------
 * These exist so EVERY well-typed program runs; the compiler's
 * specialized column loops (Codegen.hs) shadow them per call site when
 * the element function is statically known and arithmetic-only, and
 * TAIL-CALL BACK IN here when a runtime layout guard fails.  Exported
 * under stable direct names for exactly that fallback path. */

V fpr_vec_map(V f, V vec) {
  vec_t *x = vchk(vec, "Vec.map: not a Vector");
  /* This runtime entry implements the same-element map: checked source
   * calls preserve the element type and therefore its float layout.
   * Type-changing maps are lowered to mapAs with output layout evidence. */
  V out = vhas_float(x) ? h_new_like(x) : h_new((V)&fpr_unit);
  for (uw i = 0; i < x->len; i++) out = h_push(fpr_apply(f, row_at(x, i)), out);
  vfree(x); /* consumed input */
  return out;
}

/* Type-changing maps: the compiler supplies the OUTPUT layout rather than
 * inheriting the input's float widths. Empty spec uses first-push layout
 * inference, admitted only for a statically known non-float output type. */
static V h_mapAs(V spec, V f, V vec) {
  vec_t *x = vchk(vec, "Vec.map: not a Vector");
  str_t *sp = (str_t *)spec;
  V out = sp->len ? h_newAs(spec) : h_new((V)&fpr_unit);
  for (uw i = 0; i < x->len; i++) out = h_push(fpr_apply(f, row_at(x, i)), out);
  vfree(x);
  return out;
}

/* filter is EAGER COMPACTION today: the kept rows slide down in place
 * with two cursors and len shrinks -- zero allocation, later scans
 * stay dense.  2026-08-25-MEMORY.md v2 names the branch-light end-state (a mask
 * column that scans fuse, compaction deferred to Vec.compact or
 * Sys.poolReset); until that lands with the mask-fusing loops, eager
 * compaction is the correct simple thing.  Capacity beyond the new
 * length stays attached (it recycles with the column).  In-place is
 * sound unconditionally now: no CoW, one owner, real copies. */
V fpr_vec_filter(V f, V vec) {
  vec_t *x = vchk(vec, "Vec.filter: not a Vector");
  uw j = 0;
  for (uw i = 0; i < x->len; i++) {
    V row = row_at(x, i);
    V keep = fpr_apply(f, row);
    if (!ISINT(keep) && ((hdr_t *)keep)->var) {
      if (j != i)
        for (uw k = 0; k < x->ncols; k++)
          *vl_slot(x->cols[k], j) = *vl_slot(x->cols[k], i);
      j++;
    }
  }
  x->len = j;
  return (V)x;
}

V fpr_vec_fold(V f, V z, V vec) {
  vec_t *x = vchk(vec, "Vec.fold: not a Vector");
  V acc = z;
  for (uw i = 0; i < x->len; i++) {
    V pf = fpr_apply(f, acc);
    acc = fpr_apply(pf, row_at(x, i));
    /* the intermediate PAP is churn: release it, or an immortal
     * actor's generic-tier fold bleeds one pap per element (the
     * saturating apply copies args out; nothing retains pf) */
    if (!ISINT(pf) && TID(pf) == T_PAP && pf != f) fpr_free(pf);
  }
  return mktup2(acc, (V)x);
}

static V h_fromList(V xs) {
  V out = h_new((V)&fpr_unit);
  while (!ISINT(xs) && TID(xs) == T_LIST && ((hdr_t *)xs)->var == 1) {
    out = h_push(*(V *)((char *)xs + 8), out);
    xs = *(V *)((char *)xs + 8 + sizeof(uw));
  }
  return out;
}

static V h_fromListAs(V spec, V xs) {
  V out = h_newAs(spec);
  while (!ISINT(xs) && TID(xs) == T_LIST && ((hdr_t *)xs)->var == 1) {
    out = h_push(*(V *)((char *)xs + 8), out);
    xs = *(V *)((char *)xs + 8 + sizeof(uw));
  }
  return out;
}

static V h_toList(V vec) {
  vec_t *x = vchk(vec, "Vec.toList: not a Vector");
  V acc = 0;
  /* Nil */
  hdr_t *nil = (hdr_t *)fpr_alloc(8);
  nil->tid = T_LIST;
  nil->var = 0;
  acc = (V)nil;
  for (uw i = x->len; i > 0; i--) {
    hdr_t *c = (hdr_t *)fpr_alloc(8 + 2 * sizeof(uw));
    c->tid = T_LIST;
    c->var = 1;
    *(V *)((char *)c + 8) = row_at(x, i - 1);
    *(V *)((char *)c + 8 + sizeof(uw)) = acc;
    acc = (V)c;
  }
  vfree(x); /* consumed input */
  return acc;
}

/* split after element n: (first n, rest).  Both halves are FRESH vectors
 * (each hart sorts its own — a shared block chain would put two writers
 * on one ring, which this design never allows); the original is consumed
 * (linearity: the caller no longer owns it). */
static V h_split(V nv, V vec) {
  vec_t *x = vchk(vec, "Vec.split: not a Vector");
  if (!ISINT(nv)) fpr_cpanic("Vec.split: count not an Int");
  sw n = UNTAG(nv);
  if (n < 0) n = 0;
  if ((uw)n > x->len) n = (sw)x->len;
  V lo = vhas_float(x) ? h_new_like(x) : h_new((V)&fpr_unit);
  V hi = vhas_float(x) ? h_new_like(x) : h_new((V)&fpr_unit);
  for (uw i = 0; i < (uw)n; i++) lo = h_push(row_at(x, i), lo);
  for (uw i = (uw)n; i < x->len; i++) hi = h_push(row_at(x, i), hi);
  vfree(x); /* consumed input */
  return mktup2(lo, hi);
}

/* ---- the discoverable-symbol table ------------------------------------ */
FPR_FN(fpr_g_Vec_x2enew, h_new, 1);
FPR_FN(fpr_g_Vec_x2epush, h_push, 2);
FPR_FN(fpr_g_Vec_x2elen, h_len, 1);
FPR_FN(fpr_g_Vec_x2eget, h_get, 2);
FPR_FN(fpr_g_Vec_x2eset, h_set, 3);
/* at/put: the same operations as get/set under their other names.  They
 * were the 0-based pair while get/set were 1-based; since the whole system
 * went 0-based (docs/2026-10-02-ZERO-BASED.md) the two pairs are one. */
static V h_at(V iv, V vec) {
  if (!ISINT(iv)) fpr_cpanic("Vec.at: index not an Int");
  return h_get(iv, vec);
}
/* The same three reads WITHOUT the (value, handle) pair.  The compiler
 * (Inline.hs vecPeek) calls these where the pair is taken apart at once,
 * `(x, v2) = Vec.at i v`: the handle returned is always the one passed
 * in, so v2 is v and the 48-byte tuple was all that was allocated --
 * per element read, in every vector loop.  Same checks, same messages. */
static V h_peek_get(V iv, V vec) {
  vec_t *x = vchk(vec, "Vec.get: not a Vector");
  if (!ISINT(iv)) fpr_cpanic("Vec.get: index not an Int");
  sw i = UNTAG(iv);
  if (i < 0 || (uw)i >= x->len) fpr_cpanic("Vec.get: index out of range");
  return row_at(x, (uw)i);
}
static V h_peek_at(V iv, V vec) {
  if (!ISINT(iv)) fpr_cpanic("Vec.at: index not an Int");
  return h_peek_get(iv, vec);
}
static V h_peek_len(V vec) {
  vec_t *x = vchk(vec, "Vec.len: not a Vector");
  return TAG((sw)x->len);
}
static V h_put(V iv, V v, V vec) {
  if (!ISINT(iv)) fpr_cpanic("Vec.put: index not an Int");
  return h_set(iv, v, vec);
}
FPR_FN(fpr_g_Vec_x2eat, h_at, 2);
FPR_FN(fpr_g__x24vec_x2eget, h_peek_get, 2);
FPR_FN(fpr_g__x24vec_x2eat, h_peek_at, 2);
FPR_FN(fpr_g__x24vec_x2elen, h_peek_len, 1);
FPR_FN(fpr_g_Vec_x2eput, h_put, 3);
FPR_FN(fpr_g_Vec_x2emap, fpr_vec_map, 2);
FPR_FN(fpr_g_Vec_x2emapAs, h_mapAs, 3);
FPR_FN(fpr_g_Vec_x2efilter, fpr_vec_filter, 2);
FPR_FN(fpr_g_Vec_x2efold, fpr_vec_fold, 3);
FPR_FN(fpr_g_Vec_x2enewAs, h_newAs, 1);
FPR_FN(fpr_g_Vec_x2erange, h_range, 2);
FPR_FN(fpr_g_Vec_x2efromList, h_fromList, 1);
FPR_FN(fpr_g_Vec_x2efromListAs, h_fromListAs, 2);
FPR_FN(fpr_g_Vec_x2etoList, h_toList, 1);
FPR_FN(fpr_g_Vec_x2efree, h_free, 1);
FPR_FN(fpr_g_Vec_x2esplit, h_split, 2);

/* ==== the numeric SIMD tier ============================================
 * Element-wise ops over ONE unboxed Int column, striding the raw block
 * words contiguously -- the loops below are exactly the shapes RVV/NEON
 * name (vadd.vx, vmul.vv, vmerge.vvm, vluxei, vmslt), written so the C
 * compiler's autovectorizer takes them on hosted targets.  Two vectors
 * of equal length share an IDENTICAL block partition (the directory is
 * index-structured), so zips pair blocks and stay contiguous.
 *
 * Linearity discipline: unary ops mutate in place and return the same
 * vector; zips mutate dst in place and CONSUME src (freed) -- dup first
 * if you need it again; gather/slice thread the read-only operand back
 * in a tuple; blend consumes mask and src.  Int column only: anything
 * else panics (this is the numeric tier, not the generic one).      */

/* the whole tier compiles under the full vectorizer regardless of the
 * build's baseline -O level: these loops ARE the SIMD, so the pragma is
 * part of the contract, not an optimization hint.
 *
 * What actually vectorizes today: adds, min/max, compares, ges, blend
 * and burst take SSE2/NEON lanes (paddq / cmgt / vmerge shapes).  The
 * 64-bit MULTIPLIES (axpb, zipMul) stay scalar on hosted baselines --
 * SSE has no 64-lane multiply below AVX-512, NEON none at all -- and
 * become vmul.vx/.vv at SEW=64 on the RVV target this tier is shaped
 * for.  Element width is the machine word by design (16.16 products
 * need the headroom); narrowing lanes to buy host multipliers would
 * trade away correctness for a benchmark. */
#pragma GCC push_options
#pragma GCC optimize("O3,tree-vectorize")

static vec_t *vnum(V v, const char *who) {
  vec_t *x = vchk(v, who);
  /* the integer SIMD tier (axpb/sar/minS/zipAdd/...) is Int-only: a
   * float vector is REFUSED here rather than reinterpreted, since its
   * words are IEEE bits and `a * p[i] + b` on them is nonsense.  Float
   * lanes are the compiler's specialized column loops (Codegen.hs) and
   * Vec.map over F64 -- not these fixed-function ops (v1). */
  if (x->len && VREP(x) != VR_INT)
    fpr_cpanic("SIMD tier: not an Int vector (float vectors: use Vec.map / the specialized loops)");
  return x;
}

/* Optional hosted GPU tier.  A strong backend definition may replace
 * this default.  It must leave the column untouched when returning
 * zero.  Contiguous columns: the hook takes the raw span directly. */
__attribute__((weak)) int fpr_gpu_vec_axpb(uw *col, uw len, sw a, sw b) {
  (void)col; (void)len; (void)a; (void)b;
  return 0;
}

__attribute__((weak)) int fpr_gpu_vec_fold_pair_sum(void *col0, void *col1,
                                                     uw len, sw seed, sw *out) {
  (void)col0; (void)col1; (void)len; (void)seed; (void)out;
  return 0;
}

static int gpu_axpb_exact(vec_t *x, sw a, sw b) {
  if (x->len < 65536 || a < INT32_MIN || a > INT32_MAX ||
      b < INT32_MIN || b > INT32_MAX)
    return 0;
  sw *p = (sw *)x->cols[0]->base;
  for (uw i = 0; i < x->len; i++) {
    if (p[i] < INT32_MIN || p[i] > INT32_MAX) return 0;
    int64_t product = (int64_t)(int32_t)a * (int64_t)(int32_t)p[i];
    if (product < INT32_MIN || product > INT32_MAX) return 0;
    int64_t result = product + (int64_t)(int32_t)b;
    if (result < INT32_MIN || result > INT32_MAX) return 0;
  }
  return fpr_gpu_vec_axpb(x->cols[0]->base, x->len, a, b);
}

/* one column, one contiguous run: sw *p over all n words */
#define VS_BLOCKS(x, BODY)                                           \
  do {                                                               \
    uw n = (x)->len;                                                 \
    sw *p = (sw *)(x)->cols[0]->base;                                \
    (void)p;                                                         \
    if (n) { BODY; }                                                 \
  } while (0)

static V h_iota(V nv) {
  if (!ISINT(nv)) fpr_cpanic("Vec.iota: not an Int");
  sw n = UNTAG(nv);
  V v = h_new((V)&fpr_unit);
  for (sw i = 0; i < n; i++) v = h_push(TAG(i), v);
  return v;
}

static V h_dup(V vec) {
  vec_t *x = vchk(vec, "Vec.dup: not a Vector");
  /* an HONEST copy (v2): two independent owners from this point --
   * the cost is visible at the dup, not smuggled into the next write */
  return mktup2((V)vcopy(x), (V)x);
}

static V h_axpb(V av, V bv, V vec) {
  vec_t *x = vnum(vec, "Vec.axpb: not a Vector");
  sw a = UNTAG(av), b = UNTAG(bv);
  if (gpu_axpb_exact(x, a, b)) return (V)x;
  VS_BLOCKS(x, { for (uw i = 0; i < n; i++) p[i] = a * p[i] + b; });
  return (V)x;
}

static V h_sar(V kv, V vec) {
  vec_t *x = vnum(vec, "Vec.sar: not a Vector");
  sw k = UNTAG(kv);
  VS_BLOCKS(x, { for (uw i = 0; i < n; i++) p[i] >>= k; });
  return (V)x;
}

static V h_minS(V kv, V vec) {
  vec_t *x = vnum(vec, "Vec.minS: not a Vector");
  sw k = UNTAG(kv);
  VS_BLOCKS(x, { for (uw i = 0; i < n; i++) p[i] = p[i] < k ? p[i] : k; });
  return (V)x;
}

static V h_maxS(V kv, V vec) {
  vec_t *x = vnum(vec, "Vec.maxS: not a Vector");
  sw k = UNTAG(kv);
  VS_BLOCKS(x, { for (uw i = 0; i < n; i++) p[i] = p[i] > k ? p[i] : k; });
  return (V)x;
}

static V h_ges(V kv, V vec) {
  vec_t *x = vnum(vec, "Vec.ges: not a Vector");
  sw k = UNTAG(kv);
  VS_BLOCKS(x, { for (uw i = 0; i < n; i++) p[i] = p[i] >= k; });
  return (V)x;
}

/* zips: dst op= src, one contiguous run each */
static vec_t *vzip2(V dv, V sv, const char *who) {
  vec_t *d = vnum(dv, who), *s = vnum(sv, who);
  if (d->len != s->len) fpr_cpanic("SIMD tier: zip length mismatch");
  return s;
}
#define VS_ZIP(dv, sv, WHO, EXPR)                                            \
  do {                                                                       \
    vec_t *_d = vnum(dv, WHO), *_s = vzip2(dv, sv, WHO);             \
    uw _n = _d->len;                                                         \
    sw *p = (sw *)_d->cols[0]->base, *q = (sw *)_s->cols[0]->base;           \
    for (uw _i = 0; _i < _n; _i++) { sw A = p[_i], B = q[_i]; p[_i] = (EXPR); } \
    vfree(_s);                                                               \
    return (V)_d;                                                            \
  } while (0)

static V h_zipAdd(V dv, V sv) { VS_ZIP(dv, sv, "Vec.zipAdd", A + B); }
static V h_zipMul(V dv, V sv) { VS_ZIP(dv, sv, "Vec.zipMul", A * B); }
static V h_zipMin(V dv, V sv) { VS_ZIP(dv, sv, "Vec.zipMin", A < B ? A : B); }
static V h_zipLt(V dv, V sv)  { VS_ZIP(dv, sv, "Vec.zipLt", A < B); }
static V h_zipDiv(V dv, V sv) { VS_ZIP(dv, sv, "Vec.zipDiv", B == 0 ? 0 : A / B); }

/* gather: idx[i] := src[idx[i]] (out of range -> 0); src threads back */
static V h_gather(V iv, V sv) {
  vec_t *x = vnum(iv, "Vec.gather: not a Vector");
  vec_t *s = vnum(sv, "Vec.gather: not a Vector");
  VS_BLOCKS(x, {
    for (uw i = 0; i < n; i++) {
      sw ix = p[i];
      p[i] = (ix >= 0 && (uw)ix < s->len) ? *(sw *)vl_slot(s->cols[0], (uw)ix) : 0;
    }
  });
  return mktup2((V)x, (V)s);
}

/* blend: dst[i] := mask[i] ? src[i] : dst[i]; mask and src consumed */
static V h_blend(V mv, V sv, V dv) {
  vec_t *m = vnum(mv, "Vec.blend: not a Vector");
  vec_t *s = vnum(sv, "Vec.blend: not a Vector");
  vec_t *d = vnum(dv, "Vec.blend: not a Vector");
  if (m->len != d->len || s->len != d->len) fpr_cpanic("Vec.blend: length mismatch");
  {
    uw n = d->len;
    sw *pd = (sw *)d->cols[0]->base, *pm = (sw *)m->cols[0]->base,
       *ps = (sw *)s->cols[0]->base;
    for (uw i = 0; i < n; i++) pd[i] = pm[i] ? ps[i] : pd[i];
  }
  vfree(m); vfree(s);
  return (V)d;
}

/* slice: fresh copy of [off, off+n) (0-based); original threads back */
static V h_slice(V ov, V nv, V vec) {
  vec_t *x = vnum(vec, "Vec.slice: not a Vector");
  if (!ISINT(ov) || !ISINT(nv)) fpr_cpanic("Vec.slice: bounds not Ints");
  sw off = UNTAG(ov), n = UNTAG(nv);
  if (off < 0 || n < 0 || (uw)(off + n) > x->len) fpr_cpanic("Vec.slice: out of range");
  V c = h_new((V)&fpr_unit);
  for (sw i = 0; i < n; i++) c = h_push(TAG(*(sw *)vl_slot(x->cols[0], (uw)(off + i))), c);
  return mktup2(c, (V)x);
}

/* burst: dst[off..] := src, contiguously; src consumed */
static V h_burst(V ov, V sv, V dv) {
  vec_t *s = vnum(sv, "Vec.burst: not a Vector");
  vec_t *d = vnum(dv, "Vec.burst: not a Vector");
  if (!ISINT(ov)) fpr_cpanic("Vec.burst: offset not an Int");
  sw off = UNTAG(ov);
  if (off < 0 || (uw)off + s->len > d->len) fpr_cpanic("Vec.burst: out of range");
  VS_BLOCKS(s, {
    sw *pd = (sw *)d->cols[0]->base + off;
    for (uw i = 0; i < n; i++) pd[i] = p[i];
  });
  vfree(s);
  return (V)d;
}

/* ---- the DDA lanes: subtract, compare-equal, max, abs, scalar-eq ----
 * Voxel traversal needs per-lane axis selection (which tMax is smallest),
 * per-lane sign handling, and per-lane block-id tests; these are the
 * remaining shapes for that (vsub.vv, vmseq.vv/.vx, vmax.vv). */

static V h_zipSub(V dv, V sv) { VS_ZIP(dv, sv, "Vec.zipSub", A - B); }
static V h_zipEq(V dv, V sv)  { VS_ZIP(dv, sv, "Vec.zipEq", A == B); }
static V h_zipMax(V dv, V sv) { VS_ZIP(dv, sv, "Vec.zipMax", A > B ? A : B); }

static V h_absv(V vec) {
  vec_t *x = vnum(vec, "Vec.absv: not a Vector");
  VS_BLOCKS(x, { for (uw i = 0; i < n; i++) p[i] = p[i] < 0 ? -p[i] : p[i]; });
  return (V)x;
}

static V h_eqS(V kv, V vec) {
  vec_t *x = vnum(vec, "Vec.eqS: not a Vector");
  sw k = UNTAG(kv);
  VS_BLOCKS(x, { for (uw i = 0; i < n; i++) p[i] = p[i] == k; });
  return (V)x;
}

#pragma GCC pop_options

FPR_FN(fpr_g_Vec_x2eiota, h_iota, 1);
FPR_FN(fpr_g_Vec_x2edup, h_dup, 1);
FPR_FN(fpr_g_Vec_x2eaxpb, h_axpb, 3);
FPR_FN(fpr_g_Vec_x2esar, h_sar, 2);
FPR_FN(fpr_g_Vec_x2eminS, h_minS, 2);
FPR_FN(fpr_g_Vec_x2emaxS, h_maxS, 2);
FPR_FN(fpr_g_Vec_x2eges, h_ges, 2);
FPR_FN(fpr_g_Vec_x2ezipAdd, h_zipAdd, 2);
FPR_FN(fpr_g_Vec_x2ezipMul, h_zipMul, 2);
FPR_FN(fpr_g_Vec_x2ezipMin, h_zipMin, 2);
FPR_FN(fpr_g_Vec_x2ezipLt, h_zipLt, 2);
FPR_FN(fpr_g_Vec_x2ezipDiv, h_zipDiv, 2);
FPR_FN(fpr_g_Vec_x2egather, h_gather, 2);
FPR_FN(fpr_g_Vec_x2eblend, h_blend, 3);
FPR_FN(fpr_g_Vec_x2eslice, h_slice, 3);
FPR_FN(fpr_g_Vec_x2eburst, h_burst, 3);
FPR_FN(fpr_g_Vec_x2ezipSub, h_zipSub, 2);
FPR_FN(fpr_g_Vec_x2ezipEq, h_zipEq, 2);
FPR_FN(fpr_g_Vec_x2ezipMax, h_zipMax, 2);
FPR_FN(fpr_g_Vec_x2eabsv, h_absv, 1);
FPR_FN(fpr_g_Vec_x2eeqS, h_eqS, 2);
