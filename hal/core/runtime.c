/* runtime.c — allocator, generic apply, core prims, panic.
 *
 * The core prims here are exactly the names the DESUGARER can emit
 * (operators, str/strcat from interpolation, error). Everything else a
 * program references is deliberately NOT here: it arrives as a fpr_g_*
 * extern that hal.c (or any other module) satisfies at link time.
 */
#include "fpr.h"
#include "vec_layout.h" /* the deep copier lays vectors into slabs */
#ifdef FPR_QOSAPP
#include "qos_abi.h"
#endif

const hdr_t fpr_true = {T_BOOL, 1};
const hdr_t fpr_false = {T_BOOL, 0};
const hdr_t fpr_unit = {T_UNIT, 0};

/* ---- allocator v2: bump + size header + segregated free list ---------
 * Every allocation carries its total size in a hidden 16-byte header
 * (16 to preserve alignment), which is what makes fpr_free -- and
 * therefore ARC reclamation -- possible at all. Freed blocks go into
 * exact-fit free lists by size class (16-byte steps up to the bucket
 * ceiling); blocks ABOVE the ceiling recycle through the pool's
 * exact-fit bigfree LIFO (the "larger blocks leak by design" PoC rule
 * is retired -- Vec.free of a big column block comes back).  Actor
 * stacks were never the leak: they ride the stack pool. */
extern char _heap_start[], _heap_end[];

/* per-hart control blocks; tp points at ours (see fpr.h essay) */
fpr_hart_t fpr_harts[FPR_NHARTS];
uw fpr_live_harts = FPR_NHARTS; /* hosted boots may lower this (fpr.h) */

/* process-loading growth hook; NULL for a normal machine boot */
fpr_grant_t (*fpr_grow_memory)(uw want_bytes) = 0;

/* the SMP release flag secondaries spin on.  Lives in .data (explicit
 * section + volatile) so it is 0 straight from the ELF image -- a
 * secondary that reaches its spin loop before hart 0 clears bss reads
 * a real 0, not garbage. */
#ifdef __APPLE__
__attribute__((section("__DATA,__data"))) volatile uint32_t fpr_smp_go = 0;
#else
__attribute__((section(".data"))) volatile uint32_t fpr_smp_go = 0;
#endif

void fpr_actors_init(void);       /* actors.c: global (hart 0, pre-release) */
void fpr_hart_main(int id);       /* actors.c: the hart loop */
void fpr_hart_secondary(int id);  /* actors.c: tp setup + hart loop */

/* emitted by fprc only under --rvv (sets mstatus.VS).  Weak no-op
 * default here so images built without --rvv link and never touch the
 * CSR: a --rvv unit's own (strong) definition from the generated
 * assembly overrides this one via ordinary weak/strong symbol
 * coalescing (true on both ELF and Mach-O; plain `extern ... weak`
 * with NO definition anywhere is what Apple's ld refuses to leave
 * unresolved). mstatus is PER-HART: every hart's init calls it. */
__attribute__((weak)) void fpr_rvv_enable(void) {}

/* the hart pools live forever: static bucket arrays, no recycler */
static void *hart_bkts[FPR_NHARTS][FPR_NBUCKETS];

static void hart_init(int id) {
  fpr_hart_t *h = &fpr_harts[id];
  h->id = (uw)id;
  fpr_pool_init(&h->pool, hart_bkts[id]);
  for (int i = 0; i < FPR_NBUCKETS; i++) h->pool.buckets[i] = 0;
  h->current = 0;
  h->rq_head = h->rq_tail = 0;
  h->idle = 0;
  h->fuel_preempts = 0;
  h->rpos = 0;
}

#ifdef FPR_POSIX
#if defined(FPR_QOSAPP) && !defined(FPR_QOSAPP_SINGLE) && defined(__aarch64__)
/* v3: x28 is the hart register.  Clang wraps a global-
 * register-variable WRITE in a callee-save spill/reload (verified:
 * str x28 / mov x28, x0 / ldr x28 -- the write annihilated on
 * return); gcc compiles it correctly, but the Mac toolchain is clang.
 * Writes therefore bypass the register variable with an untracked
 * inline-asm mov, which clang has no license to save around.  Reads
 * stay on the register variable -- those compile correctly. */
void fpr_set_tp(fpr_hart_t *h) { __asm__ volatile("mov x28, %0" ::"r"(h)); }
#else
void fpr_set_tp(fpr_hart_t *h) { fpr_posix_hart = h; }
#endif
#else
void fpr_set_tp(fpr_hart_t *h) { __asm__ volatile("mv tp, %0" ::"r"(h)); }
#endif

void fpr_rt_init(void) {
  for (int i = 0; i < FPR_NHARTS; i++) hart_init(i);
  /* buddy over heap + process regions TOGETHER: the ONE lower
   * allocator (per-actor slabs, stacks, acbs, and process slots all
   * come from here).  Init before actors: actor 0's stack is a buddy
   * block.  Skipped when running AS a loaded process -- a process's
   * heap is the grant its loader handed it, not this machine's RAM. */
  if (!fpr_is_process) {
    /* buddy over the heap region: slabs, stacks, acbs, growth grants.
     * The process SLOT is not allocated at all -- images are LINKED at
     * _proc_arena_start, so that fixed range is the slot by identity
     * (one concurrent slot, per the stated design). */
#ifdef FPR_BUDDY_MIN
    uw minb = (uw)FPR_BUDDY_MIN;
#else
    uw minb = 64u * 1024;
#endif
    uw base = ((uw)_heap_start + (minb - 1)) & ~(uw)(minb - 1);
    buddy_init((void *)base, (uw)_heap_end - base);
    fpr_mem_own = 1; /* this image runs the buddy: the memory actor follows */
  }
  fpr_set_tp(&fpr_harts[0]);
  fpr_rvv_enable();
  fpr_actors_init();
  /* everything above happens-before any secondary's first instruction */
  __atomic_store_n(&fpr_smp_go, 1, __ATOMIC_RELEASE);
}

char *fpr_static_lo, *fpr_static_hi; /* image-statics window (fpr.h) */

#ifndef FPR_BUILTIN
int fpr_in_heap(V v) { /* the buddy span: heap + process regions */
  /* a loaded process's IMAGE lives inside the span (the fixed slot)
   * but its cells are statics without alloc preheaders -- exclude the
   * window before either span test below can claim them */
  if (!ISINT(v) && (char *)v >= fpr_static_lo && (char *)v < fpr_static_hi)
    return 0;
#ifdef FPR_QOSAPP
  /* the PLUGIN slot sits inside the arena span but holds IMAGE data
   * (a loaded library's code + rodata literals) -- immortal, never
   * slab-backed; ARC must treat its values like the shell's own
   * static literals (qos_abi.h) */
  if ((uw)v >= QOS_PLUG_BASE && (uw)v < QOS_PLUG_BASE + QOS_PLUG_SIZE)
    return 0;
#endif
  if (fpr_sched) /* shared plane: the KERNEL's span is the heap */
    return !ISINT(v) && (char *)v >= fpr_sched->heap_lo && (char *)v < fpr_sched->heap_hi;
  return !ISINT(v) && (char *)v >= _heap_start && (char *)v < _proc_arena_end;
}

#endif

/* ---- the slab allocator (see the fpr.h essay) ----------------------- */
#ifndef FPR_SLAB_SZ
#define FPR_SLAB_SZ ((uw)256 * 1024)
#endif
#define SLAB_SZ FPR_SLAB_SZ

static fpr_pool_t *cur_pool(fpr_hart_t *h) {
  if (h->pool_override) return (fpr_pool_t *)h->pool_override;
  return h->current ? fpr_acb_pool(h->current) : &h->pool;
}

/* pop from this pool's bucket: the bucket head is CAS-pushed by any
 * hart (cross-actor drop-to-zero), so the owner drains by atomic
 * exchange -- ABA-free, and everything taken is exclusively ours. */
static void *bucket_take(fpr_pool_t *pool, uw idx) {
  if (!pool->buckets) return 0;
  void *head = __atomic_exchange_n(&pool->buckets[idx], (void *)0, __ATOMIC_ACQUIRE);
  if (!head) return 0;
  void *rest = *(void **)head;
  /* re-push the remainder (we own it; pushers only touch the head) */
  while (rest) {
    void *nx = *(void **)rest;
    void *old;
    do {
      old = __atomic_load_n(&pool->buckets[idx], __ATOMIC_RELAXED);
      *(void **)rest = old;
    } while (!__atomic_compare_exchange_n(&pool->buckets[idx], &old, rest, 0,
                                          __ATOMIC_RELEASE, __ATOMIC_RELAXED));
    rest = nx;
  }
  return head;
}

/* ---- process-mode slab recycling -----------------------------------
 * The host never takes grants back (wholesale-at-exit is the loader
 * contract), but the PROCESS can certainly reuse them: a dead actor's
 * escape-free slabs go on this list and the next slab request shops
 * here before asking the loader to grow.  Without it, any
 * actor-per-unit-of-work design leaks its whole footprint per unit --
 * found the hard way when pshell's frame-per-actor renderer exhausted
 * a 256 MiB arena in fourteen seconds of idle shell on a Pi 4.
 * Own lock, taken while arc_lock may be held (never the reverse). */
static fpr_freelist_t grant_fl; /* released grants, variable-size */
static fpr_lock_t arc_lock; /* declared early: the deep-copy transfer,
                             * arena teardown, and ARC paths all take it */

/* the one freelist discipline (fpr.h) -- every recycler below and in
 * actors.c is an instance of these two functions plus local policy */
void *fpr_fl_take(fpr_freelist_t *fl, uw want) {
  fpr_lock(&fl->mu);
  fpr_flnode_t **pp = &fl->head, *n = fl->head;
  while (n) {
    if (n->cap >= want) { *pp = n->next; break; }
    pp = &n->next;
    n = n->next;
  }
  fpr_unlock(&fl->mu);
  return n;
}
void fpr_fl_put(fpr_freelist_t *fl, void *p, uw cap) {
  fpr_flnode_t *n = (fpr_flnode_t *)p;
  n->cap = cap;
  fpr_lock(&fl->mu);
  n->next = fl->head;
  fl->head = n;
  fpr_unlock(&fl->mu);
}
static fpr_slab_t *slab_of(V v); /* fwd (defined with the ARC table) */
 /* declared early: the arena teardown and
                             * the deep-copy paths run under it */
/* arena telemetry, always on: how many times and how much the process
 * arena has grown.  Cheap (two adds under the existing paths), and the
 * difference between a healthy acb-floor drift and a leak is exactly
 * these numbers over time -- the Pi should not need gdb to say which. */
uw fpr_grow_count, fpr_grow_bytes;
/* THE one gateway to arena growth: every site calls this so the
 * ledger the UI shows is the whole truth.  (Its first version counted
 * only the slab site -- the on-screen number read 4x low.) */
/* ---- grow attribution -----------------------------------
 * The ONE counted gateway now records WHO grew: a lock-free ring of
 * the last GROWLOG_N (site, want, got, actor) events, written with an
 * atomic sequence bump and NOTHING else -- no lock, no print, no
 * allocation (the instrumentation-poison law: this runs at allocation
 * sites, sometimes under allocator locks).  Readers pull copies via
 * Sys.growLog; a torn slot (seq moved during the copy) is skipped.
 * Sites are the gateway's callers, named in growsite_name below. */
#define GROWLOG_N 32
typedef struct {
  uw seq; /* published LAST (release); 0 = never written */
  uw site, want, got, actor;
} growev_t;
static growev_t growlog[GROWLOG_N];
static uw growlog_seq;
const char *fpr_growsite_name(uw site) {
  static const char *names[] = {"?", "slab", "slab-spare", "buckets",
                                "big-block", "stack", "msg"};
  return site < sizeof names / sizeof *names ? names[site] : "?";
}
extern uw fpr_current_id(void);

fpr_grant_t fpr_grow_counted(uw want, uw site) {
  fpr_grant_t g = {0, 0};
  if (fpr_mem_own) { /* the memory actor's buddy (fpr.h) */
    g.ptr = fpr_mem_take(want);
    if (g.ptr) g.size = buddy_block_usable_size(g.ptr);
  } else if (fpr_grow_memory)
    g = fpr_grow_memory(want); /* a loaded process: the loader's grant */
  if (g.ptr) {
    __atomic_add_fetch(&fpr_grow_count, 1, __ATOMIC_RELAXED);
    __atomic_add_fetch(&fpr_grow_bytes, g.size, __ATOMIC_RELAXED);
    uw s = __atomic_fetch_add(&growlog_seq, 1, __ATOMIC_RELAXED);
    growev_t *e = &growlog[s % GROWLOG_N];
    __atomic_store_n(&e->seq, 0, __ATOMIC_RELAXED); /* invalidate for readers */
    e->site = site;
    e->want = want;
    e->got = g.size;
    e->actor = fpr_current_id();
    __atomic_store_n(&e->seq, s + 1, __ATOMIC_RELEASE);
  }
  return g;
}

static void praw(const char *s);
static void pdec(uw u);
extern uw fpr_current_id(void);
#ifdef FPR_GROWTRACE
static uw grant_pool_len(void);
/* one line per arena grow, whichever site asked -- the slab-only trace
 * hid three other growers and cost a day of wrong conclusions */
void fpr_growlog(const char *site, uw want) {
  praw("[grow] ");
  praw(site);
  praw(" actor ");
  pdec(fpr_current_id());
  praw(" want ");
  pdec(want);
  praw("\n");
}
#endif
static fpr_slab_t *grant_take(uw total) {
  /* the flnode rides next+owner; sl->end survives, which is the one
   * field reuse needs (grant_put derived cap from it) */
  return (fpr_slab_t *)fpr_fl_take(&grant_fl, total);
}

static void grant_put(fpr_slab_t *sl); /* fwd: defined just below */
/* a slab goes home: to the memory actor on an image that owns the
 * buddy, to the grant recycler in a loaded process (the loader never
 * takes grants back), else straight to buddy.  Safe from any context
 * and under any lock: the memory actor's path never waits. */
static void slab_home(fpr_slab_t *sl) {
  if (fpr_mem_own) fpr_mem_give(sl);
  else if (fpr_is_process) grant_put(sl);
  else buddy_free(sl);
}
/* the actual release of an ownerless (message) slab.  Split out so
 * actors.c's deferred-drop list can call it at drain time. */
void fpr_slab_release(fpr_slab_t *sl) {
  if (fpr_sched) { fpr_sched->slab_release(sl); return; }
  slab_home(sl);
}

/* a fresh pool slab from THIS image's lower allocator -- the shared
 * plane's growth path for routed process pools (fpr.h fpr_sched_t);
 * the caller is the process's actor, so the request parks it like
 * any other */
fpr_slab_t *fpr_slab_new(uw want) {
  fpr_slab_t *sl = (fpr_slab_t *)(fpr_mem_own ? fpr_mem_take(want) : buddy_alloc(want));
  if (!sl) return 0;
  sl->end = (char *)sl + buddy_block_usable_size(sl);
  return sl;
}

#ifdef FPR_GROWTRACE
static uw grant_pool_len(void) {
  uw n = 0;
  for (fpr_flnode_t *p = grant_fl.head; p; p = p->next) n++;
  return n;
}
#endif

