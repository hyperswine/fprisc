/* Single-threaded, coalescing first-fit heap. No scheduler or OS dependency.
 * The 16 bytes immediately before every payload remain compatible with the
 * shared runtime's object-size ABI; the second word holds a reference count.
 */
#include "builtin.h"
#include <stdint.h>
typedef struct block { uw size; struct block *prev, *next; uw used; uw fields; struct block *pending; const str_t *layout; uw alignment_padding; } block;
_Static_assert((sizeof(block)+16)%16 == 0, "Builtin payload alignment");
_Static_assert(sizeof(uw) == 8, "Builtin heap currently requires 64-bit words");
static block *head;
static uw low, high;
#define PREFIX (sizeof(block) + 16)
static uw *meta(block *b) { return (uw *)((char *)b + sizeof(block)); }
static V payload(block *b) { return (V)((char *)b + PREFIX); }
void fpr_builtin_heap_init(void *start, void *end) {
  low = ((uw)start + 15) & ~(uw)15;
  high = (uw)end & ~(uw)15;
  if (high <= low || high - low < PREFIX + 16) fpr_cpanic("Builtin: heap too small");
  head = (block *)low;
  *head = (block){.size=high-low};
}
int fpr_in_heap(V v) { return !ISINT(v) && v >= low + PREFIX && v < high; }
static block *find(V v) {
  for (block *b = head; b; b = b->next)
    if (payload(b) == v && b->used) return b;
  fpr_cpanic("Builtin: invalid allocation pointer");
  return 0;
}
static void split(block *b, uw size) {
  if (b->size - size < PREFIX + 16) return;
  block *n = (block *)((char *)b + size);
  *n = (block){.size=b->size-size,.prev=b,.next=b->next};
  if (n->next) n->next->prev = n;
  b->next = n; b->size = size;
}
V fpr_alloc(V bytes) {
  if (bytes > UINTPTR_MAX - PREFIX - 15) fpr_cpanic("Builtin: allocation overflow");
  uw size = PREFIX + ((bytes + 15) & ~(uw)15);
  if (size == PREFIX) size += 16;
  for (block *b = head; b; b = b->next) if (!b->used && b->size >= size) {
    split(b, size); b->used = 1; b->fields = 0; b->pending = 0; b->layout = 0;
    meta(b)[0] = b->size - sizeof(block); meta(b)[1] = 1;
    unsigned char *p = (unsigned char *)payload(b);
    for (uw i = 0; i < b->size - PREFIX; i++) p[i] = 0;
    return (V)p;
  }
  fpr_cpanic("Builtin: out of memory"); return 0;
}
static void merge(block *b) {
  block *n = b->next;
  if (n && !n->used) {
    b->size += n->size; b->next = n->next;
    if (b->next) b->next->prev = b;
  }
}
void fpr_free(V v) {
  if (!v) return;
  block *b = find(v);
  if (meta(b)[1] != 1) fpr_cpanic("Builtin: free of shared allocation");
  b->used = 0; merge(b);
  if (b->prev && !b->prev->used) merge(b->prev);
}
V fpr_realloc(V v, V bytes) {
  if (!v) return bytes ? fpr_alloc(bytes) : 0;
  block *b = find(v);
  if (meta(b)[1] != 1) fpr_cpanic("Builtin: realloc of shared allocation");
  if (!bytes) { fpr_free(v); return 0; }
  if (bytes <= b->size - PREFIX) return v;
  V n = fpr_alloc(bytes);
  for (uw i = 0; i < b->size - PREFIX; i++) ((char *)n)[i] = ((char *)v)[i];
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
  uw n = 0;
  for (block *b = head; b; b = b->next) if (b->used) n++;
  return n;
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
