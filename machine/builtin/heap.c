/* Single-threaded, coalescing segregated heap. No scheduler or OS dependency.
 * The 16 bytes immediately before every payload remain compatible with the
 * shared runtime's object-size ABI; the second word holds a reference count.
 *
 * Physical neighbours permit constant-time coalescing; free blocks alone are
 * indexed by size. A side bitmap authenticates exact live payload starts before
 * find() reads a header. Subtracting PREFIX without this check would accept a
 * forged header inside an allocation. The bitmap uses one bit per 16 bytes
 * (0.78%, rounded to 16 bytes), outside every allocation; no host allocation or
 * fixed heap cap is required.
 */
#include "builtin.h"
#include <stdint.h>
/* REGIONS (docs/2026-10-25-REGIONS-LOOPS-CALLS.md).  This heap has no
 * collector: a value lives until its owner frees it or the region it was
 * allocated in resets.  A region keeps an intrusive list of the blocks it
 * allocated, threaded through `pending` (the link the ARC release worklist
 * uses, never live at the same time: ARC builds open no regions), so a
 * region costs no bytes per allocation and its reset walks only its own
 * blocks.  A block's `used` says which it is: 1 untracked (no region was
 * open, or bulk Vector storage, which outlives every region), 2 in a
 * region's list, 3 in a list and already freed by its owner (the space
 * waits for the reset; the live bit is gone, so a second free is refused). */
#define HEAP_STATE
typedef struct block { uw size; struct block *prev, *next; uw used; uw fields; struct block *pending; const str_t *layout; uw alignment_padding; } block;
_Static_assert((sizeof(block)+16)%16 == 0, "Builtin payload alignment");
_Static_assert(sizeof(uw) == 4 || sizeof(uw) == 8, "Builtin heap requires RV32/RV64 words");
static uw low HEAP_STATE, high HEAP_STATE;
#define PREFIX (sizeof(block) + 16)
#define WORD_BITS (sizeof(uw) * 8)
#define SUBS 8
#ifdef FPR_BUILTIN_HEAP_MAX_BYTES
_Static_assert(FPR_BUILTIN_HEAP_MAX_BYTES > 0,
               "Builtin heap maximum must be positive");
_Static_assert(FPR_BUILTIN_HEAP_MAX_BYTES >= PREFIX + 32,
               "Builtin heap maximum is too small");
_Static_assert(FPR_BUILTIN_HEAP_MAX_BYTES <= UINTPTR_MAX,
               "Builtin heap maximum exceeds address space");
/* Constant-folded at compile time; no runtime clz instruction/libgcc dependency.
 * Class f is log2(size/16)-2 for sizes >=128, with a separate small row. */
enum { CLASS_ROWS = FPR_BUILTIN_HEAP_MAX_BYTES < 128 ? 1 :
  62 - __builtin_clzll((unsigned long long)FPR_BUILTIN_HEAP_MAX_BYTES >> 4) };
#else
enum { CLASS_ROWS = WORD_BITS };
#endif
static block *bins[CLASS_ROWS][SUBS] HEAP_STATE;
static unsigned char submap[CLASS_ROWS] HEAP_STATE;
static uw firstmap HEAP_STATE, live_count HEAP_STATE;
static unsigned char *live_map HEAP_STATE;
#if defined(FPR_BUILTIN_HEAP_STATS)
static fpr_builtin_heap_stats statistics HEAP_STATE;
#define HEAP_STAT(code) do { code; } while (0)
#else
#define HEAP_STAT(code) ((void)0)
#endif
#ifdef FPR_BUILTIN_HEAP_TEST
/* Logical allocator work, excluding required payload zero/copy bytes. */
uw fpr_builtin_heap_lookup_steps, fpr_builtin_heap_allocation_steps;
#define LOOKUP_STEP() (++fpr_builtin_heap_lookup_steps)
#define ALLOCATION_STEP() (++fpr_builtin_heap_allocation_steps)
#else
#define LOOKUP_STEP() ((void)0)
#define ALLOCATION_STEP() ((void)0)
#endif
static uw *meta(block *b) { return (uw *)((char *)b + sizeof(block)); }
static V payload(block *b) { return (V)((char *)b + PREFIX); }
/* Every payload/capacity is 16-byte aligned. Word stores avoid eight separate
 * read/modify/write bus transactions per word on the 64-bit board's 32-bit RAM
 * port. may_alias permits the payload's arbitrary runtime object layout. */