static void grant_put(fpr_slab_t *sl) {
  fpr_fl_put(&grant_fl, sl, (uw)(sl->end - (char *)(sl + 1)));
}

/* bucket-array recycler (see fpr.h): fixed-size, type-stable */
typedef struct bktblk { void *b[FPR_NBUCKETS]; } bktblk_t;
static fpr_freelist_t bkt_fl;

void **fpr_bkt_take(void) {
  bktblk_t *k = (bktblk_t *)fpr_fl_take(&bkt_fl, sizeof(bktblk_t));
  if (!k) {
#ifdef FPR_GROWTRACE
    fpr_growlog("bkt", sizeof(bktblk_t));
#endif
    /* a 4 KiB array from a 64 KiB-floor allocator: carve the whole
     * block and seed the recycler with the rest (a block per array
     * left 6 MiB behind a hundred dead workers) */
    fpr_grant_t g = fpr_grow_counted(sizeof(bktblk_t), 3); /* buckets */
    if (g.ptr && g.size >= sizeof(bktblk_t)) {
      k = (bktblk_t *)g.ptr;
      for (char *q = (char *)g.ptr + sizeof(bktblk_t); q + sizeof(bktblk_t) <= (char *)g.ptr + g.size;
           q += sizeof(bktblk_t))
        fpr_fl_put(&bkt_fl, q, sizeof(bktblk_t));
    }
  }
  if (!k) return 0;
  for (int i = 0; i < FPR_NBUCKETS; i++) k->b[i] = 0;
  return k->b;
}

void fpr_bkt_put(void **b) {
  fpr_fl_put(&bkt_fl, b, sizeof(bktblk_t));
}

#ifndef FPR_BUILTIN
V fpr_alloc(V raw_bytes) {
  fpr_hart_t *h = fpr_hart();
  fpr_pool_t *pool = cur_pool(h);
  uw total = (((raw_bytes + 15) & ~(uw)15)) + 16;
  if (total <= (uw)16 * FPR_NBUCKETS) {
    uw idx = total / 16 - 1;
    void *p = bucket_take(pool, idx);
    if (p) {
      *(uw *)p = total; /* [1] (the slab ptr) survived recycling */
      { /* zero the rounding pad: the deep copier derives field counts
         * from total and must read pad words as benign (see fpr_dcopy) */
        uw pad = (total - 16) - raw_bytes;
        if (pad) __builtin_memset((char *)p + 16 + raw_bytes, 0, pad);
      }
      return (V)((char *)p + 16);
    }
  }
  if (total > (uw)16 * FPR_NBUCKETS && pool->bigfree) {
    /* exact-fit reuse of a freed big block: owner-only, so swap the
     * whole LIFO out, take one match, CAS the rest back (frees may
     * race in meanwhile -- prepending is safe) */
    void *lst = __atomic_exchange_n(&pool->bigfree, 0, __ATOMIC_ACQUIRE);
    void *take = 0, *keep = 0;
    while (lst) {
      void *nx = *(void **)((char *)lst + 16);
      if (!take && *(uw *)lst == total) take = lst;
      else { *(void **)((char *)lst + 16) = keep; keep = lst; }
      lst = nx;
    }
    while (keep) {
      void *nx = *(void **)((char *)keep + 16), *old;
      do {
        old = __atomic_load_n(&pool->bigfree, __ATOMIC_RELAXED);
        *(void **)((char *)keep + 16) = old;
      } while (!__atomic_compare_exchange_n(&pool->bigfree, &old, keep, 0,
                                            __ATOMIC_RELEASE, __ATOMIC_RELAXED));
      keep = nx;
    }
    if (take) {
      char *p = (char *)take;         /* header ([0] total, [1] slab) intact */
      *(uw *)(p + 16) = 0;            /* the link word: payload must start benign */
      uw pad = (total - 16) - raw_bytes;
      if (pad) __builtin_memset(p + 16 + raw_bytes, 0, pad);
      return (V)(p + 16);
    }
  }
  fpr_slab_t *sl = pool->cur;
  if (!sl || sl->hp + total > sl->end) {
    uw want = total + sizeof(fpr_slab_t);
    if (want < SLAB_SZ) want = SLAB_SZ;
    if (fpr_sched) {
      /* shared plane: pools grow from the KERNEL's buddy, so every
       * value this process builds lives in the one heap span and the
       * kernel reaps its acbs like any other */
      sl = fpr_sched->slab_new(want);
      if (!sl) fpr_cpanic("heap exhausted (shared buddy has no free block)");
    } else {
      sl = 0;
      if (!fpr_mem_own && fpr_is_process && fpr_grow_memory) {
        /* a loaded process without a buddy grows through its loader's
         * grant: recycled grant first; only a miss grows the arena */
        sl = grant_take(total);
        /* SELF-TOPPING on a miss, same reasoning as the stack pool: a
         * miss here is the spawn-vs-reap epilogue race finding the
         * grant recycler empty (a dying worker's slab returns
         * microseconds after the next worker's first alloc shops for
         * it).  Take a spare so recycler depth converges to real
         * concurrency and each level is a one-time cost, not a
         * permanent 256KB/N-frames drip. */
        if (!sl && want == SLAB_SZ) {
          fpr_grant_t sp = fpr_grow_counted(SLAB_SZ, 2); /* slab-spare */
          if (sp.ptr) {
            fpr_slab_t *ss = (fpr_slab_t *)sp.ptr;
            ss->end = (char *)sp.ptr + sp.size;
            grant_put(ss);
          }
        }
      }
      if (!sl) {
        /* the memory actor's buddy (or the loader's grant): one block */
        fpr_grant_t g = fpr_grow_counted(want, 1); /* slab */
#ifdef FPR_GROWTRACE
        { /* which actor, and is the recycler empty? */
          praw("[grow] slab actor ");
          pdec(fpr_current_id());
          praw(" want ");
          pdec(want);
          praw(" recycled ");
          pdec(grant_pool_len());
          praw("\n");
        }
#endif
        if (!g.ptr || g.size < total + sizeof(fpr_slab_t)) {
          /* the post-mortem journal should carry the numbers: how much
           * had been taken and what was being asked when it died */
          praw("[mem] exhausted: want ");
          pdec(want);
          praw(" after ");
          pdec(fpr_grow_count);
          praw(" blocks / ");
          pdec(fpr_grow_bytes >> 20);
          praw(" MiB taken\n");
          fpr_cpanic("heap exhausted (no block for a slab)");
        }
        sl = (fpr_slab_t *)g.ptr;
        sl->end = (char *)g.ptr + g.size;
      }
    }
    sl->owner = pool;
    sl->escaped = 0;
    sl->holds = 0;
    sl->hp = (char *)(sl + 1);
    sl->next = pool->cur;
    pool->cur = sl;
  }
  char *p = sl->hp;
  sl->hp += total;
  pool->allocated += total;
  *(uw *)p = total;
  *(fpr_slab_t **)(p + 8) = sl;
  { /* pad zeroing, same reason as the bucket path */
    uw pad = (total - 16) - raw_bytes;
    if (pad) __builtin_memset(p + 16 + raw_bytes, 0, pad);
  }
  return (V)(p + 16);
}

/* called ONLY from the ARC drop path, under arc_lock -- which is what
 * makes reading slab->owner race-free against death teardown (also
 * under arc_lock).  An orphaned slab's blocks are not recycled: the
 * whole slab goes back to buddy when its last promoted object drops. */
/* the third op of the allocator contract (docs/MEMORY.md): grow a
 * block to hold `want` payload bytes.  Copy-based through the pool
 * tiers today: the preheader's total names the old payload capacity,
 * and the freed predecessor recycles exactly (buckets below the
 * ceiling, the bigfree LIFO above it), so a doubling ladder reuses
 * its own history.  In-place growth arrives when bulk storage moves
 * behind Memory.qa's buddy (docs/MEMORY-V2-PLAN.md), where
 * buddy_realloc already provides it. */
V fpr_realloc(V v, V want) {
  if (!v) return fpr_alloc(want);
  uw old = *(uw *)((char *)v - 16) - 16; /* payload capacity */
  if (old >= (uw)want) return v;
  V n = fpr_alloc(want);
  __builtin_memcpy((void *)n, (void *)v, old);
  fpr_free(v);
  return n;
}

void fpr_free(V v) {
  char *p = (char *)v - 16;
  uw total = *(uw *)p;
  fpr_slab_t *sl = *(fpr_slab_t **)(p + 8);
  if (total == 0) return; /* corrupt or double-freed: stays in slab */
  if (!sl || !sl->owner) return;
  if (total > (uw)16 * FPR_NBUCKETS) {
    /* above the bucket ceiling: exact-fit bigfree LIFO.  The header
     * stays intact (reuse needs total + slab), the link rides the
     * first payload word -- so no poison tripwire here. */
    fpr_pool_t *bpool = sl->owner;
    void *old;
    do {
      old = __atomic_load_n(&bpool->bigfree, __ATOMIC_RELAXED);
      *(void **)(p + 16) = old;
    } while (!__atomic_compare_exchange_n(&bpool->bigfree, &old, p, 0,
                                          __ATOMIC_RELEASE, __ATOMIC_RELAXED));
    return;
  }
  fpr_pool_t *pool = sl->owner;
  uw idx = total / 16 - 1;
  *(uw *)p = 0; /* poison size: crude double-free tripwire */
  void *old;
  if (!pool->buckets) return;
  do {
    old = __atomic_load_n(&pool->buckets[idx], __ATOMIC_RELAXED);
    *(void **)p = old;
  } while (!__atomic_compare_exchange_n(&pool->buckets[idx], &old, p, 0,
                                        __ATOMIC_RELEASE, __ATOMIC_RELAXED));
}

#endif

/* ==== DEEP-COPY MESSAGE TRANSFER (the "it just works" send) ==========
 *
 * The four blood-paid laws -- copy-on-retain, never-send-live-state,
 * flat-root contortion, drop-what-you-receive-or-leak-the-slab -- all
 * share one cause: send used to pin only the message ROOT while its
 * children stayed loose in the sender's pool.  Now send deep-copies the
 * whole message into ONE ownerless slab (owner = NULL from birth), and
 * every existing reclamation path just works: interior fpr_free is
 * already a no-op on ownerless slabs, and the root's final decref
 * already frees a !owner escape-free slab wholesale (grant recycler in
 * process mode, buddy on machine boot).  One message = one slab; drop
 * of the root frees EVERYTHING, and nothing the sender does afterward
 * (poolReset, death, mutation) can touch the receiver's copy.
 *
 * Field discovery is DERIVED, not tabled: every object carries its
 * total size in the 16-byte preheader, so nfields = (total-16-8)/W for
 * uniform-V constructors; the rounding pad is zeroed at alloc, and a
 * zero word is copied verbatim, never recursed.  Special tids:
 *   T_STR/T_BITS/T_DEVICE/T_REGISTER  raw bytes, no V fields
 *   T_PAP                              nargs known in the struct
 *   T_VEC                              COPIED like everything else
 *                                      (v2: header, cols, and column
 *                                      data all land in the slab --
 *                                      vec_layout.h is the contract)
 *   T_ACTOR                            immortal acb: share pointer
 *   T_SSTR                             linear-local: refused honestly
 *   T_LIST var 1                       spine iterated, not recursed
 * Statics (out of heap) and ints copy by value.  Sharing inside one
 * message duplicates (values are immutable trees; DAGs cost bytes,
 * never correctness).  fpr_dcopy also serves `keep` (retention into
 * the caller's own pool) with fpr_alloc as the allocator. */

void fpr_vec_release(V v); /* vec.c: the universal vector free */

/* release what a dropped message root still owns OUTSIDE its slab:
 * slab-resident cells die with the slab wholesale, but a received
 * vector the receiver GREW reallocated its column bases into the
 * receiver's pool -- fpr_vec_release frees those (and no-ops on the
 * slab pieces).  Runs only on ownerless message slabs at final drop. */
static void dc_release(V v) {
  if (ISINT(v) || !v || !fpr_in_heap(v)) return;
  hdr_t *h = (hdr_t *)v;
  switch (h->tid) {
    case T_VEC: fpr_vec_release(v); return;
    case T_ACTOR: case T_STR: case T_BITS: case T_DEVICE: case T_REGISTER:
    case T_SSTR: return;
    case T_PAP: {
      pap_t *p = (pap_t *)v;
      for (uw i = 0; i < p->nargs; i++) dc_release((V)p->args[i]);
      return;
    }
    case T_LIST: {
      V c = v;
      while (!ISINT(c) && fpr_in_heap(c) && TID(c) == T_LIST &&
             ((hdr_t *)c)->var == 1) {
        dc_release(*(V *)((char *)c + 8));
        c = *(V *)((char *)c + 8 + sizeof(uw));
      }
      return;
    }
    default: {
      uw total = *(uw *)((char *)v - 16);
      uw nf = (total - 16 - 8) / sizeof(uw);
      V *f = (V *)((char *)v + 8);
      for (uw i = 0; i < nf; i++) dc_release(f[i]);
      return;
    }
  }
}

typedef struct { char *hp; fpr_slab_t *sl; } dctx_t;

/* a fresh cell's slab footprint: fpr_alloc's exact rounding + header */
static uw dc_cellsz(uw raw) { return (((raw + 15) & ~(uw)15)) + 16; }

static uw dc_size(V v) {
  if (ISINT(v) || !v || !fpr_in_heap(v)) return 0;
  uw total = *(uw *)((char *)v - 16);
  hdr_t *h = (hdr_t *)v;
  switch (h->tid) {
    case T_ACTOR: return 0; /* immortal acb: shared, not copied */
    case T_VEC: {
      vec_t *x = (vec_t *)v;
      uw n = dc_cellsz(sizeof(vec_t));
      for (uw k = 0; k < x->ncols; k++) {
        if (!x->cols[k]) continue;
        n += dc_cellsz(sizeof(col_t));
        if (x->len) n += dc_cellsz(x->len * sizeof(uw));
        if (!((x->kinds >> k) & 1)) /* boxed column: elements recurse */
          for (uw i = 0; i < x->len; i++)
            n += dc_size((V)x->cols[k]->base[i]);
      }
      return n;
    }
    case T_SSTR: fpr_cpanic("send/keep: SString is linear-local");
    case T_STR: case T_BITS: case T_DEVICE: case T_REGISTER: return total;
    case T_PAP: {
      pap_t *p = (pap_t *)v;
      uw n = total;
      for (uw i = 0; i < p->nargs; i++) n += dc_size((V)p->args[i]);
      return n;
    }
    case T_LIST: {
      uw n = 0;
      V c = v;
      while (!ISINT(c) && fpr_in_heap(c) && TID(c) == T_LIST &&
             ((hdr_t *)c)->var == 1) {
        n += *(uw *)((char *)c - 16);
        n += dc_size(*(V *)((char *)c + 8)); /* head */
        c = *(V *)((char *)c + 8 + sizeof(uw));
      }
      return n + dc_size(c); /* nil (static: 0) or improper tail */
    }
    default: { /* uniform-V constructor: derive field count */
      uw nf = (total - 16 - 8) / sizeof(uw);
      uw n = total;
      V *f = (V *)((char *)v + 8);
      for (uw i = 0; i < nf; i++) n += dc_size(f[i]);
      return n;
    }
  }
}

