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
 * inferred on RV64: a float V is its bit pattern, so the runtime cannot tell
 * one from a pointer -- fix_layout's first-push rule is undecidable
 * for floats (the documented v1 hazard, turned into an API instead of
 * a guess).  Vec.newAs declares the layout up front. */
#include "vec_layout.h"
/* every piece of a Vector -- header, directory, kinds, shape, columns -- is
 * bulk storage: fpr_alloc_bulk, the actor's base pool whatever region is open,
 * so an owned Vector survives a turn's reset and crosses its boundary by
 * handle (docs/2026-10-24-REGIONS-STAGE2.md).  The tuples and records Vec
 * operations RETURN are ordinary values and stay on fpr_alloc. */

/* ---- column access ---------------------------------------------------- */

static inline uw *vl_slot(col_t *c, uw i) { return &c->base[i]; }

static void col_grow(col_t *c) {
  uw ncap = c->cap ? c->cap * 2 : (uw)VL_B0;
  c->base = (uw *)fpr_realloc_bulk((V)c->base, ncap * sizeof(uw));
  c->cap = ncap;
}

static col_t *col_new(void) {
  col_t *c = (col_t *)fpr_alloc_bulk(sizeof(col_t));
  c->cap = 0;
  c->base = 0;
  return c;
}

static void col_free(col_t *c) {
  if (c->base) fpr_free_raw((V)c->base); /* >8KiB: bigfree LIFO */
  fpr_free_raw((V)c);
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
    n->base = (uw *)fpr_alloc_bulk(cap * sizeof(uw));
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
  x->cols = (col_t **)fpr_alloc_bulk(ncols * sizeof(col_t *));
  x->kinds = (uint8_t *)fpr_alloc_bulk(VKINDS_BYTES(ncols));
  for (uw k = 0; k < VKINDS_BYTES(ncols); k++) x->kinds[k] = VK_BOX;
  for (uw k = 0; k < ncols; k++) x->cols[k] = 0;
}
static void vdir_free(vec_t *x) {
  if (x->cols) fpr_free_raw((V)x->cols);
  if (x->kinds) fpr_free_raw((V)x->kinds);
  x->cols = 0;
  x->kinds = 0;
  x->ncols = 0;
  if (x->shape) fpr_free_raw((V)x->shape);
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
    x->shape = (vec_shape_t *)fpr_alloc_bulk(src->shape_len * sizeof(vec_shape_t));
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
  vec_t *n = (vec_t *)fpr_alloc_object_bulk(sizeof(vec_t));
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
  vec_t *x = (vec_t *)fpr_alloc_object_bulk(sizeof(vec_t));
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
  /* Float columns store the V verbatim: IEEE bits on RV64, a pointer to
   * a numeric leaf on RV32. Width comes from the declaration. */
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
  x->shape = (vec_shape_t *)fpr_alloc_bulk(sp->len * sizeof(vec_shape_t));
  uw *stack = (uw *)fpr_alloc_raw(sp->len * sizeof(uw));
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
  fpr_free_raw((V)stack);
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
  if (i < 0 || (uw)i >= x->len) fpr_trap_range("Vec.get: index out of range", i, x->len);
  return mktup2(row_at(x, (uw)i), (V)x);
}