typedef uw heap_word __attribute__((may_alias));
static void zero_words(V v, uw bytes) {
  heap_word *p = (heap_word *)v;
  for (uw i = 0; i < bytes / sizeof(heap_word); i++) p[i] = 0;
}
static void copy_payload(V to, V from, uw bytes) {
  heap_word *dst = (heap_word *)to, *src = (heap_word *)from;
  for (uw i = 0; i < bytes / sizeof(heap_word); i++) dst[i] = src[i];
}
static void initialize_block(block *b, uw size, block *prev, block *next) {
  /* A struct zero initializer becomes a byte-oriented memset at -Os. These
   * aligned words keep splitting a block cheap on the board's RAM port. */
  zero_words((V)b, sizeof(*b));
  b->size = size; b->prev = prev; b->next = next;
}
/* log2 and first-set-bit without libgcc or a hardware bit-manip extension. */
static unsigned log2_word(uw v) {
  unsigned n = 0;
#if UINTPTR_MAX > UINT32_MAX
  if (v >> 32) { v >>= 32; n += 32; }
#endif
  if (v >> 16) { v >>= 16; n += 16; }
  if (v >> 8) { v >>= 8; n += 8; }
  if (v >> 4) { v >>= 4; n += 4; }
  if (v >> 2) { v >>= 2; n += 2; }
  return n + (unsigned)(v >> 1);
}
static unsigned first_bit(uw bits) { return log2_word(bits & (0 - bits)); }
static void size_class(uw size, unsigned *f, unsigned *s) {
  uw units = size >> 4;
  unsigned n = log2_word(units);
  if (n < 3) { *f = 0; *s = (unsigned)units; }
  else { *f = n - 2; *s = (unsigned)(units >> (n - 3)) - SUBS; }
}
/* fields/pending are free-list links only while the block is free. They retain
 * their existing exact-layout/worklist meanings throughout its allocated life. */