static V dc_dup(V v, dctx_t *c); /* fwd */

static V dc_cell(V v, dctx_t *c, uw total) {
  char *p = c->hp;
  c->hp += total;
  *(uw *)p = total;
  *(fpr_slab_t **)(p + 8) = c->sl; /* interior promotes pin THIS slab */
  __builtin_memcpy(p + 16, (char *)v, total - 16);
  return (V)(p + 16);
}

/* a FRESH cell in the slab (no source memcpy): the vec copier builds
 * its header/cols/data cells directly */
static V dc_bump(dctx_t *c, uw raw) {
  uw total = dc_cellsz(raw);
  char *p = c->hp;
  c->hp += total;
  *(uw *)p = total;
  *(fpr_slab_t **)(p + 8) = c->sl;
  return (V)(p + 16);
}

static V dc_dup(V v, dctx_t *c) {
  if (ISINT(v) || !v || !fpr_in_heap(v)) return v;
  uw total = *(uw *)((char *)v - 16);
  hdr_t *h = (hdr_t *)v;
  switch (h->tid) {
    case T_VEC: {
      /* the whole vector -- header, col_t's, column spans -- lands in
       * the message slab: one message = one slab, vectors included.
       * cap = len (tight): a later push on the receiver's side grows
       * through fpr_realloc into ITS pool; the slab cell is then
       * "freed" as a no-op and dies with the slab at root drop. */
      vec_t *x = (vec_t *)v;
      vec_t *n = (vec_t *)dc_bump(c, sizeof(vec_t));
      n->tid = T_VEC;
      n->var = x->var;
      n->len = x->len; n->eltid = x->eltid; n->elvar = x->elvar;
      n->ncols = x->ncols; n->kinds = x->kinds; n->fkinds = x->fkinds;
      for (uw k = 0; k < VMAXCOLS; k++) n->cols[k] = 0;
      for (uw k = 0; k < x->ncols; k++) {
        if (!x->cols[k]) continue;
        col_t *nc = (col_t *)dc_bump(c, sizeof(col_t));
        nc->cap = 0;
        nc->base = 0;
        if (x->len) {
          nc->base = (uw *)dc_bump(c, x->len * sizeof(uw));
          nc->cap = x->len;
          if ((x->kinds >> k) & 1)
            __builtin_memcpy(nc->base, x->cols[k]->base,
                             x->len * sizeof(uw));
          else /* boxed column: elements are Vs, copy them too */
            for (uw i = 0; i < x->len; i++)
              nc->base[i] = (uw)dc_dup((V)x->cols[k]->base[i], c);
        }
        n->cols[k] = nc;
      }
      return (V)n;
    }
    case T_ACTOR: return v;
    case T_STR: case T_BITS: case T_DEVICE: case T_REGISTER:
      return dc_cell(v, c, total);
    case T_PAP: {
      V n = dc_cell(v, c, total);
      pap_t *p = (pap_t *)n;
      for (uw i = 0; i < p->nargs; i++) p->args[i] = (uw)dc_dup((V)p->args[i], c);
      return n;
    }
    case T_LIST: {
      if (h->var != 1) return dc_cell(v, c, total); /* heap nil */
      V first = 0, *patch = &first;
      V cur = v;
      while (!ISINT(cur) && fpr_in_heap(cur) && TID(cur) == T_LIST &&
             ((hdr_t *)cur)->var == 1) {
        V n = dc_cell(cur, c, *(uw *)((char *)cur - 16));
        *patch = n;
        *(V *)((char *)n + 8) = dc_dup(*(V *)((char *)cur + 8), c);
        patch = (V *)((char *)n + 8 + sizeof(uw));
        cur = *(V *)((char *)cur + 8 + sizeof(uw));
      }
      *patch = dc_dup(cur, c);
      return first;
    }
    default: {
      uw nf = (total - 16 - 8) / sizeof(uw);
      V n = dc_cell(v, c, total);
      V *f = (V *)((char *)n + 8);
      for (uw i = 0; i < nf; i++) f[i] = dc_dup(f[i], c);
      return n;
    }
  }
}

/* ---- message slabs: PACKED --------------------------------------------
 * A message used to get a slab of its own -- 256 KiB from the buddy for
 * a forty-byte tuple, three thousand in flight was 750 MiB, and with
 * the memory actor every send was a round trip.  Now each actor packs
 * its outgoing messages into ONE ownerless slab (MSG_SLAB_SZ, the
 * buddy's floor) until it is full, then starts another; a message too
 * big for a fresh one gets a slab of its own, as before.
 *
 * Lifetime is the two counts on the slab, both under arc_lock:
 * `escaped` (promoted roots still live, exactly as before) and
 * `holds` -- the sender's own hold while it is still packing into the
 * slab, plus one per DROPPER whose borrow window is open (fpr_drop_park:
 * a dropped root's children may be read until that actor's next
 * receive, so its hold lasts until then).  The slab goes home when both
 * are zero.  With one dropper per slab the old "park the slab on the
 * dropper" was the same rule; with many droppers it would have freed
 * the slab under a slower dropper's window, which is why the holds
 * exist. */
#ifndef FPR_MSG_SLAB_SZ
#define FPR_MSG_SLAB_SZ ((uw)64 * 1024)
#endif
#define MSG_SLAB_SZ FPR_MSG_SLAB_SZ
static fpr_slab_t *msg_slab_new(uw need) {
  fpr_slab_t *sl = 0;
  uw want = need + sizeof(fpr_slab_t);
  if (want < MSG_SLAB_SZ) want = MSG_SLAB_SZ;
  if (!fpr_mem_own && fpr_is_process && fpr_grow_memory) sl = grant_take(need);
  if (!sl) {
    fpr_grant_t g = fpr_grow_counted(want, 6); /* msg */
    if (!g.ptr || g.size < need + sizeof(fpr_slab_t))
      fpr_cpanic("send: no block for the message slab");
    sl = (fpr_slab_t *)g.ptr;
    sl->end = (char *)g.ptr + g.size;
  }
  sl->owner = 0; /* ownerless from birth: freed wholesale on last drop */
  sl->escaped = 0;
  sl->holds = 0;
  sl->hp = (char *)(sl + 1);
  sl->next = 0;
  return sl;
}
/* holds--; the slab goes home once nothing keeps it (arc_lock) */
static void slab_unhold_locked(fpr_slab_t *sl) {
  if (--sl->holds == 0 && sl->escaped == 0 && !sl->owner) fpr_slab_release(sl);
}
void fpr_slab_unhold(fpr_slab_t *sl, int locked) {
  if (!locked) fpr_lock(&arc_lock);
  slab_unhold_locked(sl);
  if (!locked) fpr_unlock(&arc_lock);
}
void fpr_slabs_unhold(fpr_slab_t **sls, uw n) {
  fpr_lock(&arc_lock);
  for (uw i = 0; i < n; i++) slab_unhold_locked(sls[i]);
  fpr_unlock(&arc_lock);
}
static V msg_copy_in(V v, int fresh) {
  uw need = dc_size(v);
  if (!need) return dc_dup(v, 0); /* ints, statics, bare actor handles */
  fpr_hart_t *h = fpr_hart();
  fpr_slab_t **slot = (!fresh && h && h->current) ? fpr_acb_msg_slot(h->current) : 0;
  fpr_slab_t *sl = slot ? *slot : 0;
  if (sl && sl->hp + need > sl->end) { /* full: the sender's hold ends */
    *slot = 0;
    fpr_slab_unhold(sl, 0);
    sl = 0;
  }
  if (!sl) {
    sl = msg_slab_new(need);
    if (slot && need + sizeof(fpr_slab_t) <= MSG_SLAB_SZ) {
      sl->holds = 1; /* the sender keeps packing into it */
      *slot = sl;
    }
  }
  dctx_t c = {sl->hp, sl};
  V r = dc_dup(v, &c);
  sl->hp = c.hp;
  return r;
}
/* copy v into the sender's message slab; returns the new root (or v
 * itself when there is nothing to copy: ints, statics, bare handles) */
#ifndef FPR_MSG_PACK
#define FPR_MSG_PACK 1 /* 0: a slab per message (the bisecting switch) */
#endif
V fpr_msg_copy(V v) { return msg_copy_in(v, !FPR_MSG_PACK); }
/* ... into a slab of its own: Sys.arena's transfer copy, freed by hand */
V fpr_msg_copy_fresh(V v) { return msg_copy_in(v, 1); }

/* keep: retain a received value past its message's drop -- a deep copy
 * into the CALLER'S OWN pool (fpr_alloc), vectors included (v2: a
 * kept vector is the keeper's own; nothing outlives its slab by
 * reference).  This is the one retention annotation the turn-scoped
 * model needs. */
static V kp_dup(V v) {
  if (ISINT(v) || !v || !fpr_in_heap(v)) return v;
  uw total = *(uw *)((char *)v - 16);
  hdr_t *h = (hdr_t *)v;
  switch (h->tid) {
    case T_VEC: {
      vec_t *x = (vec_t *)v;
      vec_t *n = (vec_t *)fpr_alloc(sizeof(vec_t));
      n->tid = T_VEC;
      n->var = x->var;
      n->len = x->len; n->eltid = x->eltid; n->elvar = x->elvar;
      n->ncols = x->ncols; n->kinds = x->kinds; n->fkinds = x->fkinds;
      for (uw k = 0; k < VMAXCOLS; k++) n->cols[k] = 0;
      for (uw k = 0; k < x->ncols; k++) {
        if (!x->cols[k]) continue;
        col_t *nc = (col_t *)fpr_alloc(sizeof(col_t));
        nc->cap = 0;
        nc->base = 0;
        if (x->len) {
          nc->base = (uw *)fpr_alloc(x->len * sizeof(uw));
          nc->cap = x->len;
          if ((x->kinds >> k) & 1)
            __builtin_memcpy(nc->base, x->cols[k]->base,
                             x->len * sizeof(uw));
          else
            for (uw i = 0; i < x->len; i++)
              nc->base[i] = (uw)kp_dup((V)x->cols[k]->base[i]);
        }
        n->cols[k] = nc;
      }
      return (V)n;
    }
    case T_ACTOR: return v;
    case T_SSTR: fpr_cpanic("keep: SString is linear-local");
    case T_STR: case T_BITS: case T_DEVICE: case T_REGISTER: {
      V n = fpr_alloc(total - 16);
      __builtin_memcpy((void *)n, (void *)v, total - 16);
      return n;
    }
    case T_PAP: {
      V n = fpr_alloc(total - 16);
      __builtin_memcpy((void *)n, (void *)v, total - 16);
      pap_t *p = (pap_t *)n;
      for (uw i = 0; i < p->nargs; i++) p->args[i] = (uw)kp_dup((V)p->args[i]);
      return n;
    }
    case T_LIST: {
      if (h->var != 1) {
        V n = fpr_alloc(total - 16);
        __builtin_memcpy((void *)n, (void *)v, total - 16);
        return n;
      }
      V first = 0, *patch = &first;
      V cur = v;
      while (!ISINT(cur) && fpr_in_heap(cur) && TID(cur) == T_LIST &&
             ((hdr_t *)cur)->var == 1) {
        uw t = *(uw *)((char *)cur - 16);
        V n = fpr_alloc(t - 16);
        __builtin_memcpy((void *)n, (void *)cur, t - 16);
        *patch = n;
        *(V *)((char *)n + 8) = kp_dup(*(V *)((char *)cur + 8));
        patch = (V *)((char *)n + 8 + sizeof(uw));
        cur = *(V *)((char *)cur + 8 + sizeof(uw));
      }
      *patch = kp_dup(cur);
      return first;
    }
    default: {
      uw nf = (total - 16 - 8) / sizeof(uw);
      V n = fpr_alloc(total - 16);
      __builtin_memcpy((void *)n, (void *)v, total - 16);
      V *f = (V *)((char *)n + 8);
      for (uw i = 0; i < nf; i++) f[i] = kp_dup(f[i]);
      return n;
    }
  }
}
static V g_keep(V v) { return kp_dup(v); }
FPR_FN(fpr_g_keep, g_keep, 1);

/* ---- Sys.arena: the structured arena --------------------------------
 * poolReset's "no live locals" contract was a footgun by construction:
 * the reset nukes the CALLER's pool, so every local had to be proven
 * dead by hand.  Sys.arena inverts it: run the thunk under a FRESH
 * pool (pool_override in cur_pool), deep-copy the RESULT out through a
 * message slab, tear the arena pool down wholesale, then copy the
 * result into the caller's own pool.  Escapes are impossible by
 * construction -- not because an analysis proved them absent, but
 * because the result is the only thing that leaves and it leaves BY
 * COPY.  Caller locals are untouched (different pool).  The sacrifice
 * is one deep copy of the result: the theme of this whole patch set.
 *
 * HONEST REFUSAL: a Vector result cannot escape -- its storage lives
 * in the arena slabs being torn down, and CoW sharing would dangle.
 * Detected by walk, refused with a message.  Return scalars, strings,
 * or trees; build pool-owned vectors OUTSIDE arenas (their whole point
 * is stable identity, which is the opposite of arena scoping).
 * Nested arenas work (the previous override is saved/restored). */
static int has_vec(V v) {
  if (ISINT(v) || !v || !fpr_in_heap(v)) return 0;
  hdr_t *h = (hdr_t *)v;
  switch (h->tid) {
    case T_VEC: return 1;
    case T_ACTOR: case T_STR: case T_BITS: case T_DEVICE: case T_REGISTER:
    case T_SSTR: return 0;
    case T_PAP: {
      pap_t *p = (pap_t *)v;
      for (uw i = 0; i < p->nargs; i++)
        if (has_vec((V)p->args[i])) return 1;
      return 0;
    }
    case T_LIST: {
      V c = v;
      while (!ISINT(c) && fpr_in_heap(c) && TID(c) == T_LIST &&
             ((hdr_t *)c)->var == 1) {
        if (has_vec(*(V *)((char *)c + 8))) return 1;
        c = *(V *)((char *)c + 8 + sizeof(uw));
      }
      return has_vec(c);
    }
    default: {
      uw total = *(uw *)((char *)v - 16);
      uw nf = (total - 16 - 8) / sizeof(uw);
      V *f = (V *)((char *)v + 8);
      for (uw i = 0; i < nf; i++)
        if (has_vec(f[i])) return 1;
      return 0;
    }
  }
}

