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
#if defined(FPR_BUILTIN_GC) && defined(__riscv)
/* Private allocator pointers (bounds/free lists) are not application roots. */
#define HEAP_STATE __attribute__((section(".bss.fpr_heap")))
#else
#define HEAP_STATE
#endif
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
#if defined(FPR_BUILTIN_HEAP_STATS) || defined(FPR_BUILTIN_GC)
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
V fpr_alloc(V bytes) {
  if (bytes > UINTPTR_MAX - PREFIX - 15) fpr_cpanic("Builtin: allocation overflow");
  uw size = PREFIX + ((bytes + 15) & ~(uw)15);
  if (size == PREFIX) size += 16;
#if defined(FPR_BUILTIN_GC) && defined(FPR_BUILTIN_GC_STRESS)
  if (statistics.requests % FPR_BUILTIN_GC_STRESS == 0) fpr_builtin_gc_collect();
#endif
  block *b = available(size);
#ifdef FPR_BUILTIN_GC
  if (!b && size <= high - low) { fpr_builtin_gc_collect(); b = available(size); }
#endif
  if (!b) fpr_cpanic("Builtin: out of memory");
  remove_free(b); split(b, size); b->used = 1; b->fields = 0; b->pending = 0; b->layout = 0;
  b->alignment_padding = 0;
  meta(b)[0] = b->size - sizeof(block); meta(b)[1] = 1;
  mark_live(payload(b), 1); live_count++;
  HEAP_STAT(statistics.requests++; statistics.requested_bytes += bytes;
    statistics.live_bytes += b->size;
    if (statistics.live_bytes > statistics.peak_bytes) statistics.peak_bytes = statistics.live_bytes);
  V p = payload(b); zero_words(p, b->size - PREFIX);
  return p;
}
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
  mark_live(v, 0); live_count--; b->used = 0; merge(b);
  if (b->prev && !b->prev->used) {
    block *p = b->prev; remove_free(p);
    p->size += b->size; p->next = b->next;
    if (p->next) p->next->prev = p;
    b = p;
  }
  insert_free(b);
}
V fpr_realloc(V v, V bytes) {
  if (!v) return bytes ? fpr_alloc(bytes) : 0;
  block *b = find(v);
  if (meta(b)[1] != 1) fpr_cpanic("Builtin: realloc of shared allocation");
  if (!bytes) { fpr_free(v); return 0; }
  if (bytes <= b->size - PREFIX) return v;
  if (bytes > UINTPTR_MAX - PREFIX - 15) fpr_cpanic("Builtin: allocation overflow");
  uw old_capacity = b->size - PREFIX;
  uw size = PREFIX + ((bytes + 15) & ~(uw)15);
  if (b->next && !b->next->used && b->size + b->next->size >= size) {
#if defined(FPR_BUILTIN_HEAP_STATS) || defined(FPR_BUILTIN_GC)
    uw old_size = b->size;
#endif
    merge(b); split(b, size);
    HEAP_STAT(statistics.live_bytes += b->size - old_size;
      if (statistics.live_bytes > statistics.peak_bytes) statistics.peak_bytes = statistics.live_bytes);
    meta(b)[0] = b->size - sizeof(block);
    zero_words(v + old_capacity, b->size - PREFIX - old_capacity);
    return v;
  }
  V n = fpr_alloc(bytes);
  copy_payload(n, v, b->size - PREFIX);
  block *m = find(n); m->fields = b->fields; m->layout = b->layout;
  fpr_free(v); return n;
}
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
}
#ifdef FPR_BUILTIN_GC
#ifdef FPR_BUILTIN_ARC
#error "Conservative collection and compiler ARC are separate ownership modes"
#endif
static block *gc_work HEAP_STATE;
static int gc_active HEAP_STATE;
/* Locate the preceding live payload through the bitmap, never through an
 * untrusted candidate's apparent header. A stale/interior integer is harmless.
 * Unlike find(), this deliberately accepts byte-interior payload pointers. */
static block *gc_owner(uw v) {
  if (v < low || v > high) return 0;
  if (v < low + PREFIX) return 0;
  uw bit = ((v == high ? v-1 : v)-low) >> 4, index = bit / WORD_BITS;
  uw bits = ((const heap_word *)live_map)[index] & (~(uw)0 >> (WORD_BITS-1-bit%WORD_BITS));
  while (!bits && index) bits = ((const heap_word *)live_map)[--index];
  if (!bits) return 0;
  uw start = low + ((index*WORD_BITS + log2_word(bits)) << 4);
  block *b = (block *)(start-PREFIX);
  return v-start <= b->size-PREFIX ? b : 0; /* include a one-past-end iterator */
}
static void gc_enqueue(block *b) {
  if (b && b->used == 1) { b->used = 2; b->pending = gc_work; gc_work = b; }
}
static void gc_mark(uw v, int allocator_headers) {
  if (allocator_headers && v >= low && v < high) {
    /* C may keep only an address of a metadata field across fpr_alloc.
     * Authenticate the following payload, at most PREFIX bytes away. */
    for (uw p=(v+15)&~(uw)15; p<high && p-v<=PREFIX; p+=16) {
      uw bit=(p-low)>>4;
      if (live_map[bit>>3] & (1u<<(bit&7))) gc_enqueue((block *)(p-PREFIX));
    }
  }
  /* A block header can ALSO be the preceding allocation's one-past-end
   * pointer. Preserve both interpretations rather than choosing one. */
  gc_enqueue(gc_owner(v));
}
void fpr_builtin_gc_begin(void) {
  if (gc_active) fpr_cpanic("Builtin: reentrant collection");
  gc_active = 1; gc_work = 0; statistics.collections++;
}
void fpr_builtin_gc_roots(const uw *begin, const uw *end, int allocator_headers) {
  if (!gc_active || ((uw)begin % sizeof(uw)) || ((uw)end % sizeof(uw)) || (uw)end < (uw)begin)
    fpr_cpanic("Builtin: invalid GC roots");
  for (uw p = (uw)begin; p < (uw)end; p += sizeof(uw)) gc_mark(*(const heap_word *)p, allocator_headers);
}
void fpr_builtin_gc_end(void) {
  if (!gc_active) fpr_cpanic("Builtin: collection not started");
  while (gc_work) {
    block *b = gc_work; gc_work = b->pending; b->pending = 0;
    gc_mark((uw)b->layout, 0);
    fpr_builtin_gc_roots((const uw *)payload(b), (const uw *)((uw)b+b->size), 0);
  }
  /* Sweep without recursive releases: cycles are reclaimed together. Rebuild
   * free indices after marking so coalescing cannot invalidate the traversal. */
  for (block *b = (block *)low; b; b = b->next) {
    if (b->used == 2) b->used = 1;
    else if (b->used) {
      mark_live(payload(b), 0); live_count--; b->used = 0;
      statistics.live_bytes -= b->size; statistics.reclaimed_bytes += b->size;
    }
  }
  firstmap = 0;
  for (unsigned f=0; f<CLASS_ROWS; f++) {
    submap[f]=0; for (unsigned s=0;s<SUBS;s++) bins[f][s]=0;
  }
  for (block *b = (block *)low; b; b = b->next) if (!b->used) {
    while (b->next && !b->next->used) {
      block *n=b->next; b->size+=n->size; b->next=n->next;
      if (b->next) b->next->prev=b;
    }
    insert_free(b);
  }
  gc_active = 0;
}
#endif
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