static block *free_prev(block *b) { return (block *)b->fields; }
static void insert_free(block *b) {
  unsigned f, s; size_class(b->size, &f, &s);
  b->alignment_padding = f * SUBS + s;
  b->fields = 0; b->pending = bins[f][s];
  if (b->pending) b->pending->fields = (uw)b;
  bins[f][s] = b; submap[f] |= (unsigned char)(1u << s);
  firstmap |= (uw)1 << f;
}
static void remove_free(block *b) {
  unsigned f = (unsigned)(b->alignment_padding / SUBS);
  unsigned s = (unsigned)(b->alignment_padding % SUBS);
  block *p = free_prev(b), *n = b->pending;
  if (p) p->pending = n; else bins[f][s] = n;
  if (n) n->fields = (uw)p;
  if (!bins[f][s]) {
    submap[f] &= (unsigned char)~(1u << s);
    if (!submap[f]) firstmap &= ~((uw)1 << f);
  }
}
static void mark_live(V v, int live) {
  uw bit = (v - low) >> 4;
  unsigned char mask = (unsigned char)(1u << (bit & 7));
  if (live) live_map[bit >> 3] |= mask;
  else live_map[bit >> 3] &= (unsigned char)~mask;
}
void fpr_builtin_heap_init(void *start, void *end) {
  uw lo = (uw)start, hi = (uw)end & ~(uw)15;
  if (lo > UINTPTR_MAX - 15) fpr_cpanic("Builtin: heap too small");
  low = (lo + 15) & ~(uw)15;
  if (hi <= low) fpr_cpanic("Builtin: heap too small");
#ifdef FPR_BUILTIN_HEAP_MAX_BYTES
  if (hi - low > (uw)FPR_BUILTIN_HEAP_MAX_BYTES)
    fpr_cpanic("Builtin: configured heap exceeds maximum");
#endif
  /* One bit per 16-byte slot; rounding applies to the bitmap, not the payload. */
  uw map_bytes = ((((hi - low) >> 4) + 7) >> 3);
  map_bytes = (map_bytes + 15) & ~(uw)15;
  if (hi - low < map_bytes + PREFIX + 16) fpr_cpanic("Builtin: heap too small");
  high = hi - map_bytes; live_map = (unsigned char *)high;
  zero_words((V)live_map, map_bytes);
  for (unsigned f = 0; f < CLASS_ROWS; f++) {
    submap[f] = 0;
    for (unsigned s = 0; s < SUBS; s++) bins[f][s] = 0;
  }
  firstmap = live_count = 0;
  HEAP_STAT(statistics = (fpr_builtin_heap_stats){0});
#ifdef FPR_BUILTIN_HEAP_TEST
  fpr_builtin_heap_lookup_steps = fpr_builtin_heap_allocation_steps = 0;
#endif
  block *head = (block *)low;
  initialize_block(head, high-low, 0, 0);
  insert_free(head);
}
int fpr_in_heap(V v) { return !ISINT(v) && v >= low + PREFIX && v < high; }
static block *find(V v) {
  LOOKUP_STEP();
  if (fpr_in_heap(v) && !(v & 15)) {
    uw bit = (v - low) >> 4;
    if (live_map[bit >> 3] & (1u << (bit & 7))) {
      block *b = (block *)(v - PREFIX);
      if (b->used && b->size >= PREFIX + 16 && !(b->size & 15)
          && b->size <= high - (uw)b && meta(b)[0] == b->size - sizeof(block))
        return b;
    }
  }
  fpr_cpanic("Builtin: invalid allocation pointer");
  return 0;
}
static void split(block *b, uw size) {
  if (b->size - size < PREFIX + 16) return;
  block *n = (block *)((char *)b + size);
  initialize_block(n, b->size-size, b, b->next);
  if (n->next) n->next->prev = n;
  b->next = n; b->size = size;
  insert_free(n);
}
static block *available(uw size) {
  /* Reject impossible requests before a bounded index's row is addressed.
   * Reallocation also reaches this path before changing the original block. */
  if (size > high - low) return 0;
  unsigned f, s; size_class(size, &f, &s);
  block *same = bins[f][s];
  ALLOCATION_STEP();
  if (same && same->size >= size) return same;
  /* Every block in a higher class fits. Select it without walking allocations
   * or free blocks. Only if there is no higher class do we inspect the rest of
   * the request's own class: refusing a fitting block there would be false OOM.
   * Small objects (whole block <256 bytes) have exact 16-byte classes, so this
   * fallback is unnecessary for them. Large-class fallback is free-block-only. */
  uw subs = submap[f] & (0xffu << (s + 1));
  if (subs) return bins[f][first_bit(subs)];
  uw later = firstmap & ~(((uw)1 << (f + 1)) - 1);
  if (later) { f = first_bit(later); return bins[f][first_bit(submap[f])]; }
  for (block *b = same ? same->pending : 0; b; b = b->pending) {
    ALLOCATION_STEP();
    if (b->size >= size) return b;
  }
  return 0;
}
/* ---- regions ---------------------------------------------------------- */
typedef struct region {
  struct region *up;
  uw seq;            /* the loop activation that opened it; 0 for a call region */
  block *scratch;    /* what the current turn allocated */
  block *held;       /* the state the last reset copied out */
  block *fresh;      /* the state a reset is copying out now */
  block **target;    /* where a new block is linked: &scratch, or &fresh mid-copy */
  uw bytes;          /* bytes allocated into scratch since the last reset */
} region;
static region *cur_region HEAP_STATE;
static uw loose_bytes HEAP_STATE; /* non-bulk bytes allocated with no region open */
typedef struct { uw mark; region *in; region *opened; } pend;
static pend pend0[8] HEAP_STATE;
static pend *pends HEAP_STATE;
static uw npend HEAP_STATE, cappend HEAP_STATE;
static uw region_opens HEAP_STATE, region_reclaimed HEAP_STATE;
/* the hart's allocation clock (fpr.h region_bytes, the word a loop region's
 * back edge reads inline): the host that owns the hart block names it once
 * (machine/tangnano20k/base.c); a harness without one leaves it unset */
static uw *clock_cell HEAP_STATE;
void fpr_builtin_heap_clock(uw *cell) { clock_cell = cell; }
static uw cur_bytes(void) { return cur_region ? cur_region->bytes : loose_bytes; }
/* a call region opens once its call has allocated this much in the region it
 * started in.  On the host the trip is a slab, the price of an open; here an
 * open costs one small block (the region record) and the result's copy, so
 * the trip is small: what a call leaves in its caller before it trips is
 * garbage until the CALLER's region resets, and nested calls each leave that
 * much (dtree's 30 entropy calls inside a split search).  At 4 KiB the open
 * is under 3% of what the call allocated. */