static V g_arena(V f) {
  fpr_hart_t *h = fpr_hart();
  struct fpr_pool *prev = h->pool_override;
  fpr_pool_t ap;
  fpr_pool_init(&ap, fpr_bkt_take()); /* bigfree=0 matters: a stack pool
                                       * with garbage there walked it as
                                       * a freelist on any >ceiling alloc */
  if (!ap.buckets) fpr_cpanic("Sys.arena: no memory for a bucket array");
  h->pool_override = (struct fpr_pool *)&ap;
  V r = fpr_apply(f, (V)&fpr_unit);
  if (has_vec(r))
    fpr_cpanic("Sys.arena: Vector results cannot escape an arena "
               "(their storage IS the arena) -- return scalars/trees, "
               "or build pool-owned vectors outside");
  V t = fpr_msg_copy_fresh(r); /* its own slab: survives the teardown, freed below */
  /* teardown, poolReset-style, under arc_lock (owner/escaped race) */
  fpr_lock(&arc_lock);
  fpr_slab_t *sl = ap.cur;
  while (sl) {
    fpr_slab_t *nx = sl->next;
    if (sl->escaped == 0) slab_home(sl);
    else sl->owner = 0; /* something was sent from inside: orphan it */
    sl = nx;
  }
  fpr_unlock(&arc_lock);
  fpr_bkt_put(ap.buckets);
  h->pool_override = prev;
  /* copy the result into the CALLER's pool; free the transfer slab */
  if (ISINT(t) || !fpr_in_heap(t)) return t;
  fpr_slab_t *ts = slab_of(t);
  V out = kp_dup(t);
  if (ts && !ts->owner && ts->escaped == 0 && ts->holds == 0) {
    fpr_lock(&arc_lock);
    slab_home(ts);
    fpr_unlock(&arc_lock);
  }
  return out;
}
FPR_FN(fpr_g_Sys_x2earena, g_arena, 1);

/* death teardown (hart loop, after the switch OFF the actor's stack):
 * slabs with no escaped objects return to buddy now; the rest are
 * orphaned and return when their last promoted object is dropped.
 * The stack never escapes: always reclaimed. */
void fpr_arc_teardown_pool(fpr_pool_t *pool); /* below, with the ARC state */
void fpr_pool_reclaim(struct fpr_acb *a) {
  fpr_arc_teardown_pool(fpr_acb_pool(a));
}

/* ---- ARC: cross-actor sharing accounts ------------------------------
 * The rule from the design discussion: basic values (tagged ints) cross
 * actor boundaries by value; anything heap-allocated gets PROMOTED on
 * send -- an entry in the ARC table, count = number of cross-actor
 * shares. Static objects (rodata strings, prim PAPs, devices) are
 * immortal and skip the table via the heap-range check. `drop` decrefs;
 * at zero the object is returned to the free list. Reclamation is
 * SHALLOW: fields are not traversed (objects don't carry field counts
 * -- an ABI v2 with a 16-byte header would fix that, same change deep
 * equality wants). In the real compiler the RC-insertion pass emits
 * these drops; here the demo program does it by hand to show the
 * protocol working. */
/* THE TABLE GROWS.  It starts as a static 1024-slot array and rehashes
 * into a buddy block of twice the size whenever live + tombstone slots
 * pass 70% -- so a long-running hub with ten thousand shared values in
 * flight costs a bigger table, not a panic (the old fixed table died
 * at 1024).  Growth happens under arc_lock on the insert path, before
 * the probe, so a probe never runs on a table it could overrun; the
 * panic below is unreachable and kept as the last word if allocation
 * itself fails.  arc_hwm is the most live entries ever held. */
#define ARC_CAP0 1024
#define ARC_TOMB ((V)1)
typedef struct { V ptr; uw cnt; } arcent_t;
static arcent_t arct0[ARC_CAP0];
static arcent_t *arct = arct0;
static uw arc_cap = ARC_CAP0;
static uw arc_live, arc_used, arc_hwm, arc_grows; /* used = live + tombstones */

/* probe for v; on miss, the returned slot is the best insertion point
 * (first tombstone seen, else the empty that ended the probe) --
 * without tombstone reuse, heavy promote/drop cycling fills the table
 * with tombstones and kills it (found the hard way: a 100k-hop token
 * ring paniced "ARC table full" at ~1k cycles). */
static uw arc_probe(V v, int *found) {
  uw i = ((v >> 4) * (uw)2654435761UL) & (arc_cap - 1);
  uw first_tomb = arc_cap;
  for (uw n = 0; n < arc_cap; n++) {
    V p = arct[i].ptr;
    if (p == v) { *found = 1; return i; }
    if (p == 0) { *found = 0; return first_tomb != arc_cap ? first_tomb : i; }
    if (p == ARC_TOMB && first_tomb == arc_cap) first_tomb = i;
    i = (i + 1) & (arc_cap - 1);
  }
  *found = 0;
  if (first_tomb != arc_cap) return first_tomb;
  fpr_cpanic("ARC table full");
}
/* a block for the table: the counted gateway (the memory actor, or a
 * loader grant); `direct` for the never-waiting path under arc_lock */
static void *arc_block(uw bytes, int direct) {
  if (fpr_mem_own && direct) return fpr_mem_take_direct(bytes);
  fpr_grant_t g = fpr_grow_counted(bytes, 5); /* site 5: the ARC table */
  return (g.ptr && g.size >= bytes) ? g.ptr : 0;
}
/* the next table, taken BEFORE arc_lock by whoever is about to insert
 * (a memory-actor request parks the caller; no spinlock is held across
 * a wait) and installed by arc_grow under the lock.  A spare that
 * turns out unneeded (a racer grew first) goes back. */
static arcent_t *arc_spare;
static uw arc_spare_cap;
static void arc_reserve(void) {
  uw cap = __atomic_load_n(&arc_cap, __ATOMIC_RELAXED);
  if ((__atomic_load_n(&arc_used, __ATOMIC_RELAXED) + 1) * 10 <= cap * 7) return;
  if (__atomic_load_n(&arc_spare, __ATOMIC_ACQUIRE)) return;
  uw ncap = cap * 2;
  arcent_t *nt = (arcent_t *)arc_block(ncap * sizeof(arcent_t), 0);
  if (!nt) return; /* the direct fallback under the lock has the last word */
  fpr_lock(&arc_lock);
  if (!arc_spare && arc_cap == cap) { arc_spare = nt; arc_spare_cap = ncap; nt = 0; }
  fpr_unlock(&arc_lock);
  if (nt) { if (fpr_mem_own) fpr_mem_give(nt); }
}
/* under arc_lock: double the table and reinsert the live entries
 * (tombstones are left behind, which is what makes the rehash also the
 * table's compaction) */
static void arc_grow(void) {
  uw ncap = arc_cap * 2;
  arcent_t *nt = 0;
  if (arc_spare && arc_spare_cap == ncap) { nt = arc_spare; arc_spare = 0; }
  if (!nt) nt = (arcent_t *)arc_block(ncap * sizeof(arcent_t), 1);
  if (!nt) return; /* out of memory: the probe's panic stays the last word */
  __builtin_memset(nt, 0, ncap * sizeof(arcent_t));
  arcent_t *ot = arct;
  uw ocap = arc_cap;
  arct = nt;
  arc_cap = ncap;
  arc_used = 0;
  for (uw k = 0; k < ocap; k++) {
    if (ot[k].ptr && ot[k].ptr != ARC_TOMB) {
      int f;
      uw j = arc_probe(ot[k].ptr, &f);
      arct[j] = ot[k];
      arc_used++;
    }
  }
  if (ot != arct0) { if (fpr_mem_own) fpr_mem_give(ot); else if (!fpr_is_process) buddy_free(ot); }
  arc_grows++;
}
/* an insert is coming: make room first (the 70% rule) and account for it */
static uw arc_slot_for(V v, int *found) {
  if ((arc_used + 1) * 10 > arc_cap * 7) arc_grow();
  uw i = arc_probe(v, found);
  if (!*found) {
    if (arct[i].ptr == 0) arc_used++; /* a tombstone reused keeps the count */
    if (arc_live + 1 > arc_hwm) arc_hwm = arc_live + 1;
  }
  return i;
}
uw fpr_arc_cap(void) { return arc_cap; }
uw fpr_arc_hwm(void) { return arc_hwm; }
uw fpr_arc_grows_count(void) { return arc_grows; }

/* one lock for the whole table: promotion happens on SEND, which is
 * rare next to computation -- contention is negligible and the SPSC
 * story stays clean (the table is the ONLY shared-mutable structure
 * in the runtime that is not a single-producer ring). */


static fpr_slab_t *slab_of(V v) { return *(fpr_slab_t **)((char *)v - 8); }

/* an actor handle is the acb itself: immortal, no allocation preheader,
 * shared raw -- a bare handle as a message (spawn's result passed on)
 * must not be counted, or the slab lookup reads the word before it */
static int arc_by_value(V v) {
  return !fpr_in_heap(v) || TID(v) == T_ACTOR;
}
void fpr_arc_incref(V v) {
  if (fpr_sched) { fpr_sched->arc_incref(v); return; }
  if (arc_by_value(v)) return; /* ints, immortal statics, handles: by value */
  arc_reserve(); /* the next table, if one is due, before the lock */
  fpr_lock(&arc_lock);
  int found;
  uw i = arc_slot_for(v, &found);
  if (!found) {
    arct[i].ptr = v;
    arct[i].cnt = 0;
    arc_live++;
    /* first promotion: this object now pins its slab (escape count) */
    fpr_slab_t *sl = slab_of(v);
    if (sl) sl->escaped++;
  }
  arct[i].cnt++;
  fpr_unlock(&arc_lock);
}

void fpr_arc_decref(V v) {
  if (fpr_sched) { fpr_sched->arc_decref(v); return; }
  if (arc_by_value(v)) return;
  fpr_lock(&arc_lock);
  int found;
  uw i = arc_probe(v, &found);
  if (!found) { fpr_unlock(&arc_lock); return; } /* never shared: no-op */
  int dead = (--arct[i].cnt == 0);
  if (dead) {
    arct[i].ptr = ARC_TOMB; /* tombstone keeps probe chains intact */
    arc_live--;
    fpr_slab_t *sl = slab_of(v);
    if (sl) {
      sl->escaped--;
      if (!sl->owner) {
        /* an ownerless slab (a message slab, or a dead actor's
         * orphaned one): release the root's vecs and take THIS
         * DROPPER's hold on the slab -- every drop, not only the last
         * escapee's, because the slab is shared by many messages now
         * and each dropper's borrow window (the compiler's `drop m`
         * right after the destructure, the arm still reading the
         * children) must keep the slab until its own next receive.
         * The slab goes home once escaped and holds are both zero. */
        dc_release(v);
        fpr_drop_park(sl);
      } else {
        fpr_free(v); /* under arc_lock: owner read is death-race-free */
      }
    }
  }
  fpr_unlock(&arc_lock);
}

/* death teardown, under the same lock that guards owner/escaped:
 * escape-free slabs return to buddy; the rest are orphaned. */
void fpr_arc_teardown_pool(fpr_pool_t *pool) {
  fpr_lock(&arc_lock);
  fpr_slab_t *sl = pool->cur;
  while (sl) {
    fpr_slab_t *nx = sl->next;
    if (sl->escaped == 0) slab_home(sl); /* home: the memory actor, or the
                                          * grant recycler (see grant_take) */
    else sl->owner = 0; /* orphan: freed at last drop above */
    sl = nx;
  }
  pool->cur = 0;
  pool->bigfree = 0; /* big free blocks die with their slabs */
  if (pool->buckets) {
    fpr_bkt_put(pool->buckets); /* type-stable reuse; see fpr.h */
    pool->buckets = 0;
  }
  fpr_unlock(&arc_lock);
}

/* SOFT DEATH: reclaim the CURRENT actor's pool in place -- the same
 * walk as death teardown (clean slabs to the recycler, escaped slabs
 * orphaned so the last drop frees them), but the actor lives on with
 * an empty pool.  This is what makes a PERSISTENT frame worker have
 * frame-per-actor memory semantics without paying an acb + stack +
 * chblk per frame: the pool is the frame arena, and this is the end
 * of the frame.  CONTRACT: call only when the actor holds no live
 * local values -- everything it still needs must be owned elsewhere
 * (the spawner's pool, C-owned rings, or the message it will receive
 * next).  The bucket index is CLEARED, not returned: every recorded
 * free cell lives in a slab this walk just recycled or orphaned. */
static V g_poolReset(V u) {
  (void)u;
  if (fpr_sched) { fpr_sched->pool_reset(); return (V)&fpr_unit; }
  fpr_hart_t *h = fpr_hart();
  fpr_pool_t *pool = cur_pool(h);
  fpr_drop_drain_current(); /* soft death = end of frame: borrows are done */
  fpr_lock(&arc_lock);
  fpr_slab_t *sl = pool->cur;
  while (sl) {
    fpr_slab_t *nx = sl->next;
    if (sl->escaped == 0) slab_home(sl);
    else sl->owner = 0;
    sl = nx;
  }
  pool->cur = 0;
  pool->allocated = 0;
  pool->bigfree = 0; /* big free blocks die with their slabs */
  if (pool->buckets)
    for (int i = 0; i < FPR_NBUCKETS; i++) pool->buckets[i] = 0;
  fpr_unlock(&arc_lock);
  return (V)&fpr_unit;
}
FPR_FN(fpr_g_Sys_x2epoolReset, g_poolReset, 1);
void fpr_pool_reset_c(void) { g_poolReset((V)&fpr_unit); }
uw fpr_arc_live_count(void) { return arc_live; }

/* sendArc's promotion (actors.c): count = HOLDERS.  A value with no
 * entry yet gains one at count 1 -- the SENDER's standing share, since
 * the sender keeps using what it shared -- and every send adds the
 * receiver's share on top.  A message root (already counted once for
 * its current holder) just gains the receiver's.  Every holder
 * releases with `drop`; the last drop reclaims exactly as today.
 * First promotion of a pool value pins its slab (escaped++), so the
 * shared object outlives the sender's poolReset/death by the existing
 * orphan machinery.  This is the v1 mechanism; the mailbox-serialized
 * ARC.qa (docs/MEMORY-V2-PLAN.md phase 4) replaces the table+lock
 * underneath without changing this contract. */
void fpr_arc_promote_share(V v) {
  if (fpr_sched) { fpr_sched->arc_incref(v); return; }
  if (arc_by_value(v)) return; /* ints, immortal statics, handles: by value */
  arc_reserve(); /* the next table, if one is due, before the lock */
  fpr_lock(&arc_lock);
  int found;
  uw i = arc_slot_for(v, &found);
  if (!found) {
    arct[i].ptr = v;
    arct[i].cnt = 1; /* the sender's standing share */
    arc_live++;
    fpr_slab_t *sl = slab_of(v);
    if (sl) sl->escaped++;
  }
  arct[i].cnt++; /* the receiver's share */
  fpr_unlock(&arc_lock);
}

/* is v a TRACKED message root living in an ownerless slab?  The exact
 * precondition for sendLinear's zero-copy transfer (actors.c): such a
 * root carries the ONE standing ARC count for its slab, so handing the
 * pointer to another actor hands the count with it -- no copy, no
 * incref, and the receiver's ordinary drop parks the slab as ever.
 * Anything else (a local value, a CHILD of a still-held message)
 * fails here and takes the copy path -- a child's slab lifetime
 * belongs to its parent root, never to a forwarded pointer. */
int fpr_arc_movable_root(V v) {
  if (fpr_sched) return 0; /* shared plane: conservative copy path */
  if (!fpr_in_heap(v) || ISINT(v)) return 0;
  if (TID(v) == T_ACTOR) return 0; /* handles: no preheader, share raw */
  fpr_slab_t *sl = slab_of(v);
  if (!sl || sl->owner) return 0;
  fpr_lock(&arc_lock);
  int found;
  arc_probe(v, &found);
  fpr_unlock(&arc_lock);
  return found;
}

