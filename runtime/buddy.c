/* buddy.c -- a textbook power-of-two buddy allocator over a reserved
 * arena (docs/PROCESS-LOADING.md). Owned by System.qa: hands out the
 * initial code+heap slot for a freshly loaded process, and additional
 * blocks later when that process asks for more memory.
 *
 * Block layout: each returned pointer is preceded by one word (the
 * order it was allocated at), so free() doesn't need the caller to
 * remember the size -- callers still pass a size to buddy_alloc (they
 * know what they need), but never to buddy_free.
 *
 *   [ order:uw ][ ...block... ]
 *   ^header      ^returned pointer
 *
 * Free lists are singly-linked through the first word of each free
 * block's PAYLOAD (blocks are always >= BUDDY_MIN_BLOCK >= sizeof(uw),
 * so this never overruns). One spinlock: this is System.qa's own
 * allocator, called rarely (process load/unload, memory-growth
 * requests) next to actual computation, so a single lock is fine --
 * same reasoning as the ARC table lock in runtime.c.
 */
#include "fpr.h"

static void buddy_free_locked(void *p); /* the coalescing free, under buddy_lock */

#ifndef BUDDY_MIN_BLOCK
#ifdef FPR_BUDDY_MIN
#define BUDDY_MIN_BLOCK ((uw)FPR_BUDDY_MIN)
#else
#define BUDDY_MIN_BLOCK ((uw)64 * 1024)
#endif
#endif /* order 0 */
#define BUDDY_MAX_ORDER 24               /* generous ceiling; real order set by init */

typedef struct free_node { struct free_node *next; } free_node_t;

static char *arena_base;
static uw arena_size;
static int max_order;
static free_node_t *free_lists[BUDDY_MAX_ORDER + 1];
static fpr_lock_t buddy_lock;

static int order_of(uw bytes) {
  uw need = bytes + sizeof(uw); /* header */
  uw block = BUDDY_MIN_BLOCK;
  int order = 0;
  while (block < need) { block <<= 1; order++; }
  return order;
}

static uw block_size(int order) { return BUDDY_MIN_BLOCK << order; }

static uw offset_of(void *p) { return (uw)((char *)p - arena_base); }

void buddy_init(void *base, uw size) {
  arena_base = (char *)base;
  arena_size = size & ~(BUDDY_MIN_BLOCK - 1);
  for (int i = 0; i <= BUDDY_MAX_ORDER; i++) free_lists[i] = 0;
  max_order = 0;
  /* seed the WHOLE span as a greedy power-of-two decomposition, each
   * block naturally aligned at its offset (96 MiB = 64 MiB + 32 MiB).
   * The old round-down-to-one-power-of-two silently dropped the tail
   * -- which under the unified span was the entire process region.
   * Cross-block coalescing can't happen (a block's buddy at the seam
   * is never on a free list), which is exactly right: these are
   * independent roots. */
  uw off = 0;
  while (arena_size - off >= BUDDY_MIN_BLOCK) {
    uw rem = arena_size - off;
    int order = 0;
    while (block_size(order + 1) <= rem &&
           (off & (block_size(order + 1) - 1)) == 0 &&
           order + 1 <= BUDDY_MAX_ORDER)
      order++;
    free_node_t *b = (free_node_t *)(arena_base + off);
    b->next = free_lists[order];
    free_lists[order] = b;
    if (order > max_order) max_order = order;
    off += block_size(order);
  }
}

/* split a free block at `order` down to `want`, threading the buddy
 * halves onto the intermediate free lists as we go */
static void *split_down(int order, int want) {
  free_node_t *blk = free_lists[order];
  free_lists[order] = blk->next;
  while (order > want) {
    order--;
    free_node_t *buddy = (free_node_t *)((char *)blk + block_size(order));
    buddy->next = free_lists[order];
    free_lists[order] = buddy;
  }
  return blk;
}

/* returns NULL on exhaustion -- a real, user-visible condition, not
 * papered over. bytes is the USABLE size the caller wants (excludes
 * the header; buddy_alloc accounts for it). */
void *buddy_alloc(uw bytes) {
  int want = order_of(bytes);
  if (want > max_order) return 0;
  fpr_lock(&buddy_lock);
  int order = want;
  while (order <= max_order && !free_lists[order]) order++;
  if (order > max_order) {
    fpr_unlock(&buddy_lock);
    return 0; /* exhausted at this size class */
  }
  void *blk = split_down(order, want);
  fpr_unlock(&buddy_lock);
  *(uw *)blk = (uw)want;
  return (char *)blk + sizeof(uw);
}