#ifndef FPR_BUILTIN_CALL_TRIP
#define FPR_BUILTIN_CALL_TRIP ((uw)4096)
#endif
static V alloc_impl(V bytes, int bulk);
static void physical_free(block *b);
__attribute__((unused)) /* ARC builds open no regions */
static region *region_push(uw seq) {
  region *r = (region *)alloc_impl(sizeof(region), 1);
  r->up = cur_region; r->seq = seq;
  r->scratch = r->held = r->fresh = 0;
  r->target = &r->scratch; r->bytes = 0;
  cur_region = r;
  region_opens++;
  return r;
}
static void free_list(block *b) {
  while (b) {
    block *nx = b->pending; /* read first: the free may merge this header away */
    if (b->used == 2) {
      mark_live(payload(b), 0); live_count--;
      HEAP_STAT(statistics.live_bytes -= b->size);
    }
    region_reclaimed += b->size;
    physical_free(b);
    b = nx;
  }
}
static V alloc_impl(V bytes, int bulk) {
  if (bytes > UINTPTR_MAX - PREFIX - 15) fpr_cpanic("Builtin: allocation overflow");
  uw size = PREFIX + ((bytes + 15) & ~(uw)15);
  if (size == PREFIX) size += 16;
#ifdef FPR_BUILTIN_ARC
  (void)bulk; /* ARC builds open no regions: every block is untracked */
#else
  /* a pending call region whose call has used a slab here opens now */
  if (!bulk && npend) {
    pend *e = &pends[npend - 1];
    if (!e->opened && e->in == cur_region && cur_bytes() - e->mark >= FPR_BUILTIN_CALL_TRIP) e->opened = region_push(0);
  }
#endif
  block *b = available(size);
  if (!b) fpr_cpanic("Builtin: out of memory");
  remove_free(b); split(b, size); b->used = 1; b->fields = 0; b->pending = 0; b->layout = 0;
#ifndef FPR_BUILTIN_ARC
  if (!bulk) {
    if (clock_cell) *clock_cell += b->size; /* the clock a loop region's back edge reads (hart cell 58) */
    if (cur_region) {
      b->used = 2;
      b->pending = *cur_region->target;
      *cur_region->target = b;
      cur_region->bytes += b->size;
    } else loose_bytes += b->size;
  }
#endif
  b->alignment_padding = 0;
  meta(b)[0] = b->size - sizeof(block); meta(b)[1] = 1;
  mark_live(payload(b), 1); live_count++;
  HEAP_STAT(statistics.requests++; statistics.requested_bytes += bytes;
    statistics.live_bytes += b->size;
    if (statistics.live_bytes > statistics.peak_bytes) statistics.peak_bytes = statistics.live_bytes);
  V p = payload(b); zero_words(p, b->size - PREFIX);
  return p;
}
V fpr_alloc(V bytes) { return alloc_impl(bytes, 0); }
static void merge(block *b) {
  block *n = b->next;
  if (n && !n->used) {
    remove_free(n);
    b->size += n->size; b->next = n->next;
    if (b->next) b->next->prev = b;
  }
}
void fpr_free(V v) {
  if (!v) return;
  block *b = find(v);
  if (meta(b)[1] != 1) fpr_cpanic("Builtin: free of shared allocation");
  HEAP_STAT(statistics.live_bytes -= b->size);
  mark_live(v, 0); live_count--;
  if (b->used == 2) { b->used = 3; return; } /* in a region's list: its space waits for the reset */
  physical_free(b);
}
static void physical_free(block *b) {
  b->used = 0; merge(b);
  if (b->prev && !b->prev->used) {
    block *p = b->prev; remove_free(p);
    p->size += b->size; p->next = b->next;
    if (p->next) p->next->prev = p;
    b = p;
  }
  insert_free(b);
}
static V realloc_impl(V v, V bytes, int bulk) {
  if (!v) return bytes ? alloc_impl(bytes, bulk) : 0;
  block *b = find(v);
  if (meta(b)[1] != 1) fpr_cpanic("Builtin: realloc of shared allocation");
  if (!bytes) { fpr_free(v); return 0; }
  if (bytes <= b->size - PREFIX) return v;
  if (bytes > UINTPTR_MAX - PREFIX - 15) fpr_cpanic("Builtin: allocation overflow");
  uw old_capacity = b->size - PREFIX;
  uw size = PREFIX + ((bytes + 15) & ~(uw)15);
  if (b->next && !b->next->used && b->size + b->next->size >= size) {
#if defined(FPR_BUILTIN_HEAP_STATS)
    uw old_size = b->size;
#endif
    merge(b); split(b, size);
    HEAP_STAT(statistics.live_bytes += b->size - old_size;
      if (statistics.live_bytes > statistics.peak_bytes) statistics.peak_bytes = statistics.live_bytes);
    meta(b)[0] = b->size - sizeof(block);
    zero_words(v + old_capacity, b->size - PREFIX - old_capacity);
    return v;
  }
  V n = alloc_impl(bytes, bulk);
  copy_payload(n, v, b->size - PREFIX);
  block *m = find(n); m->fields = b->fields; m->layout = b->layout;
  fpr_free(v); return n;
}
V fpr_realloc(V v, V bytes) { return realloc_impl(v, bytes, 0); }
/* Explicit owning references, not automatic compiler ARC. Constructors move
 * references into fields. Retain before reusing an owning reference. Float
 * payloads, cycles and custom raw-pointer objects are outside this API.
 */