/* ---- Sys.sleepUs lives in actors.c now: a PARKED sleep.  This hook is
 * its fallback where there is no actor to park (a hart-loop context)
 * or no clock: the host sleeps the thread (qosp's syscall 6); the weak
 * default returns 0, a no-op. */
__attribute__((weak)) int fpr_hal_sleep_us(uw us) { (void)us; return 0; }

uw fpr_arc_live(void) { return arc_live; }

/* the CURRENT ACTOR's allocation gauge: bytes it has ever bumped from
 * its slabs (recycled-bucket hits do not re-count).  The per-hart
 * high-water mark died with the arenas; "what has THIS actor cost"
 * is the question the slab model can actually answer. */
static V g_heapUsed(V d) {
  (void)d;
  fpr_hart_t *h = fpr_hart();
  fpr_pool_t *pool = h->current ? fpr_acb_pool(h->current) : &h->pool;
  return TAG((sw)pool->allocated);
}

static V g_drop(V v) { fpr_arc_decref(v); return (V)&fpr_unit; }

/* substr s off len -- 1-indexed byte slice, clamped. Mechanism, not
 * policy: diskfs chunks payloads into pages (write) and takes the used
 * prefix of a page (read) with this; doing it via chr+strcat would be
 * one allocation PER BYTE of every page moved. */
static V g_substr(V sv, V off, V len) {
  if (ISINT(sv) || TID(sv) != T_STR) fpr_cpanic("substr: not a String");
  str_t *s = (str_t *)sv;
  sw o = UNTAG(off), l = UNTAG(len);
  if (o < 1) o = 1;
  if (l < 0) l = 0;
  if ((uw)(o - 1) >= s->len) { o = 1; l = 0; }
  if ((uw)l > s->len - (uw)(o - 1)) l = (sw)(s->len - (uw)(o - 1));
  return (V)fpr_mkstr(s->bytes + (o - 1), (uw)l);
}
static V g_arcLive(V d) {
  (void)d;
  if (fpr_sched) return TAG((sw)fpr_sched->arc_live());
  return TAG(fpr_arc_live());
}



/* ---- panic ---------------------------------------------------------- */
/* The core writes '\n' and nothing else.  Whether a line also needs a
 * carriage return is a fact about the DEVICE -- a raw 16550 does, a posix
 * stream does not -- so it is hal_putc's to add (hal/virt, hal/builtin).
 * It used to be inserted here, which made every hosted program's stdout
 * CRLF and every check pipe its output through `tr -d '\r'`. */
static void praw(const char *s) {
  while (*s) hal_putc(*s++);
}

extern uw fpr_current_id(void);
static void pdec(uw u) {
  char b[24]; int i = 23;
  if (u == 0) b[i--] = '0';
  while (u) { b[i--] = '0' + (u % 10); u /= 10; }
  for (int j = i + 1; j <= 23; j++) hal_putc(b[j]);
}
void fpr_logput(int sev, const char *b, uw n);
/* #24: last-words persistence.  A hosted target (qosp via entry.c)
 * points this at its storage syscall, so a crash-restart loop stops
 * destroying its own evidence: the record lands as "sys/panic\n<msg>"
 * in the append-only kv log, visible to Disk.qa on the next boot.
 * NULL everywhere else -- a machine boot cannot run the storage
 * actor's RPC from panic context, and honesty beats a fake hook. */
void (*fpr_panic_persist)(const char *msg, uw n);
#ifndef FPR_BUILTIN
void fpr_cpanic(const char *m) {
  static int in_panic;
  if (!in_panic) {
    in_panic = 1;
    uw n = 0;
    while (m[n]) n++;
    fpr_logput(2, m, n); /* the error ring keeps the last words */
    if (fpr_panic_persist) fpr_panic_persist(m, n);
  }
  praw("\n*** FPRISC PANIC [actor ");
  pdec(fpr_current_id());
  praw("]: ");
  praw(m);
  praw(" ***\n");
  hal_poweroff(1); /* QEMU: exit 1; real HW: no-op, park below */
  for (;;) FPR_PARK();
}

#endif

/* the `error` builtin's V-taking twin: funnel through fpr_cpanic so a
 * user-level panic reaches the error ring and the persist hook exactly
 * like a runtime one (it previously printed raw and died -- last words
 * that never made /logs/errors). */
void fpr_panic(V s) {
  static char pbuf[160];
  if (!ISINT(s) && TID(s) == T_STR) {
    str_t *t = (str_t *)s;
    uw n = t->len < sizeof pbuf - 1 ? t->len : sizeof pbuf - 1;
    for (uw i = 0; i < n; i++) pbuf[i] = (char)t->bytes[i];
    pbuf[n] = 0;
    fpr_cpanic(pbuf);
  }
  fpr_cpanic("panic (non-string value)");
}

volatile uint32_t fpr_shutdown; /* hart loops park when set */

void fpr_exit(V result) {
  extern void fpr_render_to_uart(V v); /* below */
  __atomic_store_n(&fpr_shutdown, 1, __ATOMIC_RELEASE);
#if defined(FPR_POSIX) && !defined(FPR_QOSAPP)
  /* the Base profile (hal/posix): an ordinary process.  Nothing is
   * echoed; main's Int result is the exit status (0..255), any other
   * result exits 0.  Sys.exit is the early way out. */
  hal_poweroff(ISINT(result) ? (int)(UNTAG(result) & 255) : 0);
#else
  praw("\n[fpr] main => ");
  fpr_render_to_uart(result);
  praw("\n");
  hal_poweroff(0); /* QEMU: clean exit 0; real HW: no-op, park below */
#endif
  for (;;) FPR_PARK();
}

/* ---- generic apply --------------------------------------------------- */
/* A function value is a PAP: code addr + arity + args collected so far.
 * Saturation calls through an arity-dispatched cast; otherwise we copy
 * the PAP with one more arg (PAPs are immutable -- statics get shared). */
typedef V (*F1)(V);
typedef V (*F2)(V, V);
typedef V (*F3)(V, V, V);
typedef V (*F4)(V, V, V, V);
typedef V (*F5)(V, V, V, V, V);
typedef V (*F6)(V, V, V, V, V, V);
typedef V (*F7)(V, V, V, V, V, V, V);
typedef V (*F8)(V, V, V, V, V, V, V, V);

static V callf(uw fn, uw ar, V *a) {
  switch (ar) {
    case 1: return ((F1)fn)(a[0]);
    case 2: return ((F2)fn)(a[0], a[1]);
    case 3: return ((F3)fn)(a[0], a[1], a[2]);
    case 4: return ((F4)fn)(a[0], a[1], a[2], a[3]);
    case 5: return ((F5)fn)(a[0], a[1], a[2], a[3], a[4]);
    case 6: return ((F6)fn)(a[0], a[1], a[2], a[3], a[4], a[5]);
#if defined(FPR_POSIX) && defined(__x86_64__)
    /* x64 lowering convention: args 7/8 travel in TLS cells, not SysV
     * stack slots -- that keeps generated tail calls to arity-7/8
     * functions plain jmps (TCO intact).  This C boundary fills the
     * cells and calls through the 6-register cast; the lowered callee
     * reads the cells in its prologue (see compiler/X64.hs). */
    case 7: {
#ifndef FPR_QOSAPP
      extern FPR_TLS uw fpr_x64_a6;
#endif
      fpr_x64_a6 = (uw)a[6];
      return ((F6)fn)(a[0], a[1], a[2], a[3], a[4], a[5]);
    }
    case 8: {
#ifndef FPR_QOSAPP
      extern FPR_TLS uw fpr_x64_a6, fpr_x64_a7;
#endif
      fpr_x64_a6 = (uw)a[6];
      fpr_x64_a7 = (uw)a[7];
      return ((F6)fn)(a[0], a[1], a[2], a[3], a[4], a[5]);
    }
#else
    case 7: return ((F7)fn)(a[0], a[1], a[2], a[3], a[4], a[5], a[6]);
    case 8: return ((F8)fn)(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]);
#endif
  }
  /* WIDE ARITY (9..8+FPR_ARGSPILL): args 8+ travel in the caller's
   * hart argspill cells -- the same convention generated call sites
   * use, so a lowered wide callee reads them in its prologue exactly
   * as if a generated caller had stored them.  Safe here for the same
   * reason it is safe there: nothing between these stores and the
   * call is a safepoint, and the callee copies the cells into its
   * frame before its fuel check. */
  if (ar > 8 && ar <= 8 + FPR_ARGSPILL) {
    fpr_hart_t *h = fpr_hart();
    for (uw i = 8; i < ar; i++) h->argspill[i - 8] = (sw)a[i];
#if defined(FPR_POSIX) && defined(__x86_64__)
#ifndef FPR_QOSAPP
    extern FPR_TLS uw fpr_x64_a6, fpr_x64_a7;
#endif
    fpr_x64_a6 = (uw)a[6];
    fpr_x64_a7 = (uw)a[7];
    return ((F6)fn)(a[0], a[1], a[2], a[3], a[4], a[5]);
#else
    return ((F8)fn)(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]);
#endif
  }
  fpr_cpanic("apply: arity > 24");
}

V fpr_apply(V f, V a) {
  if (ISINT(f)) fpr_cpanic("apply: applied an integer");
  pap_t *p = (pap_t *)f;
  if (p->tid != T_PAP) fpr_cpanic("apply: not a function value");
  uw n = p->nargs;
  if (n + 1 == p->arity) {
    V args[8 + FPR_ARGSPILL];
    for (uw i = 0; i < n; i++) args[i] = p->args[i];
    args[n] = a;
    return callf(p->fn, p->arity, args);
  }
  pap_t *q = (pap_t *)fpr_alloc(sizeof(pap_t) + p->arity * sizeof(V));
  q->tid = T_PAP;
  q->var = 0;
  q->fn = p->fn;
  q->arity = p->arity;
  q->nargs = n + 1;
  for (uw i = 0; i < n; i++) q->args[i] = p->args[i];
  q->args[n] = a;
  return (V)q;
}

/* whole-spine application: rargs points at the LAST argument, with each
 * argument 16 bytes apart going UP (the codegen push discipline).
 * Saturating allocates nothing; under-saturation builds exactly ONE
 * pap; over-saturation loops.  This is why a tight FPRISC loop over
 * 2-ary HAL prims (charAt in strEq in hasCap in svcPollKey) allocates
 * zero bytes instead of a 48-byte PAP per argument. */
V fpr_applyN(V f, uw n, V *rargs) {
#define RARG(i) (rargs[(16 / sizeof(uw)) * (n - 1 - (i))]) /* 16-byte push stride */
  for (;;) {
    if (ISINT(f)) fpr_cpanic("apply: applied an integer");
    pap_t *p = (pap_t *)f;
    if (p->tid != T_PAP) fpr_cpanic("apply: not a function value");
    uw have = p->nargs, need = p->arity - have;
    if (n < need) { /* still partial: ONE pap with everything so far */
      pap_t *q = (pap_t *)fpr_alloc(sizeof(pap_t) + p->arity * sizeof(V));
      q->tid = T_PAP;
      q->var = 0;
      q->fn = p->fn;
      q->arity = p->arity;
      q->nargs = have + n;
      for (uw i = 0; i < have; i++) q->args[i] = p->args[i];
      for (uw i = 0; i < n; i++) q->args[have + i] = RARG(i);
      return (V)q;
    }
    V args[8 + FPR_ARGSPILL];
    for (uw i = 0; i < have; i++) args[i] = p->args[i];
    for (uw i = 0; i < need; i++) args[have + i] = RARG(i);
    V r = callf(p->fn, p->arity, args);
    if (n == need) return r;
    /* over-saturated: the result must itself be applicable */
    n -= need;
    // could (void) to silence
    rargs = rargs; /* remaining logical args are 0..n-1: same base */
    f = r;
  }
#undef RARG
}

static V g_sys_harts(V d) { (void)d; return TAG((sw)fpr_live_harts); }
FPR_FN(fpr_g_Sys_x2eharts, g_sys_harts, 1);

/* builtin Result constructors for C-side service code */
V fpr_mkresultn(uw variant, const char *s, uw n) {
  hdr_t *h = (hdr_t *)fpr_alloc(8 + sizeof(uw));
  h->tid = T_RESULT;
  h->var = (uint32_t)variant;
  *(V *)((char *)h + 8) = (V)fpr_mkstr((const uint8_t *)s, n);
  return (V)h;
}
V fpr_mkresult(uw variant, const char *s) {
  uw n = 0;
  while (s[n]) n++;
  return fpr_mkresultn(variant, s, n);
}

/* ---- strings --------------------------------------------------------- */
str_t *fpr_mkstr(const uint8_t *src, uw n) {
  str_t *s = (str_t *)fpr_alloc(sizeof(str_t) + n);
  s->tid = T_STR;
  s->var = 0;
  s->len = n;
  for (uw i = 0; i < n; i++) s->bytes[i] = src[i];
  return s;
}

/* ---- core prims ------------------------------------------------------ */
V fpr_prim_fn__x2b(V a, V b) { return TAG(UNTAG(a) + UNTAG(b)); }
V fpr_prim_fn__x2d(V a, V b) { return TAG(UNTAG(a) - UNTAG(b)); }
V fpr_prim_fn__x2a(V a, V b) { return TAG(UNTAG(a) * UNTAG(b)); }
V fpr_prim_fn__x2f(V a, V b) {
  if (UNTAG(b) == 0) fpr_cpanic("division by zero");
  return TAG(UNTAG(a) / UNTAG(b));
}
V fpr_prim_fn__x3c(V a, V b) { return BOOL(UNTAG(a) < UNTAG(b)); }
V fpr_prim_fn__x3e(V a, V b) { return BOOL(UNTAG(a) > UNTAG(b)); }
V fpr_prim_fn__x3c_x3d(V a, V b) { return BOOL(UNTAG(a) <= UNTAG(b)); }
V fpr_prim_fn__x3e_x3d(V a, V b) { return BOOL(UNTAG(a) >= UNTAG(b)); }

/* == : ints by value, strings by content, and DEEP over the fields of
 * lists, tuples, constructors and records.
 *
 * This used to stop at the header ("enough for bools/units/nullary
 * tags"), on the stated grounds that deep equality needs per-type field
 * counts.  It does -- and the allocation header has carried them all
 * along: the deep copier derives a cell's field count from its total
 * size (dc_size's default arm), so equality derives it the same way.
 * The old behaviour was not a missing feature but a WRONG ANSWER:
 * `(1, 2) == (3, 4)` and `[1, 2] == [3, 4]` were both True, because two
 * tuples share a tid and a var, and nothing else was read.  Every
 * program comparing structured values was silently wrong.
 *
 * The rules, in order:
 *   ints            by value
 *   same pointer    equal (and the cheap exit for shared structure)
 *   tid/var differ  not equal
 *   String          by content
 *   opaque/bulk     by IDENTITY -- a Vector is linear and an actor
 *                   handle, PAP, device or register is a thing, not a
 *                   value; walking their innards is meaningless
 *   anything else   field by field, when BOTH sides carry an allocation
 *                   preheader.  A static literal has no preheader (its
 *                   size is not recorded), so two statics keep the old
 *                   header-only answer rather than a wild read.
 * There is NO depth cap.  The first deep `==` recursed per field and
 * answered "equal" at depth 64 as a cycle guard -- so two lists that
 * differed only past their 64th element compared True, with no error
 * anywhere.  The walk is a worklist now: fields are pushed last-first so
 * they pop in order, which keeps a list of ANY length at two pending
 * pairs, and a structure nested deeply through a non-final field moves
 * the worklist from the C stack to a heap block that doubles.  The bound
 * is memory, and running out of it is the allocator's named panic, never
 * a wrong answer.  (Nothing in the language builds a cyclic value; if
 * that changes, the guard belongs here as a panic, not as a `True`.) */