/* ---- address-targeted reservation (the slab refactor's slot fix) ----
 * Process images are statically linked at _proc_arena_start, but buddy
 * now spans heap+proc as ONE region and ordinary allocations land
 * wherever.  These reserve/release the EXACT range a linked image
 * needs, by splitting free blocks TOWARD each 64 KiB unit of the range
 * (split_down's low-half bias keeps this region free in practice).
 * Returns addr, or NULL if any unit is already taken -- a loud, clean
 * load failure, not a corruption. */
static int take_unit(char *unit) {
  for (int order = 0; order <= max_order; order++) {
    free_node_t **pp = &free_lists[order];
    for (free_node_t *b = *pp; b; pp = &b->next, b = b->next) {
      char *lo = (char *)b, *hi = lo + block_size(order);
      if (unit < lo || unit >= hi) continue;
      *pp = b->next; /* unlink the containing block */
      while (order > 0) { /* split toward the unit, freeing the far half */
        order--;
        char *mid = lo + block_size(order);
        if (unit < mid) {
          free_node_t *far = (free_node_t *)mid;
          far->next = free_lists[order];
          free_lists[order] = far;
        } else {
          free_node_t *far = (free_node_t *)lo;
          far->next = free_lists[order];
          free_lists[order] = far;
          lo = mid;
        }
      }
      return 1;
    }
  }
  return 0;
}

void *buddy_reserve_range(void *addr, uw bytes) {
  uw units = (bytes + BUDDY_MIN_BLOCK - 1) / BUDDY_MIN_BLOCK;
  fpr_lock(&buddy_lock);
  for (uw i = 0; i < units; i++) {
    if (!take_unit((char *)addr + i * BUDDY_MIN_BLOCK)) {
      fpr_unlock(&buddy_lock);
      return 0; /* range occupied (earlier units stay reserved: loud config error) */
    }
  }
  fpr_unlock(&buddy_lock);
  return addr;
}

void buddy_release_range(void *addr, uw bytes) {
  uw units = (bytes + BUDDY_MIN_BLOCK - 1) / BUDDY_MIN_BLOCK;
  for (uw i = 0; i < units; i++) {
    char *u = (char *)addr + i * BUDDY_MIN_BLOCK;
    *(uw *)u = 0; /* re-stamp the order-0 header the image overwrote */
    buddy_free(u + sizeof(uw)); /* coalescing rebuilds the big blocks */
  }
}

void buddy_free(void *p) {
  if (!p) return;
  fpr_lock(&buddy_lock);
  buddy_free_locked(p);
  fpr_unlock(&buddy_lock);
}
static void buddy_free_locked(void *p) { /* under buddy_lock */
  char *hdr = (char *)p - sizeof(uw);
  int order = (int)*(uw *)hdr;
  uw off = offset_of(hdr);
  while (order < max_order) {
    uw buddy_off = off ^ block_size(order);
    free_node_t *buddy = (free_node_t *)(arena_base + buddy_off);
    /* is `buddy` currently free at exactly this order? scan is O(n) on
     * that order's list, which stays short in practice (few
     * concurrently-live process slots) -- acceptable for an allocator
     * called at load/unload/growth cadence, not per-object cadence */
    free_node_t **pp = &free_lists[order];
    int found = 0;
    while (*pp) {
      if ((char *)*pp == (char *)buddy) { *pp = (*pp)->next; found = 1; break; }
      pp = &(*pp)->next;
    }
    if (!found) break; /* buddy not free (or not same order): stop coalescing */
    off = off & ~block_size(order); /* off of the merged (lower) block */
    order++;
  }
  free_node_t *merged = (free_node_t *)(arena_base + off);
  merged->next = free_lists[order];
  free_lists[order] = merged;
}

/* grow or shrink a buddy block, IN PLACE whenever the structure
 * allows -- the missing third op of the alloc/realloc/dealloc contract
 * (docs/MEMORY.md).  A power-of-two buddy is the best possible
 * substrate for realloc-by-doubling (contiguous Vec columns lean on
 * exactly this):
 *
 *   shrink: always in place -- split off the upper halves back onto
 *           their free lists (the block is naturally aligned, so every
 *           upper half IS a valid buddy at its order).
 *   grow:   in place while this block is the LOW half of its parent
 *           and the buddy above is free at exactly this order -- absorb
 *           it and double.  The seam rule from buddy_init holds
 *           unchanged: a seeded root's buddy is never on a free list,
 *           so growth can never merge across independent roots.
 *   else:   alloc+copy+free.  NULL on exhaustion with the ORIGINAL
 *           BLOCK INTACT (partial in-place growth is kept -- the
 *           header records it, so a later free releases all of it).
 */