V fpr_builtin_retain(V v) {
  if (!v || ISINT(v) || !fpr_in_heap(v)) return v;
  uw *m = meta(find(v));
  if (m[1] == UINTPTR_MAX) fpr_cpanic("Builtin: reference count overflow");
  m[1]++; return v;
}
#ifndef FPR_BUILTIN_ARC
static void release_legacy(V v) {
  if (!v || ISINT(v) || !fpr_in_heap(v)) return;
  block *b = find(v); uw *m = meta(b);
  if (m[1] > 1) { m[1]--; return; }
  hdr_t *h = (hdr_t *)v;
  if (h->tid == T_VEC || h->tid == T_SSTR || h->tid == T_ACTOR || h->tid == T_PAP)
    fpr_cpanic("Builtin: unsupported Rc object");
  if (h->tid != T_STR && h->tid != T_BITS && h->tid != T_DEVICE && h->tid != T_REGISTER) {
    V *fields = (V *)(v + 8);
    for (uw i = 0; i < (m[0] - 24) / sizeof(V); i++) release_legacy(fields[i]);
  }
  fpr_free(v);
}


#endif

/* ARC constructors carry an exact field count and optional static per-field
 * representation descriptor; leaf primitives have fields=0.
 * This is an explicit layout, not inference from rounded allocation capacity.
 */
V fpr_builtin_alloc_adt(V bytes, uw fields) {
  if (bytes < 8 || fields > (bytes - 8) / sizeof(V))
    fpr_cpanic("Builtin: invalid ADT layout");
  V v = fpr_alloc(bytes); find(v)->fields = fields; return v;
}
uw fpr_builtin_live_allocations(void) {
  return live_count;
}
void fpr_builtin_heap_get_stats(fpr_builtin_heap_stats *out) {
  *out = (fpr_builtin_heap_stats){0}; HEAP_STAT(*out = statistics);
  out->regions = region_opens; out->reclaimed_bytes = region_reclaimed;
}
/* Worklist lives in dead blocks themselves. No recursive C stack, allocation
 * or fixed queue capacity is needed to release arbitrarily deep acyclic data.
 * Queued blocks stay allocated until their fields have been visited.
 */
#ifdef FPR_BUILTIN_ARC
static void enqueue(V v, block **work) {
  if (!v || ISINT(v) || !fpr_in_heap(v)) return;
  block *b = find(v); uw *m = meta(b);
  if (!m[1]) fpr_cpanic("Builtin: duplicate ownership or cycle");
  if (--m[1] == 0) { b->pending = *work; *work = b; }
}

#endif
void fpr_builtin_release(V v) {
#ifdef FPR_BUILTIN_ARC
  block *work = 0;
  enqueue(v, &work);
  while (work) {
    block *b = work; work = b->pending;
    V *fields = (V *)(payload(b) + 8);
    for (uw i = 0; i < b->fields; i++)
      if (!b->layout || b->layout->bytes[i]=='t') enqueue(fields[i], &work);
    meta(b)[1] = 1; /* low-level free requires exclusive ownership */
    fpr_free(payload(b));
  }
#else
  release_legacy(v);
#endif
}