#define VEQ_INLINE 32 /* pending pairs on the C stack before the heap block */
typedef struct { V a, b; } veq_pair_t;
#ifdef FPR_BUILTIN_RAW
extern uw fpr_builtin_field_count(V);
extern char fpr_builtin_field_kind(V,uw);
#endif
/* one pair, without descending: 0 differ, 1 equal, 2 compare the fields */
static int veq_shallow(V a, V b) {
  if (ISINT(a) || ISINT(b)) return a == b;
  if (a == b) {
#ifdef FPR_BUILTIN_RAW
    /* A shared ADT may contain NaN, so identity cannot skip numeric equality. */
    if (!fpr_in_heap(a) || !fpr_builtin_field_count(a)) return 1;
#else
    return 1;
#endif
  }
  if (!a || !b) return 0;
  hdr_t *x = (hdr_t *)a, *y = (hdr_t *)b;
  if (x->tid != y->tid || x->var != y->var) return 0;
  if (x->tid == T_STR) {
    str_t *s = (str_t *)a, *t = (str_t *)b;
    if (s->len != t->len) return 0;
    for (uw i = 0; i < s->len; i++)
      if (s->bytes[i] != t->bytes[i]) return 0;
    return 1;
  }
  if (x->tid == T_BITS && (x->var == 2 || x->var == 3))
    return ((bits_t *)a)->val == ((bits_t *)b)->val;
  switch (x->tid) {
    case T_VEC: case T_ACTOR: case T_PAP:
    case T_DEVICE: case T_REGISTER: case T_BITS: case T_SSTR:
      return 0; /* identity only, and a == b was already taken above */
    default: break;
  }
  if (!fpr_in_heap(a) || !fpr_in_heap(b)) return 1; /* statics: no counts */
  return 2;
}
static int veq(V a0, V b0) {
  veq_pair_t inl[VEQ_INLINE], *st = inl;
  uw n = 0, cap = VEQ_INLINE;
  V spill = 0; /* the worklist once it outgrows inl: an fpr_alloc block */
  int eq = 1;
  st[n++] = (veq_pair_t){a0, b0};
  while (n) {
    V a = st[n - 1].a, b = st[n - 1].b;
    n--;
    int r = veq_shallow(a, b);
    if (r == 0) { eq = 0; break; }
    if (r == 1) continue;
#ifdef FPR_BUILTIN_RAW
    uw nf = fpr_builtin_field_count(a);
    if (nf != fpr_builtin_field_count(b)) { eq = 0; break; }
#else
    uw ta = *(uw *)((char *)a - 16), tb = *(uw *)((char *)b - 16);
    if (ta != tb) { eq = 0; break; }
    if (ta < 24) continue;
    uw nf = (ta - 16 - 8) / sizeof(uw);
#endif
    if (n + nf > cap) {
      uw ncap = cap;
      while (n + nf > ncap) ncap *= 2;
      if (spill) spill = fpr_realloc(spill, (V)(ncap * sizeof(veq_pair_t)));
      else {
        spill = fpr_alloc((V)(ncap * sizeof(veq_pair_t)));
        for (uw i = 0; i < n; i++) ((veq_pair_t *)spill)[i] = inl[i];
      }
      st = (veq_pair_t *)spill;
      cap = ncap;
    }
    V *fa = (V *)((char *)a + 8), *fb = (V *)((char *)b + 8);
    for (uw i = nf; i-- > 0;) { /* last first, so field 0 pops first */
#ifdef FPR_BUILTIN_RAW
      char k = fpr_builtin_field_kind(a, i);
      if (k != fpr_builtin_field_kind(b, i)) { eq = 0; goto done; }
      if (k == 'd') { union { V u; double d; } x = {fa[i]}, y = {fb[i]}; if (x.d != y.d) { eq = 0; goto done; } continue; }
      if (k == 'f') { union { uint32_t u; float f; } x = {(uint32_t)fa[i]}, y = {(uint32_t)fb[i]}; if (x.f != y.f) { eq = 0; goto done; } continue; }
      if (k != 't') { if (fa[i] != fb[i]) { eq = 0; goto done; } continue; }
#endif
      if (ISINT(fa[i]) || ISINT(fb[i])) { /* the common leaf: no push */
        if (fa[i] != fb[i]) { eq = 0; goto done; }
        continue;
      }
      st[n++] = (veq_pair_t){fa[i], fb[i]};
    }
  }
done:
  if (spill) fpr_free(spill);
  return eq;
}
V fpr_prim_fn__x3d_x3d(V a, V b) { return BOOL(veq(a, b)); }
V fpr_prim_fn__x21_x3d(V a, V b) { return BOOL(!veq(a, b)); }

/* ---- render: matches the host evaluator's `render` output ----------- */
/* Lists "[1, 2]", atoms ":done", bools, unit "()", tuples via the
 * generic "<t.v fields>" form for known-arity builtins, bare "<t.v>"
 * for user types and record shapes (no field counts in headers yet). */
/* render buffers are PER HART (fpr_hart_t.rbuf): `str` and string
 * interpolation run concurrently on different harts. */
#define rbuf (fpr_hart()->rbuf)
#define rpos (fpr_hart()->rpos)
/* Overflow used to be SILENT: `if (rpos < CAP) ...` dropped every
 * character past 4095 and returned a short string, so a large
 * interpolation ("{bigString}") produced a truncated page with no
 * error anywhere -- valid HTML, cut mid-token. Renders are bounded by
 * design (this buffer is per-hart and fixed), so overflowing it is a
 * program error and says so. The common case that USED to hit this --
 * interpolating a value that is already a String -- no longer routes
 * through the buffer at all; see fpr_prim_fn_str. */
static void remit(char c) {
  if (rpos >= FPR_RBUF_SZ - 1)
    fpr_cpanic("str/print: render buffer full (4096B) -- build large "
               "strings with strcat, not interpolation");
  rbuf[rpos++] = c;
}
static void remits(const char *s) { while (*s) remit(*s++); }
static void rdec(sw n) {
  char b[24];
  int i = 23;
  int neg = n < 0;
  uw u = neg ? (uw)0 - (uw)n : (uw)n;
  if (u == 0) b[i--] = '0';
  while (u) { b[i--] = '0' + (u % 10); u /= 10; }
  if (neg) b[i--] = '-';
  for (int j = i + 1; j <= 23; j++) remit(b[j]);
}
static void render(V v);
#ifdef FPR_BUILTIN_RAW
static uw dtoa(char *,double,int);
#endif
static void renderField(V obj,uw i) {
  V v=((V *)(obj+8))[i];
#ifdef FPR_BUILTIN_RAW
  char k=fpr_in_heap(obj)?fpr_builtin_field_kind(obj,i):'t';
  if(k=='w'||k=='a') { rdec((sw)v); return; }
  if(k=='d'||k=='f') {
    union { V u; double d; } d={v}; union { uint32_t u; float f; } f={(uint32_t)v};
    char b[40]; uw n=dtoa(b,k=='d'?d.d:(double)f.f,k=='d'?15:7);
    for(uw j=0;j<n;j++)remit(b[j]);
    return;
  }
#endif
  render(v);
}
static void rfields(V obj, int n) { /* "<t.v f1 f2>" tail */
  for (int i = 0; i < n; i++) { remit(' '); renderField(obj,i); }
}
static void render(V v) {
  if (ISINT(v)) { rdec(UNTAG(v)); return; }
  hdr_t *h = (hdr_t *)v;
  switch (h->tid) {
    case T_STR: {
      str_t *s = (str_t *)v;
      for (uw i = 0; i < s->len; i++) remit((char)s->bytes[i]);
      break;
    }
    case T_BOOL: remits(h->var ? "True" : "False"); break;
    case T_UNIT: remits("()"); break;
    case T_ATOM: remit(':'); renderField(v,0); break;
    case T_LIST:
      if (h->var == 0) { remits("[]"); break; }
      remit('[');
      for (V c = v;;) {
        V *cf = (V *)((char *)c + 8);
        renderField(c,0);
        c = cf[1];
        if (ISINT(c) || ((hdr_t *)c)->tid != T_LIST || ((hdr_t *)c)->var != 1) break;
        remits(", ");
      }
      remit(']');
      break;
    case T_RESULT: remits("<3."); rdec(h->var); rfields(v, 1); remit('>'); break;
    case T_TUP2:
      remit('('); renderField(v,0); remits(", "); renderField(v,1); remit(')');
      break;
    case T_TUP3:
      remit('('); renderField(v,0); remits(", "); renderField(v,1); remits(", ");
      renderField(v,2); remit(')');
      break;
    case T_TUP4: case T_TUP5: case T_TUP6: case T_TUP7: case T_TUP8: {
      uw ta = 4 + (h->tid - T_TUP4);
      remit('(');
      for (uw i = 0; i < ta; i++) { if (i) remits(", "); renderField(v,i); }
      remit(')');
      break;
    }
    case T_BITS: rdec((sw)((bits_t *)v)->val); break;
    case T_PAP: remits("<fn>"); break;
    default: remit('<'); rdec(h->tid); remit('.'); rdec(h->var); remit('>'); break;
  }
}

V fpr_prim_fn_str(V v) {
  /* a String renders as itself: return it unchanged rather than
   * copying it through the fixed render buffer. This is what makes
   * "{s}" safe for strings of any size (and it saves the copy). */
  if (!ISINT(v) && TID(v) == T_STR) return v;
  rpos = 0;
  render(v);
  return (V)fpr_mkstr((const uint8_t *)rbuf, (uw)rpos);
}

fpr_lock_t fpr_con_lock; /* console: one LINE at a time across harts */

/* ---- the /logs substrate: three severity rings ----------------------
 * The `log` family lands HERE, in C-owned storage: LOG_N lines of
 * LOG_W bytes per severity (0 normal, 1 warn, 2 error), copied at
 * write.  C ownership is the point -- snapshots hand out fresh copies
 * in the CALLER's pool, so no cross-actor lifetime exists at all (the
 * copy-on-retain and live-state lessons, designed away).  fpr_cpanic
 * appends the panic text to the error ring first, so a post-mortem
 * Logs screen -- or gdb -- can read the last words. */
#define LOG_SEVS 4 /* 0 normal, 1 warn, 2 error, 3 HOST (qos_hostlog) */
#define LOG_N 16
#define LOG_W 96
static char log_ring[LOG_SEVS][LOG_N][LOG_W];
static uw log_seq[LOG_SEVS]; /* total ever; head = seq % LOG_N */
static fpr_lock_t log_lock;

/* #25: the console echo is rate-limited BY SEQUENCE, not by time
 * (runtime.c has no clock): 16 echoes per 64 ring writes.  At human
 * rates everything echoes; a frame-worker storm gets a bounded 25%
 * plus one honest summary line when suppression ends.  The RINGS are
 * never limited -- /logs/* always holds everything. */
#define ECHO_WIN 64
#define ECHO_ALLOW 16
static uw echo_win_base, echo_used, echo_suppressed;

void fpr_logput(int sev, const char *b, uw n) {
  if (sev < 0) sev = 0;
  if (sev >= LOG_SEVS) sev = LOG_SEVS - 1;
  if (n >= LOG_W) n = LOG_W - 1;
  uw do_echo, supp_note = 0, total;
  fpr_lock(&log_lock);
  char *dst = log_ring[sev][log_seq[sev] % LOG_N];
  for (uw i = 0; i < n; i++) dst[i] = b[i];
  dst[n] = 0;
  log_seq[sev]++;
  total = log_seq[0] + log_seq[1] + log_seq[2] + log_seq[3];
  if (total - echo_win_base >= ECHO_WIN) { echo_win_base = total; echo_used = 0; }
  do_echo = echo_used < ECHO_ALLOW;
  if (do_echo) {
    echo_used++;
    if (echo_suppressed) { supp_note = echo_suppressed; echo_suppressed = 0; }
  } else echo_suppressed++;
  fpr_unlock(&log_lock);
  if (!do_echo) return;
  /* echo, prefixed -- the console remains the zeroth debugging tool */
  static const char *pre[LOG_SEVS] = {"[log] ", "[warn] ", "[ERR] ", "[host] "};
  fpr_lock(&fpr_con_lock);
  if (supp_note) {
    const char *s = "[log] (console echo suppressed ";
    for (const char *c = s; *c; c++) hal_putc(*c);
    char db[24]; int di = 23; uw u = supp_note;
    if (u == 0) db[di--] = '0';
    while (u) { db[di--] = '0' + (u % 10); u /= 10; }
    for (int j = di + 1; j <= 23; j++) hal_putc(db[j]);
    s = " line(s); rings intact)\n";
    for (const char *c = s; *c; c++) hal_putc(*c);
  }
  for (const char *c = pre[sev]; *c; c++) hal_putc(*c);
  for (uw i = 0; i < n; i++) hal_putc(b[i]);
  hal_putc('\n');
  fpr_unlock(&fpr_con_lock);
}

static V g_logAt(V sevv, V sv) {
  if (ISINT(sv) || TID(sv) != T_STR) fpr_cpanic("log: not a string");
  str_t *t = (str_t *)sv;
  fpr_logput((int)UNTAG(sevv), (const char *)t->bytes, t->len);
  return (V)&fpr_unit;
}
static V g_log(V sv) { return g_logAt(TAG(0), sv); }
static V g_logW(V sv) { return g_logAt(TAG(1), sv); }
static V g_logE(V sv) { return g_logAt(TAG(2), sv); }
static V g_logSeq(V sevv) {
  sw sev = UNTAG(sevv);
  if (sev < 0 || sev >= LOG_SEVS) return TAG(0);
  return TAG((sw)log_seq[sev]);
}
/* newest-first list of fresh string COPIES in the caller's pool */
static V g_logSnap(V sevv) {
  sw sev = UNTAG(sevv);
  if (sev < 0 || sev >= LOG_SEVS) sev = 0;
  fpr_lock(&log_lock);
  uw have = log_seq[sev] < LOG_N ? log_seq[sev] : LOG_N;
  hdr_t *nil = (hdr_t *)fpr_alloc(8);
  nil->tid = T_LIST;
  nil->var = 0;
  V list = (V)nil;
  /* build oldest -> newest by consing, so the head is newest */
  for (uw i = 0; i < have; i++) {
    const char *line = log_ring[sev][(log_seq[sev] - have + i) % LOG_N];
    uw n = 0;
    while (line[n]) n++;
    V str = (V)fpr_mkstr((const uint8_t *)line, n);
    V *cell = (V *)fpr_alloc(24);
    ((hdr_t *)cell)->tid = T_LIST;
    ((hdr_t *)cell)->var = 1;
    cell[1] = str;
    cell[2] = list;
    list = (V)cell;
  }
  fpr_unlock(&log_lock);
  return list;
}
FPR_FN(fpr_g_log, g_log, 1);
FPR_FN(fpr_g_logWarn, g_logW, 1);
FPR_FN(fpr_g_logErr, g_logE, 1);
FPR_FN(fpr_g_Sys_x2elogAt, g_logAt, 2);
FPR_FN(fpr_g_Sys_x2elogSeq, g_logSeq, 1);
FPR_FN(fpr_g_Sys_x2elogSnap, g_logSnap, 1);