static V h_set(V iv, V v, V vec) {
  vec_t *x = vchk(vec, "Vec.set: not a Vector");
  if (!ISINT(iv)) fpr_cpanic("Vec.set: index not an Int");
  sw i = UNTAG(iv);
  if (i < 0 || (uw)i >= x->len) fpr_trap_range("Vec.set: index out of range", i, x->len);
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
 * (Core.Typed.VectorRead) calls these where the pair is taken apart at once,
 * `(x, v2) = Vec.at i v`: the handle returned is always the one passed
 * in, so v2 is v and the 48-byte tuple was all that was allocated --
 * per element read, in every vector loop.  Same checks, same messages. */
static V h_peek_get(V iv, V vec) {
  vec_t *x = vchk(vec, "Vec.get: not a Vector");
  if (!ISINT(iv)) fpr_cpanic("Vec.get: index not an Int");
  sw i = UNTAG(iv);
  if (i < 0 || (uw)i >= x->len) fpr_trap_range("Vec.get: index out of range", i, x->len);
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
static V h_sortWith(V cmp, V vec); /* below, beside h_dup */
FPR_FN(fpr_g_sortVecWith, h_sortWith, 2);

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

/* The typed fold kernel's form of the hook: the tagged Int sum when the
   hook took the fold, 0 (not an Int) when it declined. */
V fpr_gpu_vec_fold_pair_sum_tagged(void *col0, void *col1, uw len, sw seed) {
  sw out;
  if (!fpr_gpu_vec_fold_pair_sum(col0, col1, len, seed, &out)) return 0;
  return (V)(((uw)out << 1) | 1);
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

/* sortVecWith (std/vector.fpr sortWith): a STABLE sort in place, by the same merge as List.sortWith
 * (runtime.c fpr_sort_perm; the same comparator protocol: `cmp b a`, b from
 * the later run, b first only when Less).  Each row is rebuilt ONCE as the
 * comparator's argument (a record row is one cell; scalars build nothing),
 * the merge sorts a permutation, and then every column is moved by it:
 * at most n * ceil(log2 n) comparisons, n + ncols * n word moves, and 3n
 * words of raw scratch returned before it answers.  Consumes and returns the
 * vector (linear: the handle comes back sorted). */
static V h_sortWith(V cmp, V vec) {
  vec_t *x = vchk(vec, "Vector.sortWith: not a Vector");
  uw n = x->len;
  if (n < 2) return (V)x;
  V *keys = (V *)fpr_alloc_raw((V)(3 * n * sizeof(V)));
  uw *idx = (uw *)(keys + n), *tmp = idx + n;
  for (uw i = 0; i < n; i++) keys[i] = row_at(x, i);
  uw *perm = fpr_sort_perm(cmp, keys, idx, tmp, n);
  uw *spare = perm == idx ? tmp : idx; /* the other n words */
  for (uw k = 0; k < x->ncols; k++) {
    uw *base = x->cols[k]->base;
    for (uw i = 0; i < n; i++) spare[i] = base[perm[i]];
    __builtin_memcpy(base, spare, n * sizeof(uw));
  }
  fpr_free_raw((V)keys);
  return (V)x;
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
  if (d->len != s->len) fpr_trap("SIMD tier: zip length mismatch");
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
  if (m->len != d->len || s->len != d->len) fpr_trap("Vec.blend: length mismatch");
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

/* ==== MutMap: the LINEAR hash table (std/mutmap.fpr) ====================
 * docs/2026-11-10-MUTMAP.md.  A MutMap is a vec_t with rep VR_MAP and three
 * columns -- 0: the stored hash (raw; 0 = an empty slot, otherwise the key's
 * hash with the top bit set), 1: the key (raw Int, or a boxed String),
 * 2: the value (boxed) -- open addressing with LINEAR probing over a
 * power-of-two number of slots (`len`), at most 3/4 full, removal by
 * backward shift (no tombstones, so a probe never passes more than the
 * cluster it is in).  eltid counts the entries, elvar is the key kind.
 *
 * It is a vec_t so that everything that already moves, copies, bounds and
 * releases a Vector does the same to a MutMap with no new case: the deep
 * copier (send, keep, Sys.loop's boundary refusal), the region/bulk storage
 * rule, and the release path.  Empty slots hold TAG(0) in the boxed columns,
 * which every walker reads as an Int.
 *
 * LINEARITY is what makes the in-place writes sound (`MutMap 1 k v` in the
 * prelude): nothing else can hold the old version.  Every operation consumes
 * the map and hands the same handle back.
 *
 * Costs (compiler/Cost.hs, the mutmap* rules): with C = the capacity before
 * the call and |k| the key's length, one probe sequence visits at most C
 * slots and compares a key only where the stored hash is equal; growth
 * (a doubling) re-places every entry by its STORED hash, never rehashing a
 * key, and is charged to the insert that triggers it, as Vector's push. */
#define MM_KINT 1u
#define MM_KSTR 2u
#define MM_TOP ((uw)1 << (sizeof(uw) * 8 - 1))
#define MM_MIN 8u

/* ---- the hashes: deterministic, unseeded, not cryptographic -------------
 * 64-bit words: Int keys go through splitmix64's finalizer (a bijection, so
 * distinct Ints never collide before the slot mask); String bytes through
 * XXH64's single-lane round and avalanche (8-byte words, then 4, then
 * bytes), with seed 0 and the length mixed in first.  Only 64x64->64
 * multiplies: no 128-bit product, so no libgcc call on bare metal.
 * 32-bit words (RV32): murmur3's fmix32 for Ints and murmur3_32 for bytes,
 * 32-bit multiplies only.  The hash is part of nothing observable except
 * slot order and strHash/intHash themselves; a fixed hash can be flooded by
 * chosen keys (see the doc), which costs probes, never correctness. */
#if UINTPTR_MAX > 0xFFFFFFFFu
static inline uw mm_rotl(uw x, unsigned r) { return (x << r) | (x >> (64 - r)); }
static uw mm_int_hash(sw k) {
  uw z = (uw)k + 0x9E3779B97F4A7C15ull;
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
  return z ^ (z >> 31);
}
#define XP1 0x9E3779B185EBCA87ull
#define XP2 0xC2B2AE3D27D4EB4Full
#define XP3 0x165667B19E3779F9ull
#define XP4 0x85EBCA77C2B2AE63ull
#define XP5 0x27D4EB2F165667C5ull
static uw mm_bytes_hash(const uint8_t *p, uw n) {
  uw h = XP5 + n, i = 0;
  for (; i + 8 <= n; i += 8) {
    uw w = 0;
    for (unsigned b = 0; b < 8; b++) w |= (uw)p[i + b] << (8 * b);
    w *= XP2; w = mm_rotl(w, 31); w *= XP1;
    h ^= w; h = mm_rotl(h, 27) * XP1 + XP4;
  }
  if (i + 4 <= n) {
    uw w = 0;
    for (unsigned b = 0; b < 4; b++) w |= (uw)p[i + b] << (8 * b);
    h ^= w * XP1; h = mm_rotl(h, 23) * XP2 + XP3;
    i += 4;
  }
  for (; i < n; i++) { h ^= (uw)p[i] * XP5; h = mm_rotl(h, 11) * XP1; }
  h ^= h >> 33; h *= XP2; h ^= h >> 29; h *= XP3; h ^= h >> 32;
  return h;
}
#else
static inline uw mm_rotl(uw x, unsigned r) { return (x << r) | (x >> (32 - r)); }
static uw mm_fmix(uw h) {
  h ^= h >> 16; h *= 0x85EBCA6Bu; h ^= h >> 13; h *= 0xC2B2AE35u; h ^= h >> 16;
  return h;
}
static uw mm_int_hash(sw k) { return mm_fmix((uw)k + 0x9E3779B9u); }
static uw mm_bytes_hash(const uint8_t *p, uw n) {
  uw h = 0, i = 0;
  for (; i + 4 <= n; i += 4) {
    uw w = (uw)p[i] | (uw)p[i + 1] << 8 | (uw)p[i + 2] << 16 | (uw)p[i + 3] << 24;
    w *= 0xCC9E2D51u; w = mm_rotl(w, 15); w *= 0x1B873593u;
    h ^= w; h = mm_rotl(h, 13) * 5u + 0xE6546B64u;
  }
  uw w = 0;
  switch (n & 3) {
    case 3: w ^= (uw)p[i + 2] << 16; /* fallthrough */
    case 2: w ^= (uw)p[i + 1] << 8;  /* fallthrough */
    case 1: w ^= (uw)p[i]; w *= 0xCC9E2D51u; w = mm_rotl(w, 15); w *= 0x1B873593u; h ^= w;
  }
  return mm_fmix(h ^ n);
}
#endif

static uw mm_str_hash(V s) {
  if (ISINT(s) || TID(s) != T_STR) fpr_cpanic("strHash: not a String");
  str_t *t = (str_t *)s;
  return mm_bytes_hash(t->bytes, t->len);
}
/* strHash / intHash: the table's hashes as Ints, nonnegative (the top two
 * bits dropped so the result is a tagged Int on every word size) */
static V g_strHash(V s) { return TAG((sw)(mm_str_hash(s) >> 2)); }
static V g_intHash(V k) {
  if (!ISINT(k)) fpr_cpanic("intHash: not an Int");
  return TAG((sw)(mm_int_hash(UNTAG(k)) >> 2));
}

static vec_t *mchk(V m, const char *who) {
  vec_t *x = vchk(m, who);
  if (VREP(x) != VR_MAP) fpr_cpanic(who);
  return x;
}
static inline uw *mm_h(vec_t *x) { return x->cols[0]->base; }
static inline uw *mm_k(vec_t *x) { return x->cols[1]->base; }
static inline uw *mm_v(vec_t *x) { return x->cols[2]->base; }

/* the key's stored hash (top bit set), checking it is the map's key kind */
static uw mm_key_hash(vec_t *x, V k) {
  if (x->elvar == MM_KINT) {
    if (!ISINT(k)) fpr_cpanic("MutMap: an Int-keyed map got a non-Int key");
    return mm_int_hash(UNTAG(k)) | MM_TOP;
  }
  if (ISINT(k) || TID(k) != T_STR) fpr_cpanic("MutMap: a String-keyed map got a non-String key");
  return mm_str_hash(k) | MM_TOP;
}
static inline uw mm_key_raw(vec_t *x, V k) { return x->elvar == MM_KINT ? (uw)UNTAG(k) : (uw)k; }
static int mm_key_eq(vec_t *x, uw slot, V k) {
  uw s = mm_k(x)[slot];
  if (x->elvar == MM_KINT) return s == (uw)UNTAG(k);
  if (s == (uw)k) return 1;
  str_t *a = (str_t *)s, *b = (str_t *)k;
  if (a->len != b->len) return 0;
  for (uw i = 0; i < a->len; i++)
    if (a->bytes[i] != b->bytes[i]) return 0;
  return 1;
}
static inline V mm_key_val(vec_t *x, uw slot) {
  uw s = mm_k(x)[slot];
  return x->elvar == MM_KINT ? TAG((sw)s) : (V)s;
}
static void mm_clear(vec_t *x, uw slot) {
  mm_h(x)[slot] = 0;
  mm_k(x)[slot] = x->elvar == MM_KINT ? 0 : (uw)TAG(0);
  mm_v(x)[slot] = (uw)TAG(0);
}

/* fresh, empty columns of ncap slots (a power of two) */
static void mm_cols(vec_t *x, uw ncap) {
  for (uw k = 0; k < 3; k++) {
    col_t *c = col_new();
    if (ncap) {
      c->base = (uw *)fpr_alloc_bulk(ncap * sizeof(uw));
      c->cap = ncap;
    }
    x->cols[k] = c;
  }
  x->len = ncap;
  for (uw i = 0; i < ncap; i++) mm_clear(x, i);
}

/* the slot holding k (>= 0), or -1; *empty gets the first empty slot of the
 * probe (where k would go).  At most `len` slots are visited. */
static sw mm_find(vec_t *x, V k, uw h, uw *empty) {
  uw cap = x->len;
  *empty = (uw)-1;
  if (!cap) return -1;
  uw mask = cap - 1, i = h & mask, *hs = mm_h(x);
  for (uw n = 0; n < cap; n++, i = (i + 1) & mask) {
    if (hs[i] == 0) { *empty = i; return -1; }
    if (hs[i] == h && mm_key_eq(x, i, k)) return (sw)i;
  }
  return -1; /* full: cannot happen at load <= 3/4, kept as the bound */
}

/* the slot capacity that holds n entries at load <= 3/4 */
static uw mm_cap_for(uw n) {
  uw cap = MM_MIN;
  while (cap - cap / 4 < n) {
    if (cap > ((uw)-1 >> 3)) fpr_cpanic("MutMap: capacity out of range");
    cap *= 2;
  }
  return cap;
}

/* re-place every entry into ncap slots by its stored hash (keys are distinct,
 * so no key is compared), then free the old columns */
static void mm_rehash(vec_t *x, uw ncap) {
  col_t *oh = x->cols[0], *ok = x->cols[1], *ov = x->cols[2];
  uw ocap = x->len;
  mm_cols(x, ncap);
  uw mask = ncap - 1, *hs = mm_h(x), *ks = mm_k(x), *vs = mm_v(x);
  for (uw j = 0; j < ocap; j++) {
    uw h = oh->base[j];
    if (!h) continue;
    uw i = h & mask;
    while (hs[i]) i = (i + 1) & mask;
    hs[i] = h; ks[i] = ok->base[j]; vs[i] = ov->base[j];
  }
  col_free(oh); col_free(ok); col_free(ov);
}

static V mm_new(uw kind, V capv) {
  if (!ISINT(capv)) fpr_cpanic("MutMap: the capacity is not an Int");
  sw n = UNTAG(capv);
  vec_t *x = (vec_t *)fpr_alloc_object_bulk(sizeof(vec_t));
  x->tid = T_VEC;
  x->var = VR_MAP;
  x->len = 0;
  x->eltid = 0;
  x->elvar = kind;
  x->ncols = 0; x->kinds = 0; x->cols = 0;
  x->shape = 0; x->shape_len = 0;
  vdir_alloc(x, 3);
  x->kinds[0] = VK_INT;
  x->kinds[1] = kind == MM_KINT ? VK_INT : VK_BOX;
  x->kinds[2] = VK_BOX;
  mm_cols(x, n > 0 ? mm_cap_for((uw)n) : 0);
  return (V)x;
}
static V g_mutmapStrings(V capv) { return mm_new(MM_KSTR, capv); }
static V g_mutmapInts(V capv) { return mm_new(MM_KINT, capv); }

/* withCapacity: room for n entries with no further growth (never shrinks) */
static V g_mutmapReserve(V nv, V m) {
  vec_t *x = mchk(m, "MutMap.withCapacity: not a MutMap");
  if (!ISINT(nv)) fpr_cpanic("MutMap.withCapacity: the capacity is not an Int");
  sw n = UNTAG(nv);
  if (n > 0) {
    uw cap = mm_cap_for((uw)n);
    if (cap > x->len) mm_rehash(x, cap);
  }
  return m;
}

/* place a key known to be absent: grows first when the entry would pass 3/4 */
static void mm_place_new(vec_t *x, V k, uw h, V v, uw empty) {
  uw cap = x->len;
  if (cap == 0 || (x->eltid + 1) > cap - cap / 4 || empty == (uw)-1) {
    mm_rehash(x, cap ? cap * 2 : MM_MIN);
    uw mask = x->len - 1, *hs = mm_h(x);
    empty = h & mask;
    while (hs[empty]) empty = (empty + 1) & mask;
  }
  mm_h(x)[empty] = h;
  mm_k(x)[empty] = mm_key_raw(x, k);
  mm_v(x)[empty] = (uw)v;
  x->eltid++;
}

static V g_mutmapInsert(V k, V v, V m) {
  vec_t *x = mchk(m, "MutMap.insert: not a MutMap");
  uw h = mm_key_hash(x, k), empty;
  sw at = mm_find(x, k, h, &empty);
  if (at >= 0) mm_v(x)[at] = (uw)v;
  else mm_place_new(x, k, h, v, empty);
  return m;
}

static V mm_apply2(V f, V a, V b) {
  V pf = fpr_apply(f, a);
  V r = fpr_apply(pf, b);
  if (!ISINT(pf) && TID(pf) == T_PAP && pf != f) fpr_free(pf);
  return r;
}

/* insertWith f k v: where k is there store `f old v`, else v (std/map's
 * argument order).  f is called at most once. */
static V g_mutmapInsertWith(V f, V k, V v, V m) {
  vec_t *x = mchk(m, "MutMap.insertWith: not a MutMap");
  uw h = mm_key_hash(x, k), empty;
  sw at = mm_find(x, k, h, &empty);
  if (at >= 0) {
    V nv = mm_apply2(f, (V)mm_v(x)[at], v);
    mm_v(x)[at] = (uw)nv; /* f cannot reach the map (it is linear): `at` still holds */
  } else mm_place_new(x, k, h, v, empty);
  return m;
}

/* (the slot holding k, or -1; the map) */
static V g_mutmapSlot(V k, V m) {
  vec_t *x = mchk(m, "MutMap.get: not a MutMap");
  uw h = mm_key_hash(x, k), empty;
  return mktup2(TAG(mm_find(x, k, h, &empty)), m);
}
static uw mm_occupied(vec_t *x, V iv, const char *who) {
  if (!ISINT(iv)) fpr_cpanic(who);
  sw i = UNTAG(iv);
  if (i < 0 || (uw)i >= x->len) fpr_trap_range(who, i, x->len);
  if (!mm_h(x)[i]) fpr_cpanic(who);
  return (uw)i;
}
static V g_mutmapValueAt(V iv, V m) {
  vec_t *x = mchk(m, "MutMap: not a MutMap");
  uw i = mm_occupied(x, iv, "MutMap: not an occupied slot");
  return mktup2((V)mm_v(x)[i], m);
}
static V g_mutmapSetAt(V iv, V v, V m) {
  vec_t *x = mchk(m, "MutMap: not a MutMap");
  uw i = mm_occupied(x, iv, "MutMap: not an occupied slot");
  mm_v(x)[i] = (uw)v;
  return m;
}
/* empty slot i, then pull later entries of its cluster back over the gap
 * (backward shift): every remaining key stays reachable from its home slot */
static void mm_delete(vec_t *x, uw i) {
  uw mask = x->len - 1, *hs = mm_h(x), *ks = mm_k(x), *vs = mm_v(x);
  uw j = i;
  for (;;) {
    j = (j + 1) & mask;
    if (!hs[j]) break;
    uw home = hs[j] & mask;
    /* j may move to i when its home is not cyclically inside (i, j] */
    int inside = i <= j ? (home > i && home <= j) : (home > i || home <= j);
    if (!inside) {
      hs[i] = hs[j]; ks[i] = ks[j]; vs[i] = vs[j];
      i = j;
    }
  }
  mm_clear(x, i);
  x->eltid--;
}
static V g_mutmapRemoveAt(V iv, V m) {
  vec_t *x = mchk(m, "MutMap: not a MutMap");
  mm_delete(x, mm_occupied(x, iv, "MutMap: not an occupied slot"));
  return m;
}
static V g_mutmapRemove(V k, V m) {
  vec_t *x = mchk(m, "MutMap.remove: not a MutMap");
  uw h = mm_key_hash(x, k), empty;
  sw at = mm_find(x, k, h, &empty);
  if (at >= 0) mm_delete(x, (uw)at);
  return m;
}
static V g_mutmapSize(V m) {
  vec_t *x = mchk(m, "MutMap.size: not a MutMap");
  return mktup2(TAG((sw)x->eltid), m);
}
static V g_mutmapCapacity(V m) {
  vec_t *x = mchk(m, "MutMap.capacity: not a MutMap");
  return mktup2(TAG((sw)(x->len - x->len / 4)), m);
}
/* fold f z m: f acc k v over the entries in SLOT order (deterministic for a
 * given word size and sequence of operations; not key order) */
static V g_mutmapFold(V f, V z, V m) {
  vec_t *x = mchk(m, "MutMap.fold: not a MutMap");
  V acc = z;
  for (uw i = 0; i < x->len; i++) {
    if (!mm_h(x)[i]) continue;
    V p1 = fpr_apply(f, acc);
    V p2 = fpr_apply(p1, mm_key_val(x, i));
    acc = fpr_apply(p2, (V)mm_v(x)[i]);
    if (!ISINT(p2) && TID(p2) == T_PAP && p2 != f) fpr_free(p2);
    if (!ISINT(p1) && TID(p1) == T_PAP && p1 != f) fpr_free(p1);
  }
  return mktup2(acc, m);
}
/* (the (key, value) pairs in slot order, the map) */
static V g_mutmapToList(V m) {
  vec_t *x = mchk(m, "MutMap.toList: not a MutMap");
  hdr_t *nil = (hdr_t *)fpr_alloc(8);
  nil->tid = T_LIST;
  nil->var = 0;
  V acc = (V)nil;
  for (uw i = x->len; i > 0; i--) {
    if (!mm_h(x)[i - 1]) continue;
    V pair = mktup2(mm_key_val(x, i - 1), (V)mm_v(x)[i - 1]);
    hdr_t *c = (hdr_t *)fpr_alloc(8 + 2 * sizeof(uw));
    c->tid = T_LIST;
    c->var = 1;
    *(V *)((char *)c + 8) = pair;
    *(V *)((char *)c + 8 + sizeof(uw)) = acc;
    acc = (V)c;
  }
  return mktup2(acc, m);
}
static V g_mutmapFree(V m) {
  vfree(mchk(m, "MutMap.free: not a MutMap"));
  return (V)&fpr_unit;
}

FPR_FN(fpr_g_strHash, g_strHash, 1);
FPR_FN(fpr_g_intHash, g_intHash, 1);
FPR_FN(fpr_g_mutmapStrings, g_mutmapStrings, 1);
FPR_FN(fpr_g_mutmapInts, g_mutmapInts, 1);
FPR_FN(fpr_g_mutmapReserve, g_mutmapReserve, 2);
FPR_FN(fpr_g_mutmapInsert, g_mutmapInsert, 3);
FPR_FN(fpr_g_mutmapInsertWith, g_mutmapInsertWith, 4);
FPR_FN(fpr_g_mutmapSlot, g_mutmapSlot, 2);
FPR_FN(fpr_g_mutmapValueAt, g_mutmapValueAt, 2);
FPR_FN(fpr_g_mutmapSetAt, g_mutmapSetAt, 3);
FPR_FN(fpr_g_mutmapRemoveAt, g_mutmapRemoveAt, 2);
FPR_FN(fpr_g_mutmapRemove, g_mutmapRemove, 2);
FPR_FN(fpr_g_mutmapSize, g_mutmapSize, 1);
FPR_FN(fpr_g_mutmapCapacity, g_mutmapCapacity, 1);
FPR_FN(fpr_g_mutmapFold, g_mutmapFold, 3);
FPR_FN(fpr_g_mutmapToList, g_mutmapToList, 1);
FPR_FN(fpr_g_mutmapFree, g_mutmapFree, 1);