void *buddy_realloc(void *p, uw bytes) {
  if (!p) return buddy_alloc(bytes);
  char *hdr = (char *)p - sizeof(uw);
  int have = (int)*(uw *)hdr;
  int want = order_of(bytes);
  if (want == have) return p;
  if (want > max_order) return 0;
  fpr_lock(&buddy_lock);
  if (want < have) { /* shrink: free the upper halves, largest first */
    while (have > want) {
      have--;
      free_node_t *upper = (free_node_t *)(hdr + block_size(have));
      upper->next = free_lists[have];
      free_lists[have] = upper;
    }
    fpr_unlock(&buddy_lock);
    *(uw *)hdr = (uw)want;
    return p;
  }
  /* grow: absorb the free buddy above while we are the low half */
  uw off = offset_of(hdr);
  int order = have;
  while (order < want) {
    if (off & block_size(order)) break; /* high half: cannot extend up */
    char *buddy = arena_base + off + block_size(order);
    free_node_t **pp = &free_lists[order];
    int found = 0;
    while (*pp) {
      if ((char *)*pp == buddy) { *pp = (*pp)->next; found = 1; break; }
      pp = &(*pp)->next;
    }
    if (!found) break; /* buddy live or split: stop */
    order++;
  }
  fpr_unlock(&buddy_lock);
  *(uw *)hdr = (uw)order; /* record any partial growth for free() */
  if (order == want) return p;
  void *n = buddy_alloc(bytes);
  if (!n) return 0; /* exhausted; original (possibly grown) intact */
  uw old_usable = block_size(have) - sizeof(uw);
  __builtin_memcpy(n, p, old_usable < bytes ? old_usable : bytes);
  buddy_free(p);
  return n;
}

/* the usable size of a block returned by buddy_alloc (its header's
 * order, minus the header itself) -- lets a caller that requested N
 * bytes discover it actually got block_size(order)-sizeof(uw), often
 * more, without needing to remember what it asked for. */
uw buddy_block_usable_size(void *p) {
  char *hdr = (char *)p - sizeof(uw);
  int order = (int)*(uw *)hdr;
  return block_size(order) - sizeof(uw);
}

/* ---- the uncontended fast path (the memory actor's inline service) --
 * A requester that finds the lock FREE serves itself on the spot; one
 * that finds it held queues on the memory actor instead (fpr.h,
 * fpr_mem_take).  A round trip through one actor on one hart costs
 * more than the allocation itself -- and stalls whenever that hart is
 * inside a long C section (a big deep copy) -- so the actor is the
 * serialisation point for CONTENTION, not the path every block takes.
 * *busy = 1 means "the lock was held: nothing was tried". */
static int buddy_trylock(void) {
  uw exp = 0;
  return __atomic_compare_exchange_n(&buddy_lock.v, &exp, 1, 0, __ATOMIC_ACQUIRE,
                                     __ATOMIC_RELAXED);
}
void *buddy_alloc_try(uw bytes, int *busy) {
  int want = order_of(bytes);
  *busy = 0;
  if (want > max_order) return 0;
  if (!buddy_trylock()) { *busy = 1; return 0; }
  int order = want;
  while (order <= max_order && !free_lists[order]) order++;
  if (order > max_order) {
    fpr_unlock(&buddy_lock);
    return 0;
  }
  void *blk = split_down(order, want);
  fpr_unlock(&buddy_lock);
  *(uw *)blk = (uw)want;
  return (char *)blk + sizeof(uw);
}
/* the same for a free: 1 done, 0 the lock was held (queue it) */
int buddy_free_try(void *p) {
  if (!p) return 1;
  if (!buddy_trylock()) return 0;
  buddy_free_locked(p);
  fpr_unlock(&buddy_lock);
  return 1;
}

/* introspection for /proc-style reporting and tests */
uw buddy_arena_size(void) { return arena_size; }
uw buddy_free_bytes(void) {
  uw t = 0;
  fpr_lock(&buddy_lock);
  for (int o = 0; o <= max_order; o++) {
    uw n = 0;
    for (free_node_t *b = free_lists[o]; b; b = b->next) n++;
    t += n * block_size(o);
  }
  fpr_unlock(&buddy_lock);
  return t;
}