/* Sys.memStats () -> (grows, mib): the arena growth ledger */
static V g_memstats(V u) {
  (void)u;
  V *t = (V *)fpr_alloc(24);
  ((hdr_t *)t)->tid = 4; /* Tup2 */
  ((hdr_t *)t)->var = 0;
  t[1] = TAG((sw)fpr_grow_count);
  t[2] = TAG((sw)(fpr_grow_bytes >> 20));
  return (V)t;
}
FPR_FN(fpr_g_Sys_x2ememStats, g_memstats, 1);

/* Sys.memInfo () -> [arenaKiB, freeKiB, requests, waits, direct,
 * frees, denied, inline]: the memory actor's ledger (fpr.h).  arena
 * and free are the buddy's own numbers (0 without a buddy: a loaded
 * process on grants); requests/waits count takes queued on the actor
 * and how often one had to park; direct counts the takes that
 * bypassed it with no actor to park (boot, the reaper, the actor
 * itself); inline counts the takes served on the spot because the
 * buddy was uncontended. */
static V g_meminfo(V u) {
  (void)u;
  /* build the cells FIRST: the list itself may be the caller's first
   * allocation, and the numbers should include the slab that costs */
  hdr_t *nil = (hdr_t *)fpr_alloc(8);
  nil->tid = T_LIST;
  nil->var = 0;
  V list = (V)nil;
  V *cells[8];
  for (int i = 7; i >= 0; i--) {
    V *cell = (V *)fpr_alloc(24);
    ((hdr_t *)cell)->tid = T_LIST;
    ((hdr_t *)cell)->var = 1;
    cell[2] = list;
    list = (V)cell;
    cells[i] = cell;
  }
  uw vals[8] = {fpr_mem_own ? buddy_arena_size() >> 10 : 0,
                fpr_mem_own ? buddy_free_bytes() >> 10 : 0,
                fpr_mem_reqs, fpr_mem_waits, fpr_mem_direct, fpr_mem_frees,
                fpr_mem_denied, fpr_mem_inline};
  for (int i = 0; i < 8; i++) cells[i][1] = TAG((sw)vals[i]);
  return list;
}
FPR_FN(fpr_g_Sys_x2ememInfo, g_meminfo, 1);

/* Sys.growLog () -> newest-first list of formatted grow events (fresh
 * copies in the caller's pool). The ring
 * write above is lock-free at the allocation site; formatting and
 * allocation happen HERE, in ordinary code the caller runs.  A torn
 * slot (seq changed while copying) is skipped rather than lied about. */
static V g_growlog(V u) {
  (void)u;
  hdr_t *nil = (hdr_t *)fpr_alloc(8);
  nil->tid = T_LIST;
  nil->var = 0;
  V list = (V)nil;
  uw newest = __atomic_load_n(&growlog_seq, __ATOMIC_ACQUIRE);
  uw have = newest < GROWLOG_N ? newest : GROWLOG_N;
  /* build oldest -> newest by consing, so the head is newest */
  for (uw s = newest - have; s < newest; s++) {
    growev_t *e = &growlog[s % GROWLOG_N];
    uw seq1 = __atomic_load_n(&e->seq, __ATOMIC_ACQUIRE);
    growev_t c = *e;
    uw seq2 = __atomic_load_n(&e->seq, __ATOMIC_ACQUIRE);
    if (seq1 != s + 1 || seq2 != s + 1) continue; /* torn or overwritten */
    char line[96];
    int p = 0;
    const char *fmt[] = {"#", " ", " a", " want ", "K got ", "K"};
    const char *nm = fpr_growsite_name(c.site);
    /* "#<seq> <site> a<actor> want <K>K got <K>K" -- freestanding fmt */
    uw vals[] = {c.seq, 0, c.actor, c.want >> 10, c.got >> 10, 0};
    for (int i = 0; i < 6; i++) {
      for (const char *t = fmt[i]; *t && p < 90; t++) line[p++] = *t;
      if (i == 1) {
        for (const char *t = nm; *t && p < 90; t++) line[p++] = *t;
        continue;
      }
      if (i == 5) break;
      char d[24];
      int di = 23;
      uw v = vals[i];
      if (v == 0) d[di--] = '0';
      while (v && di >= 0) { d[di--] = '0' + (v % 10); v /= 10; }
      for (int j = di + 1; j <= 23 && p < 90; j++) line[p++] = d[j];
    }
    V str = (V)fpr_mkstr((const uint8_t *)line, (uw)p);
    V *cell = (V *)fpr_alloc(24);
    ((hdr_t *)cell)->tid = T_LIST;
    ((hdr_t *)cell)->var = 1;
    cell[1] = str;
    cell[2] = list;
    list = (V)cell;
  }
  return list;
}
FPR_FN(fpr_g_Sys_x2egrowLog, g_growlog, 1);

V fpr_prim_fn_print(V v) {
  /* a String prints as itself, straight to the console: like `str`, it
   * never enters the fixed render buffer, so a string of ANY length
   * prints.  (It used to panic "render buffer full" past 4095 bytes.) */
  const char *out;
  uw n;
  if (!ISINT(v) && TID(v) == T_STR) {
    out = (const char *)((str_t *)v)->bytes;
    n = ((str_t *)v)->len;
  } else {
    rpos = 0;
    render(v);
    out = rbuf;
    n = (uw)rpos;
  }
  fpr_lock(&fpr_con_lock);
  for (uw i = 0; i < n; i++) hal_putc(out[i]);
  hal_putc('\n');
  fpr_unlock(&fpr_con_lock);
  return (V)&fpr_unit;
}

/* String.len -- mangled: '.' = _x2e */
V fpr_prim_fn_String_x2elen(V s) {
  str_t *t = (str_t *)s;
  if (ISINT(s) || t->tid != T_STR) fpr_cpanic("String.len: not a string");
  return TAG(t->len);
}

/* ! : list lookup, 1-indexed */
V fpr_prim_fn__x21(V xs, V iv) {
  sw i = UNTAG(iv);
  V c = xs;
  for (;;) {
    if (ISINT(c) || TID(c) != T_LIST || ((hdr_t *)c)->var != 1)
      fpr_cpanic("!: index out of range");
    V *f = (V *)((char *)c + 8);
    if (i == 1) return f[0];
    c = f[1];
    i--;
  }
}

V fpr_prim_fn_strcat(V a, V b) {
  str_t *x = (str_t *)a, *y = (str_t *)b;
  if (ISINT(a) || ISINT(b) || x->tid != T_STR || y->tid != T_STR)
    fpr_cpanic("strcat: not strings");
  str_t *s = (str_t *)fpr_alloc(sizeof(str_t) + x->len + y->len);
  s->tid = T_STR;
  s->var = 0;
  s->len = x->len + y->len;
  for (uw i = 0; i < x->len; i++) s->bytes[i] = x->bytes[i];
  for (uw i = 0; i < y->len; i++) s->bytes[x->len + i] = y->bytes[i];
  return (V)s;
}

V fpr_prim_fn_error(V s) { fpr_panic(s); }

void fpr_render_to_uart(V v) {
  rpos = 0;
  render(v);
  for (int i = 0; i < rpos; i++) hal_putc(rbuf[i]);
}

/* string helpers exposed through the fpr_g_ contract (1-indexed, FPRISC) */
static V g_charAt(V s, V i) {
  str_t *t = (str_t *)s;
  if (ISINT(s) || t->tid != T_STR) fpr_cpanic("charAt: not a string");
  sw k = UNTAG(i);
  if (k < 1 || (uw)k > t->len) fpr_cpanic("charAt: index out of range");
  return TAG(t->bytes[k - 1]);
}
static V g_strlen(V s) {
  str_t *t = (str_t *)s;
  if (ISINT(s) || t->tid != T_STR) fpr_cpanic("strlen: not a string");
  return TAG(t->len);
}

/* parseInt : String -> Int — decimal, leading '-' allowed, stops at the
 * first non-digit. Empty or all-non-digit yields 0 (the pI idiom). */
static V g_parseInt(V sv) {
  if (ISINT(sv) || ((str_t *)sv)->tid != T_STR) fpr_cpanic("parseInt: not a String");
  str_t *s = (str_t *)sv;
  uw i = 0;
  sw sign = 1, acc = 0;
  if (i < s->len && s->bytes[i] == '-') { sign = -1; i++; }
  for (; i < s->len; i++) {
    uint8_t c = s->bytes[i];
    if (c < '0' || c > '9') break;
    acc = acc * 10 + (c - '0');
  }
  return TAG(sign * acc);
}

/* chr : Int -> String -- the inverse of charAt. One byte. The line
 * editor and path splitter build strings incrementally with this. */
static V g_chr(V c) {
  if (!ISINT(c)) fpr_cpanic("chr: not an Int");
  uint8_t b = (uint8_t)UNTAG(c);
  return (V)fpr_mkstr(&b, 1);
}

/* ---- floats: F64 / F32 as RAW-BITS payloads --------------------------
 * A float is its IEEE bit pattern carried in an ordinary V -- moved by
 * the same ld/sd/mv, slots, argspill, PAP and constructor paths as any
 * word (nothing there interprets values).  All arithmetic happens HERE,
 * in C prims the type-directed operator elaboration routes to
 * (Infer.hs resolveSites), so the generated .s stays integer-only and
 * every target's C compiler emits its own FP instructions.  The lp64
 * integer ABI is untouched: prims take and return V.
 *
 * The two runtime functions that DO interpret values dynamically
 * (render, veq) never legally see a raw float: Infer refuses str/print
 * on float-containing structures and rewrites float ==/compare to
 * these prims.  Known v1 hazard, documented not hidden: a denormal
 * whose bits alias a heap address could fool fpr_in_heap on an
 * explicit send/drop of a bare float -- the same shallow-honesty class
 * as veq's "deep equality needs field counts".  NaN-boxing or typed
 * drops are the real fix, with the Sol JTy lattice as the reference. */
#if UINTPTR_MAX > 0xFFFFFFFFu /* raw-bits floats assume a 64-bit V;
  on a 32-bit target the prims are simply absent, so any float use is
  an honest LINK error instead of silent truncation */
static double dbits(V v) { union { uw u; double d; } c; c.u = (uw)v; return c.d; }
static V bitsd(double d) { union { uw u; double d; } c; c.d = d; return (V)c.u; }
static float fbits(V v) { union { uint32_t u; float f; } c; c.u = (uint32_t)(uw)v; return c.f; }
static V bitsf(float f) { union { uint32_t u; float f; } c; c.f = f; return (V)(uw)c.u; }

/* literal splicing: the parser encodes 1.5 as f64frombits hi lo (two
 * tagged 32-bit halves -- a tagged V cannot carry 64 raw bits) */
V fpr_prim_fn_f64frombits(V hi, V lo) {
  return (V)(((uw)UNTAG(hi) << 32) | ((uw)UNTAG(lo) & 0xFFFFFFFFu));
}

/* F32 literals fit one tagged Int (32 bits < 62), so one arg */
V fpr_prim_fn_f32frombits(V b) { return (V)((uw)UNTAG(b) & 0xFFFFFFFFu); }

V fpr_prim_fn_F64_x2e_x2b(V a, V b) { return bitsd(dbits(a) + dbits(b)); }
V fpr_prim_fn_F64_x2e_x2d(V a, V b) { return bitsd(dbits(a) - dbits(b)); }
V fpr_prim_fn_F64_x2e_x2a(V a, V b) { return bitsd(dbits(a) * dbits(b)); }
/* IEEE division: inf/NaN are float-native error values -- no panic,
 * unlike Int / (floats carry their own poison; that is the point) */
V fpr_prim_fn_F64_x2e_x2f(V a, V b) { return bitsd(dbits(a) / dbits(b)); }
V fpr_prim_fn_F64_x2e_x3c(V a, V b) { return BOOL(dbits(a) < dbits(b)); }
V fpr_prim_fn_F64_x2e_x3e(V a, V b) { return BOOL(dbits(a) > dbits(b)); }
V fpr_prim_fn_F64_x2e_x3c_x3d(V a, V b) { return BOOL(dbits(a) <= dbits(b)); }
V fpr_prim_fn_F64_x2e_x3e_x3d(V a, V b) { return BOOL(dbits(a) >= dbits(b)); }
V fpr_prim_fn_F64_x2e_x3d_x3d(V a, V b) { return BOOL(dbits(a) == dbits(b)); } /* IEEE: NaN != NaN */
V fpr_prim_fn_F64_x2e_x21_x3d(V a, V b) { return BOOL(dbits(a) != dbits(b)); }
/* sqrt: the ONE float op with no C operator.  __builtin_sqrt does not
 * inline on a freestanding link -- gcc emits a libm CALL for the errno
 * path -- and NO app image in this system links libm: not the
 * bare-metal one, not the qx64 .qa (found by the x64 failing the
 * same way the RISC-V one had).  So name the instruction on each
 * architecture we target and keep the builtin only for a genuinely
 * hosted link.  Exact and correctly rounded everywhere; no
 * -ffast-math, no errno, no libm dependency introduced. */
static double fsqrt_(double x) {
#if defined(__riscv) && defined(__riscv_flen)
  double r;
  __asm__("fsqrt.d %0, %1" : "=f"(r) : "f"(x));
  return r;
#elif defined(__x86_64__)
  double r;
  __asm__("sqrtsd %1, %0" : "=x"(r) : "x"(x));
  return r;
#elif defined(__aarch64__)
  double r;
  __asm__("fsqrt %d0, %d1" : "=w"(r) : "w"(x));
  return r;
#else
  return __builtin_sqrt(x); /* hosted fallback: libm is linked */
#endif
}
V fpr_prim_fn_F64_x2esqrt(V a) { return bitsd(fsqrt_(dbits(a))); }
V fpr_prim_fn_F64_x2eofInt(V a) { return bitsd((double)UNTAG(a)); }
V fpr_prim_fn_F64_x2etoInt(V a) { return TAG((sw)dbits(a)); } /* truncates */
V fpr_prim_fn_F64_x2eofF32(V a) { return bitsd((double)fbits(a)); }

V fpr_prim_fn_F32_x2e_x2b(V a, V b) { return bitsf(fbits(a) + fbits(b)); }
V fpr_prim_fn_F32_x2e_x2d(V a, V b) { return bitsf(fbits(a) - fbits(b)); }
V fpr_prim_fn_F32_x2e_x2a(V a, V b) { return bitsf(fbits(a) * fbits(b)); }
V fpr_prim_fn_F32_x2e_x2f(V a, V b) { return bitsf(fbits(a) / fbits(b)); }
V fpr_prim_fn_F32_x2e_x3c(V a, V b) { return BOOL(fbits(a) < fbits(b)); }
V fpr_prim_fn_F32_x2e_x3e(V a, V b) { return BOOL(fbits(a) > fbits(b)); }
V fpr_prim_fn_F32_x2e_x3c_x3d(V a, V b) { return BOOL(fbits(a) <= fbits(b)); }
V fpr_prim_fn_F32_x2e_x3e_x3d(V a, V b) { return BOOL(fbits(a) >= fbits(b)); }
V fpr_prim_fn_F32_x2e_x3d_x3d(V a, V b) { return BOOL(fbits(a) == fbits(b)); }
V fpr_prim_fn_F32_x2e_x21_x3d(V a, V b) { return BOOL(fbits(a) != fbits(b)); }
/* via the double path deliberately: __builtin_sqrtf lowers to a libm
 * CALL on this toolchain (no sqrtf in a freestanding link), while
 * __builtin_sqrt inlines to fsqrt.d.  Rounding the exact f64 result
 * back to f32 is correctly rounded for every finite input anyway. */