void fpr_builtin_set_layout(V v,V descriptor) {
  block *b=find(v); const str_t *s=(const str_t *)descriptor;
  if(s->tid!=T_STR || s->len!=b->fields) fpr_cpanic("Builtin: invalid field descriptor");
  b->layout=s;
}
uw fpr_builtin_field_count(V v) { return find(v)->fields; }
char fpr_builtin_field_kind(V v,uw i) {
  block *b=find(v);
  if(i>=b->fields) fpr_cpanic("Builtin: field index out of range");
  return b->layout ? b->layout->bytes[i] : 't';
}
/* bulk storage (a Vector's pieces) is never in a region: it outlives every
 * reset, and its one owner frees it */
V fpr_alloc_bulk(V bytes) { return alloc_impl(bytes, 1); }
V fpr_realloc_bulk(V v, V bytes) { return realloc_impl(v, bytes, 1); }

/* the region operations runtime.c's compiler-region primitives drive */
int fpr_builtin_untracked(V v) { return find(v)->used == 1; }
uw fpr_builtin_region_bytes(void) { return cur_bytes(); }
uw fpr_builtin_region_seq(void) { return cur_region ? cur_region->seq : 0; }
int fpr_builtin_region_open(uw seq) {
#ifdef FPR_BUILTIN_ARC
  (void)seq; return 0;
#else
  region_push(seq); return 1;
#endif
}
/* a reset: the copy of the state the caller is about to make lands in a
 * fresh list; then the turn's scratch and the previous state are freed */
void fpr_builtin_region_cycle_begin(void) { cur_region->fresh = 0; cur_region->target = &cur_region->fresh; }
void fpr_builtin_region_cycle_end(void) {
  region *r = cur_region;
  free_list(r->scratch); free_list(r->held);
  r->held = r->fresh; r->fresh = 0; r->scratch = 0;
  r->target = &r->scratch; r->bytes = 0;
}
/* a close: the caller copies its result into the enclosing region between
 * begin and end; end frees what the closing region still holds */
void *fpr_builtin_region_close_begin(void) { region *r = cur_region; cur_region = r->up; return r; }
void fpr_builtin_region_close_end(void *token) {
  region *r = (region *)token;
  free_list(r->scratch); free_list(r->held);
  fpr_free((V)r);
}
uw fpr_builtin_region_scratch(void *token) { return ((region *)token)->bytes; }
static void adopt_list(block *b) {
  while (b) {
    block *nx = b->pending; /* read first: a free may merge this header away */
    if (b->used == 3) { region_reclaimed += b->size; physical_free(b); }
    else if (cur_region) {
      b->pending = *cur_region->target; *cur_region->target = b;
      cur_region->bytes += b->size;
    } else { b->used = 1; b->pending = 0; loose_bytes += b->size; }
    b = nx;
  }
}
void fpr_builtin_region_adopt(void *token) {
  region *r = (region *)token;
  adopt_list(r->scratch); adopt_list(r->held);
  fpr_free((V)r);
}
uw fpr_builtin_pend(void) {
  if (!pends) { pends = pend0; cappend = 8; }
  if (npend == cappend) { /* doubling, never a cap: deep call nesting just costs memory */
    pend *nv = (pend *)alloc_impl(2 * cappend * sizeof(pend), 1);
    for (uw i = 0; i < npend; i++) nv[i] = pends[i];
    if (pends != pend0) fpr_free((V)pends);
    pends = nv; cappend *= 2;
  }
  pend *e = &pends[npend++];
  e->mark = cur_bytes(); e->in = cur_region; e->opened = 0;
  return npend - 1;
}
void *fpr_builtin_pend_pop(uw tok) {
  if (!npend || npend - 1 != tok) fpr_cpanic("call region: left out of order");
  pend e = pends[--npend];
  if (e.opened && e.opened != cur_region) fpr_cpanic("call region: a nested region is still open");
  return e.opened;
}
void fpr_builtin_region_counts(uw *opens, uw *reclaimed) { *opens = region_opens; *reclaimed = region_reclaimed; }