/* via the double path deliberately: rounding the exact f64 root back
 * to f32 is correctly rounded for every finite input, and it avoids a
 * second instruction-vs-libm question for fsqrt.s. */
V fpr_prim_fn_F32_x2esqrt(V a) { return bitsf((float)fsqrt_((double)fbits(a))); }
V fpr_prim_fn_F32_x2eofInt(V a) { return bitsf((float)UNTAG(a)); }

/* ---- transcendentals: freestanding, double path -----------------------
 * No libm in any of these links, so log/exp/pow/sin/cos are here whole:
 * classic Cody-Waite reductions + Taylor/atanh polynomials, ~1 ulp on
 * the primary ranges.  v1 honesty: pow is exp(y*ln x) (error grows
 * with |y ln x|), and sin/cos reduce with a two-word pi/2, exact to
 * |x| ~ 2^30 and degrading beyond (no Payne-Hanek).  F32 variants
 * compute in double and round once, like F32.sqrt above. */
static const double LN2HI_ = 6.93147180369123816490e-01,
                    LN2LO_ = 1.90821492927058770002e-10,
                    INVLN2_ = 1.44269504088896338700e+00;
static uint64_t draw_(double d) { union { double d; uint64_t u; } c; c.d = d; return c.u; }
static double draw2d_(uint64_t u) { union { double d; uint64_t u; } c; c.u = u; return c.d; }

/* x = 2^e * m, m in [~0.7071, 1.4142); returns atanh((m-1)/(m+1)),
 * i.e. ln(m)/2, and the exponent through ep */
static double logcore_(double x, int *ep) {
  uint64_t u = draw_(x);
  int e = 0;
  if (u < (1ull << 52)) { x *= 9007199254740992.0; u = draw_(x); e -= 53; }
  e += (int)((u >> 52) & 0x7ff) - 1023;
  double m = draw2d_((u & 0xfffffffffffffull) | (1023ull << 52));
  if (m > 1.4142135623730951) { m *= 0.5; e += 1; }
  double t = (m - 1.0) / (m + 1.0), t2 = t * t;
  *ep = e;
  return t * (1.0 + t2 * (1.0 / 3 + t2 * (1.0 / 5 + t2 * (1.0 / 7 + t2 * (1.0 / 9
       + t2 * (1.0 / 11 + t2 * (1.0 / 13 + t2 * (1.0 / 15 + t2 * (1.0 / 17
       + t2 * (1.0 / 19 + t2 * (1.0 / 21 + t2 * (1.0 / 23))))))))))));
}
static int fspec_(double x) { return ((draw_(x) >> 52) & 0x7ff) == 0x7ff; } /* inf|nan */
static double flog_(double x) {
  if (x != x || fspec_(x)) return (x != x || x > 0.0) ? x : 0.0 / 0.0;
  if (x < 0.0) return 0.0 / 0.0;
  if (x == 0.0) return -1.0 / 0.0;
  int e; double s = logcore_(x, &e);
  return 2.0 * s + (double)e * LN2HI_ + (double)e * LN2LO_;
}
static double flog2_(double x) {
  if (x != x || fspec_(x)) return (x != x || x > 0.0) ? x : 0.0 / 0.0;
  if (x < 0.0) return 0.0 / 0.0;
  if (x == 0.0) return -1.0 / 0.0;
  int e; double s = logcore_(x, &e);
  return (double)e + 2.0 * s * INVLN2_; /* integer part exact */
}
static double fexp_(double x) {
  if (x != x) return x;
  if (x > 709.782712893384) return 1.0 / 0.0;
  if (x < -745.133219101941) return 0.0;
  double kd = x * INVLN2_;
  int k = (int)(kd + (kd >= 0.0 ? 0.5 : -0.5));
  double r = (x - (double)k * LN2HI_) - (double)k * LN2LO_;
  double s = 1.0 + r * (1.0 + r * (1.0 / 2 + r * (1.0 / 6 + r * (1.0 / 24
           + r * (1.0 / 120 + r * (1.0 / 720 + r * (1.0 / 5040 + r * (1.0 / 40320
           + r * (1.0 / 362880 + r * (1.0 / 3628800 + r * (1.0 / 39916800
           + r * (1.0 / 479001600 + r * (1.0 / 6227020800.0)))))))))))));
  if (k >= -1021) return s * draw2d_((uint64_t)(k + 1023) << 52);
  return s * draw2d_((uint64_t)(k + 1023 + 64) << 52) * draw2d_((uint64_t)(1023 - 64) << 52);
}
static double fpow_(double x, double y) {
  if (y == 0.0) return 1.0;
  if (x != x || y != y) return 0.0 / 0.0;
  if (x == 1.0) return 1.0;
  if (x == 0.0) return y > 0.0 ? 0.0 : 1.0 / 0.0;
  if (x < 0.0) {
    double yi = (double)(long long)y;
    if (yi != y) return 0.0 / 0.0; /* v1: no complex results */
    double r = fexp_(y * flog_(-x));
    return (((long long)y) & 1) ? -r : r;
  }
  return fexp_(y * flog_(x));
}
/* two-word Cody-Waite pi/2 reduction -> r in [-pi/4, pi/4], quadrant */
static int rempio2_(double x, double *rp, int *okp) {
  const double P1 = 1.57079632673412561417e+00, P1T = 6.07710050650619224932e-11;
  *okp = 1;
  if (x > 1.0e15 || x < -1.0e15) { *okp = 0; return 0; } /* v1 range end */
  if (x > 1.073741824e9 || x < -1.073741824e9) {
    /* coarse 2pi spin-down first so the quadrant cast stays in range
     * (accuracy here is already ~ulp(x)-limited; documented v1) */
    x -= (double)(long long)(x * 1.59154943091895345608e-01) * 6.28318530717958647693e+00;
  }
  double nd = x * 6.36619772367581382433e-01; /* 2/pi */
  double n = (double)(long long)(nd + (nd >= 0.0 ? 0.5 : -0.5));
  *rp = (x - n * P1) - n * P1T;
  return ((long long)n) & 3;
}
static double ksin_(double r) {
  double r2 = r * r;
  return r * (1.0 + r2 * (-1.0 / 6 + r2 * (1.0 / 120 + r2 * (-1.0 / 5040
       + r2 * (1.0 / 362880 + r2 * (-1.0 / 39916800 + r2 * (1.0 / 6227020800.0
       + r2 * (-1.0 / 1307674368000.0 + r2 * (1.0 / 355687428096000.0)))))))));
}
static double kcos_(double r) {
  double r2 = r * r;
  return 1.0 + r2 * (-1.0 / 2 + r2 * (1.0 / 24 + r2 * (-1.0 / 720
       + r2 * (1.0 / 40320 + r2 * (-1.0 / 3628800 + r2 * (1.0 / 479001600.0
       + r2 * (-1.0 / 87178291200.0 + r2 * (1.0 / 20922789888000.0))))))));
}
static double fsin_(double x) {
  if (x != x || fspec_(x)) return 0.0 / 0.0;
  double r; int ok; int q = rempio2_(x, &r, &ok);
  if (!ok) return 0.0 / 0.0;
  switch (q) {
    case 0: return ksin_(r);
    case 1: return kcos_(r);
    case 2: return -ksin_(r);
    default: return -kcos_(r);
  }
}
static double fcos_(double x) {
  if (x != x || fspec_(x)) return 0.0 / 0.0;
  double r; int ok; int q = rempio2_(x, &r, &ok);
  if (!ok) return 0.0 / 0.0;
  switch (q) {
    case 0: return kcos_(r);
    case 1: return -ksin_(r);
    case 2: return -kcos_(r);
    default: return ksin_(r);
  }
}
V fpr_prim_fn_F64_x2elog(V a) { return bitsd(flog_(dbits(a))); }
V fpr_prim_fn_F64_x2elog2(V a) { return bitsd(flog2_(dbits(a))); }
V fpr_prim_fn_F64_x2eexp(V a) { return bitsd(fexp_(dbits(a))); }
V fpr_prim_fn_F64_x2epow(V a, V b) { return bitsd(fpow_(dbits(a), dbits(b))); }
V fpr_prim_fn_F64_x2esin(V a) { return bitsd(fsin_(dbits(a))); }
V fpr_prim_fn_F64_x2ecos(V a) { return bitsd(fcos_(dbits(a))); }
V fpr_prim_fn_F32_x2elog(V a) { return bitsf((float)flog_((double)fbits(a))); }
V fpr_prim_fn_F32_x2elog2(V a) { return bitsf((float)flog2_((double)fbits(a))); }
V fpr_prim_fn_F32_x2eexp(V a) { return bitsf((float)fexp_((double)fbits(a))); }
V fpr_prim_fn_F32_x2epow(V a, V b) { return bitsf((float)fpow_((double)fbits(a), (double)fbits(b))); }
V fpr_prim_fn_F32_x2esin(V a) { return bitsf((float)fsin_((double)fbits(a))); }
V fpr_prim_fn_F32_x2ecos(V a) { return bitsf((float)fcos_((double)fbits(a))); }
V fpr_prim_fn_F32_x2etoInt(V a) { return TAG((sw)fbits(a)); }
V fpr_prim_fn_F32_x2eofF64(V a) { return bitsf((float)dbits(a)); }

/* dtoa, freestanding and deliberately simple (v1): sign/NaN/Inf/0,
 * fixed-point for 1e-4 <= |x| < 2^63, exponent form outside, sig
 * significant digits (15 for f64, 7 for f32 -- the f32 count is what
 * keeps 0.1f from printing its double-widened noise), trailing zeros
 * trimmed.  NOT shortest-round-trip; Ryu is a follow-up if float
 * text ever becomes a persistence format rather than a display one. */
static uw dtoa(char *out, double x, int sig) {
  char *p = out;
  if (x != x) { p[0]='N'; p[1]='a'; p[2]='N'; return 3; }
  if (x < 0 || (x == 0 && __builtin_signbit(x))) { *p++ = '-'; x = -x; }
  if (x > 1.7e308) { p[0]='I'; p[1]='n'; p[2]='f'; return (uw)(p - out) + 3; }
  if (x == 0) { *p++ = '0'; return (uw)(p - out); }
  int e10 = 0;
  if (x >= 9.2e18 || x < 1e-4) { /* exponent form: normalize to [1,10) */
    while (x >= 10.0) { x /= 10.0; e10++; }
    while (x < 1.0) { x *= 10.0; e10--; }
  }
  sw ip = (sw)x;
  double fr = x - (double)ip;
  { /* integer part */
    char b[24]; int i = 23; uw u = (uw)ip; int digs = 0;
    if (u == 0) { b[i--] = '0'; }
    while (u) { b[i--] = (char)('0' + u % 10); u /= 10; digs++; }
    for (int j = i + 1; j <= 23; j++) *p++ = b[j];
    /* a leading "0." consumes NO significant digits -- charging it one
     * (the first version did) printed 1/3 with 14 threes instead of
     * 15, i.e. one digit short of the f64 significand */
    if (digs > sig) digs = sig;
    sig -= digs;
  }
  if (fr > 0 && sig > 0) {
    *p++ = '.';
    char *fst = p;
    while (sig-- > 0) {
      fr *= 10.0;
      int d = (int)fr;
      if (d > 9) d = 9;
      *p++ = (char)('0' + d);
      fr -= d;
      if (fr <= 0) break;
    }
    while (p > fst && p[-1] == '0') p--; /* trim */
    if (p == fst) p--;                    /* bare '.' too */
  }
  if (e10) {
    *p++ = 'e';
    if (e10 < 0) { *p++ = '-'; e10 = -e10; }
    char b[8]; int i = 7;
    while (e10) { b[i--] = (char)('0' + e10 % 10); e10 /= 10; }
    for (int j = i + 1; j <= 7; j++) *p++ = b[j];
  }
  return (uw)(p - out);
}
V fpr_prim_fn_F64_x2estr(V a) {
  char b[40];
  return (V)fpr_mkstr((const uint8_t *)b, dtoa(b, dbits(a), 15));
}
V fpr_prim_fn_F32_x2estr(V a) {
  char b[40];
  return (V)fpr_mkstr((const uint8_t *)b, dtoa(b, (double)fbits(a), 7));
}
#endif /* 64-bit V */

/* ---- static PAP objects (symbol names = mangled FPRISC names) ---------- */
FPR_FN(fpr_prim_obj__x2b, fpr_prim_fn__x2b, 2);       /* +  */
FPR_FN(fpr_prim_obj__x2d, fpr_prim_fn__x2d, 2);       /* -  */
FPR_FN(fpr_prim_obj__x2a, fpr_prim_fn__x2a, 2);       /* *  */
FPR_FN(fpr_prim_obj__x2f, fpr_prim_fn__x2f, 2);       /* /  */
FPR_FN(fpr_prim_obj__x3d_x3d, fpr_prim_fn__x3d_x3d, 2);    /* == */
FPR_FN(fpr_prim_obj__x21_x3d, fpr_prim_fn__x21_x3d, 2);    /* != */
FPR_FN(fpr_prim_obj__x3c, fpr_prim_fn__x3c, 2);        /* <  */
FPR_FN(fpr_prim_obj__x3e, fpr_prim_fn__x3e, 2);        /* >  */
FPR_FN(fpr_prim_obj__x3c_x3d, fpr_prim_fn__x3c_x3d, 2);    /* <= */
FPR_FN(fpr_prim_obj__x3e_x3d, fpr_prim_fn__x3e_x3d, 2);    /* >= */
FPR_FN(fpr_prim_obj_strcat, fpr_prim_fn_strcat, 2);
FPR_FN(fpr_prim_obj_print, fpr_prim_fn_print, 1);
FPR_FN(fpr_prim_obj_String_x2elen, fpr_prim_fn_String_x2elen, 1);
FPR_FN(fpr_prim_obj__x21, fpr_prim_fn__x21, 2);
FPR_FN(fpr_prim_obj_str, fpr_prim_fn_str, 1);
FPR_FN(fpr_prim_obj_error, fpr_prim_fn_error, 1);

FPR_FN(fpr_g_charAt, g_charAt, 2);
FPR_FN(fpr_g_strlen, g_strlen, 1);
FPR_FN(fpr_g_chr, g_chr, 1);
FPR_FN(fpr_g_parseInt, g_parseInt, 1);
FPR_FN(fpr_g_substr, g_substr, 3);
FPR_FN(fpr_g_drop, g_drop, 1);
FPR_FN(fpr_g_arcLive, g_arcLive, 1);
FPR_FN(fpr_g_heapUsed, g_heapUsed, 1);

