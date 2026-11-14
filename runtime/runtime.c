/* runtime.c — allocator, generic apply, core prims, panic.
 *
 * The core prims here are exactly the names the DESUGARER can emit
 * (operators, str/strcat from interpolation, error). Everything else a
 * program references is deliberately NOT here: it arrives as a fpr_g_*
 * extern that hal.c (or any other module) satisfies at link time.
 */
#include "fpr.h"
#ifdef FPR_BUILTIN
#include "builtin.h" /* the heap's region operations (machine/builtin/heap.c) */
#endif
#include "i32.h"
#include "vec_layout.h" /* the deep copier lays vectors into slabs */
#ifdef FPR_QOSAPP
#include "qos_abi.h"
#endif

const hdr_t fpr_true = {T_BOOL, 1};
const hdr_t fpr_false = {T_BOOL, 0};
const hdr_t fpr_unit = {T_UNIT, 0};

/* ---- allocator: bump + owning slab + segregated free list ------------
 * Compact managed cells carry an 8-byte slab prefix and derive their size
 * from initialized object headers and constructor metadata. Legacy cells
 * and opaque raw buffers retain a 16-byte size/slab prefix. Freed blocks go into
 * exact-fit free lists by size class (16-byte steps up to the bucket
 * ceiling); blocks ABOVE the ceiling recycle through the pool's
 * exact-fit bigfree LIFO (the "larger blocks leak by design" PoC rule
 * is retired -- Vec.free of a big column block comes back).  Actor
 * stacks were never the leak: they ride the stack pool. */
/* The heap's span is a run-time fact, not a link-time one: the machine layer
 * says where it is (hal_heap_span) and how big -- RAM on a board, a
 * reservation of address space on a hosted system (docs/2026-09-19-BOUNDS.md). */
char *fpr_heap_lo, *fpr_heap_hi;

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
  h->pend_stack = 0;
  h->rq_head = h->rq_tail = 0;
  __atomic_store_n(&h->idle, 0, __ATOMIC_RELAXED);
  h->fuel_preempts = 0;
  h->rpos = 0;
}

#if defined(FPR_ESP_IDF)
/* Called only during hart startup, before this task can switch actors. */
__thread fpr_hart_t *fpr_esp_hart;
void fpr_set_tp(fpr_hart_t *h) { fpr_esp_hart = h; }
#elif defined(FPR_POSIX)
#if defined(__aarch64__) && ((defined(FPR_QOSAPP) && !defined(FPR_QOSAPP_SINGLE)) || (!defined(FPR_QOSAPP) && defined(FPR_HART_X28)))
/* v3 (QOS apps) and hosted posix on AArch64: x28 is the hart register.  Clang wraps a global-
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
    /* buddy over the heap region: slabs, stacks, acbs, growth grants,
     * and loaded process images (QOS's loader takes them as blocks) */
#ifdef FPR_BUDDY_MIN
    uw minb = (uw)FPR_BUDDY_MIN;
#else
    uw minb = 64u * 1024;
#endif
    char *lo, *hi, *span_hi; /* the buddy's [lo, hi); fpr_in_heap's [lo, span_hi) */
    hal_heap_span(&lo, &hi, &span_hi);
    uw base = ((uw)lo + (minb - 1)) & ~(uw)(minb - 1);
    buddy_init((void *)base, (uw)hi - base);
    fpr_heap_lo = lo;
    fpr_heap_hi = span_hi;
    fpr_mem_own = 1; /* this image runs the buddy: the memory actor follows */
  }
  fpr_set_tp(&fpr_harts[0]);
#ifdef FPR_COMPACT_CELLS
  /* Metadata allocation must precede ARC-locked frees and worker startup. */
  if (fpr_layout_register(0)) fpr_cpanic("layout table: cannot initialize constructor metadata");
#endif
  fpr_rvv_enable();
  fpr_actors_init();
  /* everything above happens-before any secondary's first instruction */
  __atomic_store_n(&fpr_smp_go, 1, __ATOMIC_RELEASE);
}

char *fpr_static_lo, *fpr_static_hi; /* image-statics window (fpr.h) */

/* ---- mortal process images (fpr.h) -----------------------------------
 * One bit per buddy minimum block over the buddy's span says "this block
 * is a loaded image": fpr_in_heap's test is O(1) and takes no lock.  The
 * map is sized from the span at the first registration (a fact of the
 * machine, not a chosen limit) and lives as long as the buddy does.  The
 * records -- range and pid -- are a list under img_lock, read only on the
 * slow paths: the copier deciding what may leave an image, and teardown.
 * Image blocks are whole buddy blocks, so they are whole units here. */
static uint8_t *img_bits;
static char *img_base;
static uw img_units, img_shift;
static fpr_image_t *img_list;
static fpr_image_t *img_pid_hit; /* first matching registry entry at last lookup */
static fpr_image_t *img_recent; /* protected by img_lock */
static uw img_count; /* writers serialized by img_lock */
static fpr_lock_t img_lock;
static int in_image(const void *p) {
  uint8_t *b = __atomic_load_n(&img_bits, __ATOMIC_ACQUIRE);
  if (!b || (const char *)p < img_base) return 0;
  uw u = (uw)((const char *)p - img_base) >> img_shift;
  return u < img_units && ((__atomic_load_n(&b[u >> 3], __ATOMIC_RELAXED) >> (u & 7)) & 1);
}
static void img_mark(fpr_image_t *im, int on) {
  uw u0 = (uw)(im->lo - img_base) >> img_shift;
  uw u1 = (uw)(im->hi - img_base + ((uw)1 << img_shift) - 1) >> img_shift;
  if (u1 > img_units) u1 = img_units;
  while (u0 < u1) {
    unsigned bit = (unsigned)(u0 & 7);
    uw span = u1 - u0 < 8 - bit ? u1 - u0 : 8 - bit;
    uint8_t mask = (uint8_t)(((1u << span) - 1) << bit);
    uint8_t *byte = &img_bits[u0 >> 3];
    /* img_lock serializes writers. Only boundary bytes need their old bits. */
    uint8_t value = on ? mask : 0;
    if (mask != UINT8_MAX) value |= __atomic_load_n(byte, __ATOMIC_RELAXED) & ~mask;
    __atomic_store_n(byte, value, __ATOMIC_RELEASE);
    u0 += span;
  }
}
void fpr_image_add(fpr_image_t *im) {
  fpr_lock(&img_lock);
  if (!img_bits) {
    char *base; uw size, unit;
    buddy_geometry(&base, &size, &unit);
    uw shift = 0;
    while (((uw)1 << shift) < unit) shift++;
    uw units = size >> shift;
    uint8_t *b = (uint8_t *)buddy_alloc(units / 8 + 1);
    if (!b) fpr_cpanic("images: no memory for the image map");
    for (uw i = 0; i < units / 8 + 1; i++) b[i] = 0;
    img_base = base; img_units = units; img_shift = shift;
    __atomic_store_n(&img_bits, b, __ATOMIC_RELEASE);
  }
  if (im->lo < img_base || (uw)(im->hi - img_base) > (img_units << img_shift))
    fpr_cpanic("images: an image block outside the buddy span");
  im->next = img_list;
  img_list = im;
  img_pid_hit = 0;
  img_recent = im;
  img_mark(im, 1);
  __atomic_store_n(&img_count, __atomic_load_n(&img_count, __ATOMIC_RELAXED) + 1, __ATOMIC_RELEASE);
  fpr_unlock(&img_lock);
}
void fpr_image_remove(fpr_image_t *im) {
  fpr_lock(&img_lock);
  for (fpr_image_t **pp = &img_list; *pp; pp = &(*pp)->next) {
    if (*pp != im) continue;
    *pp = im->next;
    if (img_pid_hit == im) img_pid_hit = 0;
    if (img_recent == im) img_recent = 0;
    img_mark(im, 0);
    __atomic_store_n(&img_count, __atomic_load_n(&img_count, __ATOMIC_RELAXED) - 1, __ATOMIC_RELEASE);
    break;
  }
  fpr_unlock(&img_lock);
}
fpr_image_t *fpr_image_of_pid(uw pid) {
  fpr_lock(&img_lock);
  fpr_image_t *im = img_pid_hit;
  if (!im || im->pid != pid) {
    im = img_list;
    while (im && im->pid != pid) im = im->next;
    img_pid_hit = im;
  }
  fpr_unlock(&img_lock);
  return im;
}
/* the pid of the image p lies in, when that is not the process the copy in
 * progress is for (0: not an image, or the receiver's own) */
static fpr_image_t *image_at_locked(const void *p) {
  const char *addr = (const char *)p;
  if (img_recent && addr >= img_recent->lo && addr < img_recent->hi) return img_recent;
  for (fpr_image_t *im = img_list; im; im = im->next) {
    if (addr >= im->lo && addr < im->hi) {
      img_recent = im;
      return im;
    }
  }
  return 0;
}
static uw image_owner_pid(const void *p) {
  if (!in_image(p)) return 0;
  fpr_lock(&img_lock);
  fpr_image_t *im = image_at_locked(p);
  uw pid = im ? im->pid : 0;
  fpr_unlock(&img_lock);
  return pid;
}
static uw img_foreign(const void *p) {
  uw pid = image_owner_pid(p);
  if (!pid) return 0;
  fpr_hart_t *h = fpr_hart();
  return (!h || pid != h->copy_pid) ? pid : 0;
}
/* an image still owned by no process (pid 0: attached, not yet launched)
 * that holds p becomes process pid's: Sys.spawnApp adopts the image its
 * root function lives in, so the image ends with the pid (the loader's
 * fpr_pid_quiet hook frees it).  1 when an image was adopted. */
uw fpr_image_adopt(const void *p, uw pid) {
  if (!in_image(p)) return 0;
  uw took = 0;
  fpr_lock(&img_lock);
  fpr_image_t *im = image_at_locked(p);
  if (im && im->pid == 0) { im->pid = pid; img_pid_hit = 0; took = 1; }
  fpr_unlock(&img_lock);
  return took;
}
uw fpr_image_count(void) {
  return __atomic_load_n(&img_count, __ATOMIC_ACQUIRE);
}
void (*fpr_pid_quiet)(uw pid);

/* Debug-only independent allocation extent oracle. This records the actual
 * rounded allocator/copier request, before the object's header exists. It is
 * deliberately separate from layout_total's type-derived answer. Entries are
 * overwritten when a slab address is reused; exhaustion fails explicitly. */
#if defined(FPR_COMPACT_CELLS) && defined(FPR_LAYOUT_CHECK)
#define LAYOUT_EXTENTS (1u << 18)
static struct { V address; uw total; } layout_extents[LAYOUT_EXTENTS];
static fpr_lock_t layout_extent_lock;
static uw layout_extent(V address,uw record) {
  fpr_lock(&layout_extent_lock);
  uw at=(address>>3)&(LAYOUT_EXTENTS-1);
  for (uw n=0;n<LAYOUT_EXTENTS;n++,at=(at+1)&(LAYOUT_EXTENTS-1)) {
    if (layout_extents[at].address==address || !layout_extents[at].address) {
      uw total=layout_extents[at].total;
      if (record) { layout_extents[at].address=address; layout_extents[at].total=record; total=record; }
      fpr_unlock(&layout_extent_lock);
      if (!total) fpr_cpanic("layout check: allocation extent missing");
      return total;
    }
  }
  fpr_unlock(&layout_extent_lock);
  fpr_cpanic("layout check: extent oracle capacity exhausted");
  return 0;
}
#endif

#if defined(FPR_LAYOUT_CHECK) || defined(FPR_COMPACT_CELLS)
/* Managed extents come from the object's class and constructor metadata.
 * A legacy check compares with the size preheader; a compact check compares
 * with independently recorded allocation requests. Fault injection must stop
 * the program rather than make an unexercised rule pass vacuously. */
#define LAYOUT_ROUND(n) ((((n) + 15) & ~(uw)15))
static uw layout_arity(uw tid, uw var) { return fpr_layout_fields(tid,var); }
/* Round the combined prefix and payload, exactly as fpr_alloc does. Actor
 * handles are not allocated cells; managed Device/Register values are fixed. */
static uw layout_total(V v) {
  uw raw;
  switch (TID(v)) {
    case T_STR: raw = sizeof(str_t) + ((str_t *)v)->len; break;
    case T_SSTR: raw = sizeof(sstr_t); break;
    case T_BITS:
      raw = (((bits_t *)v)->var == 4 || ((bits_t *)v)->var == 5)
              ? sizeof(fpr_num64_t) : sizeof(bits_t);
      break;
    case T_PAP: raw = sizeof(pap_t) + ((pap_t *)v)->arity * sizeof(V); break;
    case T_VEC: raw = sizeof(vec_t); break;
    case T_DEVICE: raw = sizeof(fpr_dev_t); break;
    case T_REGISTER: raw = sizeof(reg_t); break;
    case T_ACTOR: return 0;
    default: raw = sizeof(hdr_t) + sizeof(uw) * layout_arity(TID(v), ((hdr_t *)v)->var);
  }
  return LAYOUT_ROUND(raw + FPR_MANAGED_PREFIX);
}
#ifdef FPR_LAYOUT_REPORT
static void praw(const char *s); /* declared for real further down */
/* one line per class, so a harness can tell "the rule held" from "no object of
 * that class was ever walked" -- the vacuity the first version of this check
 * could not see */
static uw layout_seen;
static void layout_report(V v) {
  uw bit;
  const char *name;
  switch (TID(v)) {
    case T_STR: case T_SSTR: bit = 1; name = "string"; break;
    case T_BITS: bit = 2; name = "bits"; break;
    case T_PAP: bit = 4; name = "pap"; break;
    case T_VEC: bit = 8; name = "vector"; break;
    case T_ACTOR: case T_DEVICE: case T_REGISTER: return;
    default: bit = 16; name = "constructor"; break;
  }
  if (layout_seen & bit) return;
  layout_seen |= bit;
  praw("[layout] verified ");
  praw(name);
  praw("\n");
}
#endif
static uw preheader_total(V v) {
#if defined(FPR_COMPACT_CELLS) && defined(FPR_LAYOUT_CHECK)
  uw total = layout_extent(v,0);
#elif defined(FPR_COMPACT_CELLS)
  uw total = layout_total(v);
#else
  uw total = *(uw *)((char *)v - 16);
#endif
#ifdef FPR_LAYOUT_CHECK
  uw want = layout_total(v);
#ifdef FPR_LAYOUT_FAULT
  want = want ? want + 16 : 16;
#endif
  if (want != 0 && want != total)
    fpr_cpanic("layout check: derived size disagrees with the allocation");
#endif
#ifdef FPR_LAYOUT_REPORT
  layout_report(v);
#endif
  return total;
}
#define PREHEADER(v) preheader_total(v)
#else
#define PREHEADER(v) (*(uw *)((char *)(v) - 16))
#endif
#define RAW_TOTAL(v) (*(uw *)((char *)(v) - FPR_RAW_PREFIX))
static void allocation_header(char *p,uw total,fpr_slab_t *sl,uw prefix) {
  if (prefix==FPR_RAW_PREFIX) *(uw *)p=total;
  *(fpr_slab_t **)(p+prefix-8)=sl;
#if defined(FPR_COMPACT_CELLS) && defined(FPR_LAYOUT_CHECK)
  if (prefix==FPR_MANAGED_PREFIX) layout_extent((V)(p+prefix),total);
#endif
}
#ifndef FPR_BUILTIN
int fpr_in_heap(V v) { /* the buddy span: heap + process regions */
  /* a loaded process's IMAGE lives inside the span (the fixed slot)
   * but its cells are statics without alloc preheaders -- exclude the
   * window before either span test below can claim them */
  if (!ISINT(v) && (char *)v >= fpr_static_lo && (char *)v < fpr_static_hi)
    return 0;
  if (!ISINT(v) && in_image((const void *)v)) /* a loaded image's statics */
    return 0;
  if (fpr_plane_memory) /* shared plane: the KERNEL's span is the heap */
    return !ISINT(v) && (char *)v >= fpr_plane_memory->heap_lo && (char *)v < fpr_plane_memory->heap_hi;
  return !ISINT(v) && (char *)v >= fpr_heap_lo && (char *)v < fpr_heap_hi;
}

#endif

/* ---- the slab allocator (see the fpr.h essay) ----------------------- */
#ifndef FPR_SLAB_SZ
#define FPR_SLAB_SZ ((uw)256 * 1024)
#endif
#define SLAB_SZ FPR_SLAB_SZ
/* one minimum buddy block, less the buddy's own header word */
#ifndef FPR_SLAB_MIN
#define FPR_SLAB_MIN ((uw)64 * 1024 - 2 * sizeof(uw))
#endif

/* the arena override belongs to the ACTOR inside the arena (hart-loop
 * context, with no actor, keeps the hart's): an actor parked in its arena
 * must not shadow the pools of the actors the hart runs meanwhile */
static struct fpr_pool **override_slot(fpr_hart_t *h) {
  return h->current ? fpr_acb_override_slot(h->current) : &h->pool_override;
}
static fpr_pool_t *cur_pool(fpr_hart_t *h) {
  struct fpr_pool *ov = *override_slot(h);
  if (ov) return (fpr_pool_t *)ov;
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
/* Each successful growth reserves its ring position in fpr_grow_count. */
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
    /* an actor's own blocks are its process's to pay for (a confined one has
     * a budget: actors.c); the ARC table (5) and the shared spare (2) are
     * the machine's, whoever happened to grow them */
    if (g.ptr) {
      g.size = buddy_block_usable_size(g.ptr);
      if (site != 5 && site != 2) {
        g.ptr = fpr_charge_sized(g.ptr, g.size);
        if (!g.ptr) g.size = 0;
      }
    }
  } else if (fpr_grow_memory)
    g = fpr_grow_memory(want); /* a loaded process: the loader's grant */
  if (g.ptr) {
    uw s = __atomic_fetch_add(&fpr_grow_count, 1, __ATOMIC_RELAXED);
    __atomic_add_fetch(&fpr_grow_bytes, g.size, __ATOMIC_RELAXED);
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
  if (fpr_plane_memory) { fpr_plane_memory->slab_release(sl); return; }
  slab_home(sl);
}

/* a fresh pool slab from THIS image's lower allocator -- the shared
 * plane's growth path for routed process pools (fpr.h fpr_plane_memory_t);
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
  fpr_fl_put(&grant_fl, sl, (uw)(sl->end - fpr_slab_start(sl)));
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
  __builtin_memset(k->b, 0, sizeof k->b);
  return k->b;
}

void fpr_bkt_put(void **b) {
  fpr_fl_put(&bkt_fl, b, sizeof(bktblk_t));
}

#ifndef FPR_BUILTIN
static fpr_pool_t *base_pool(fpr_hart_t *h) { return h->current ? fpr_acb_pool(h->current) : &h->pool; }
static int region_trip(fpr_hart_t *h, fpr_pool_t *pool); /* below, with the regions */
/* The rounding pad (under 16 bytes) is cleared inline: bytes up to the next
 * word, then whole words, so a String's odd length no longer costs a memset
 * call.  The payload itself is never touched (check_alloc_fast). */
static inline void alloc_zero_pad(char *payload, uw raw_bytes, uw total, uw prefix) {
  uw end = total - prefix, o = raw_bytes;
  for (; o < end && (o & (sizeof(uw) - 1)); o++) payload[o] = 0;
  for (; o < end; o += sizeof(uw)) *(uw *)(payload + o) = 0;
}
/* The inline bump window (fpr.h, bump_slab).  Opened at the end of every
 * fpr_alloc over the pool that is then current; generated code then bumps
 * that pool's slab itself until the slab is full or the size class has a
 * recycled block, when it calls fpr_alloc (through the unit's register-saving
 * wrapper) and the window reopens here.  Never opened:
 *   - in a cost-probe build, so cost_alloc_requests/bytes count every
 *     allocation on the call path, exactly as before (the probe measures
 *     the program's requests, not the allocator's speed);
 *   - in a process routed through the shared plane, whose pools grow in the
 *     kernel and whose actors the kernel's scheduler switches. */
static void *bump_nobuckets[FPR_NBUCKETS]; /* a region arena's: always empty */
static inline void bump_open(fpr_hart_t *h) {
#if defined(FPR_COST_PROBE) || (defined(FPR_COMPACT_CELLS) && defined(FPR_LAYOUT_CHECK))
  (void)h;
#else
  if (fpr_plane_memory) return;
  fpr_pool_t *pool = cur_pool(h);
  if (!pool->cur) return;
  h->bump_bkt = pool->buckets ? pool->buckets : bump_nobuckets;
  h->bump_slab = pool->cur;
#endif
}
#ifdef FPR_BUMP_CHECK
/* the bump-check build (FPR_BUMP_CHECK=1 fpr build): at every fuel tick and
 * every fpr_alloc, an open window must be the current pool's bump slab, its
 * buckets the pool's, its cursor inside the slab.  A close missing from
 * some change of pool or slab shows up here at the next tick instead of as a
 * cell bumped into a pool that is no longer current.  The counts printed at
 * exit say whether open windows were ever seen (not vacuous). */
static uw bump_checks, bump_checks_open, bump_refills;
void fpr_bump_check(fpr_hart_t *h) {
  if (!h) return;
  __atomic_fetch_add(&bump_checks, 1, __ATOMIC_RELAXED);
  fpr_slab_t *sl = h->bump_slab;
  if (!sl) return;
  __atomic_fetch_add(&bump_checks_open, 1, __ATOMIC_RELAXED);
  fpr_pool_t *pool = cur_pool(h);
  if (fpr_plane_memory) fpr_cpanic("bump check: a window in a plane-routed process");
  if (sl != pool->cur) fpr_cpanic("bump check: the window is not the current pool's bump slab");
  if (sl->owner != pool) fpr_cpanic("bump check: the window's slab belongs to another pool");
  if (h->bump_bkt != (pool->buckets ? pool->buckets : bump_nobuckets))
    fpr_cpanic("bump check: the window's buckets are not the current pool's");
  if (sl->hp < fpr_slab_start(sl) || sl->hp > sl->end) fpr_cpanic("bump check: the cursor is outside its slab");
}
__attribute__((destructor)) static void bump_check_report(void) {
  praw("[bump-check] checks ");
  pdec(__atomic_load_n(&bump_checks, __ATOMIC_RELAXED));
  praw(" open ");
  pdec(__atomic_load_n(&bump_checks_open, __ATOMIC_RELAXED));
  praw(" calls ");
  pdec(__atomic_load_n(&bump_refills, __ATOMIC_RELAXED));
  praw("\n");
}
#endif
#ifdef FPR_COST_PROBE
/* Allocation sites (FPR_ALLOC_SITES=<file> on a probe build, host.c): each
 * allocation's return-address chain, a few frames deep along the frame
 * pointers, counted in a fixed table; host.c writes it at exit and
 * tools/alloc_sites.py resolves the addresses.  A chain that leaves the
 * stack's shape stops early; a full table counts the rest as dropped. */
#define SITE_N 16384
#define SITE_DEPTH 6
uw fpr_site_keys[SITE_N][SITE_DEPTH], fpr_site_counts[SITE_N], fpr_site_bytes[SITE_N], fpr_site_dropped;
static int sites_on = -1;
/* the host's switch (machine/unix/host.c); weak: other hosts have none */
__attribute__((weak)) int fpr_alloc_sites_enabled(void);
static __attribute__((noinline)) void site_note(uw bytes) {
  if (sites_on < 0) sites_on = fpr_alloc_sites_enabled ? fpr_alloc_sites_enabled() : 0;
  if (!sites_on) return;
  uw key[SITE_DEPTH] = {0};
  uw *fp = (uw *)__builtin_frame_address(0);
  extern int main(int, char **);
  uw text = (uw)&main;
  for (int d = 0; d < SITE_DEPTH && fp; d++) {
    uw ret = fp[1];
    /* a return address outside the program's text: the chain left the
     * frame records (generated code keeps no frame pointer of its own) */
    if ((ret > text ? ret - text : text - ret) > ((uw)1 << 28)) break;
    key[d] = ret;
    uw *next = (uw *)fp[0];
    if ((uw)next <= (uw)fp || (uw)next - (uw)fp > ((uw)1 << 20) || ((uw)next & 7)) break;
    fp = next;
  }
  uw hsh = 1469598103934665603ull;
  for (int d = 0; d < SITE_DEPTH; d++) hsh = (hsh ^ key[d]) * 1099511628211ull;
  for (uw i = 0, j = hsh % SITE_N; i < SITE_N; i++, j = (j + 1) % SITE_N) {
    if (fpr_site_counts[j] == 0) {
      for (int d = 0; d < SITE_DEPTH; d++) fpr_site_keys[j][d] = key[d];
    } else if (__builtin_memcmp(fpr_site_keys[j], key, sizeof key)) continue;
    fpr_site_counts[j]++;
    fpr_site_bytes[j] += bytes;
    return;
  }
  fpr_site_dropped++;
}
#define SITE_NOTE(b) site_note(b)
#else
#define SITE_NOTE(b) ((void)0)
#endif
static V alloc_in_size(fpr_hart_t *h, fpr_pool_t *pool, V raw_bytes, int bulk,uw prefix) {
  if (raw_bytes>(uw)-1-prefix-15-sizeof(fpr_slab_t)-FPR_SLAB_PAD) fpr_cpanic("allocation size overflow");
  uw total = (raw_bytes+prefix+15)&~(uw)15;
  FPR_COST_ADD(h, cost_alloc_requests, 1);
  FPR_COST_ADD(h, cost_alloc_bytes, total);
  SITE_NOTE(total);
  if (total <= (uw)16 * FPR_NBUCKETS) {
    uw idx = total / 16 - 1;
    void *p = bucket_take(pool, idx);
    if (p) {
      fpr_slab_t *owner=*(fpr_slab_t **)((char *)p+8);
      allocation_header(p,total,owner,prefix);
      /* The deep copier may read pad words as constructor fields. */
      alloc_zero_pad((char *)p + prefix, raw_bytes, total,prefix);
      return (V)((char *)p + prefix);
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
      fpr_slab_t *owner=*(fpr_slab_t **)(p+8);
      allocation_header(p,total,owner,prefix);
      *(uw *)(p+prefix)=0;
      alloc_zero_pad(p+prefix,raw_bytes,total,prefix);
      return (V)(p+prefix);
    }
  }
  fpr_slab_t *sl = pool->cur;
  if (!sl || total > (uw)(sl->end - sl->hp)) {
    /* the slab refill: a pending call region whose call has used a slab of
     * this pool opens here, and the allocation goes to its arena instead */
    if (!bulk && region_trip(h, pool)) return alloc_in_size(h, cur_pool(h), raw_bytes, 0,prefix);
    if (pool->fixed_heap) fpr_actor_fail("fixed heap: local grant exhausted");
    uw want = total + sizeof(fpr_slab_t) + FPR_SLAB_PAD;
    /* A pool's slabs START SMALL AND DOUBLE, to SLAB_SZ: the first is one
     * buddy block (64 KiB), each next twice the last.  Every actor that
     * allocated anything used to take a whole SLAB_SZ (256 KiB) at once, so a
     * thousand small session actors cost half a gigabyte before doing any
     * work (docs/2026-09-19-BOUNDS.md); an actor that really does grow pays a few extra
     * blocks on the way up.  A loaded process without a buddy keeps the one
     * size: its grant recycler matches by size. */
    uw floor = SLAB_SZ;
    if (fpr_mem_own || fpr_plane_memory) {
      floor = sl ? 2 * (uw)(sl->end - (char *)sl) : FPR_SLAB_MIN;
      if (floor > SLAB_SZ) floor = SLAB_SZ;
    }
    if (want < floor) want = floor;
    if (fpr_plane_memory) {
      /* shared plane: pools grow from the KERNEL's buddy, so every
       * value this process builds lives in the one heap span and the
       * kernel reaps its acbs like any other */
      sl = fpr_plane_memory->slab_new(want);
      if (!sl) fpr_exhausted("heap exhausted (shared buddy has no free block)");
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
        if (!g.ptr || g.size < total + sizeof(fpr_slab_t) + FPR_SLAB_PAD) {
          /* the post-mortem journal should carry the numbers: how much
           * had been taken and what was being asked when it died (a
           * process's budget says its own: fpr_exhausted) */
          if (!fpr_budget_refused()) {
            praw("[mem] exhausted: want ");
            pdec(want);
            praw(" after ");
            pdec(__atomic_load_n(&fpr_grow_count, __ATOMIC_RELAXED));
            praw(" blocks / ");
            pdec(fpr_grow_bytes >> 20);
            praw(" MiB taken\n");
          }
          fpr_exhausted("heap exhausted (no block for a slab)");
        }
        sl = (fpr_slab_t *)g.ptr;
        sl->end = (char *)g.ptr + g.size;
      }
    }
    sl->owner = pool;
    sl->escaped = 0;
    sl->holds = 0;
    sl->promoted = 0;
    sl->pushed = 0;
    sl->hp = fpr_slab_start(sl);
    sl->next = pool->cur;
    fpr_bump_close(fpr_hart()); /* this pool's bump slab changes (it may be the window's) */
    pool->cur = sl;
  }
  char *p = sl->hp;
  sl->hp += total;
  pool->allocated += total;
  if (!bulk) h->region_bytes += total;
  allocation_header(p,total,sl,prefix);
  alloc_zero_pad(p+prefix,raw_bytes,total,prefix);
  return (V)(p+prefix);
}
static V alloc_in(fpr_hart_t *h,fpr_pool_t *pool,V bytes,int bulk) {
  return alloc_in_size(h,pool,bytes,bulk,FPR_MANAGED_PREFIX);
}
static V alloc_raw_in(fpr_hart_t *h,fpr_pool_t *pool,V bytes,int bulk) {
  return alloc_in_size(h,pool,bytes,bulk,FPR_RAW_PREFIX);
}
V fpr_alloc(V raw_bytes) {
  fpr_hart_t *h = fpr_hart();
#ifdef FPR_BUMP_CHECK
  fpr_bump_check(h);
  __atomic_fetch_add(&bump_refills, 1, __ATOMIC_RELAXED);
#endif
  fpr_pool_t *pool = cur_pool(h);
  /* Compiler regions have no small-block buckets. Only admit small sizes
   * before rounding, so this shortcut cannot overflow the size arithmetic.
   * Big blocks, bucketed pools and refills retain alloc_in's reuse/trip path. */
  if (!pool->buckets && raw_bytes <= (uw)16 * FPR_NBUCKETS - FPR_MANAGED_PREFIX) {
    uw total = (raw_bytes + FPR_MANAGED_PREFIX + 15) & ~(uw)15;
    fpr_slab_t *sl = pool->cur;
    if (sl && total <= (uw)(sl->end - sl->hp)) {
      char *p = sl->hp;
      sl->hp += total;
      pool->allocated += total;
      h->region_bytes += total;
      FPR_COST_ADD(h, cost_alloc_requests, 1);
      FPR_COST_ADD(h, cost_alloc_bytes, total);
      SITE_NOTE(total);
      allocation_header(p,total,sl,FPR_MANAGED_PREFIX);
      alloc_zero_pad(p+FPR_MANAGED_PREFIX,raw_bytes,total,FPR_MANAGED_PREFIX);
      bump_open(h);
      return (V)(p + FPR_MANAGED_PREFIX);
    }
  }
  V r = alloc_in(h, pool, raw_bytes, 0);
  bump_open(fpr_hart()); /* the allocation can park: the actor can migrate */
  return r;
}
/* a Vector's storage: the base pool, never a turn's arena (fpr.h) */
V fpr_alloc_bulk(V raw_bytes) { fpr_hart_t *h = fpr_hart(); return alloc_raw_in(h, base_pool(h), raw_bytes, 1); }
V fpr_alloc_raw(V raw_bytes) {
  fpr_hart_t *h=fpr_hart();
  V v=alloc_raw_in(h,cur_pool(h),raw_bytes,0);
  bump_open(fpr_hart());
  return v;
}
V fpr_alloc_object_bulk(V raw_bytes) { fpr_hart_t *h=fpr_hart(); return alloc_in(h,base_pool(h),raw_bytes,1); }

/* called ONLY from the ARC drop path, under arc_lock -- which is what
 * makes reading slab->owner race-free against death teardown (also
 * under arc_lock).  An orphaned slab's blocks are not recycled: the
 * whole slab goes back to buddy when its last promoted object drops. */
/* the third op of the allocator contract (docs/2026-08-25-MEMORY.md): grow a
 * block to hold `want` payload bytes.  Copy-based through the pool
 * tiers today: the preheader's total names the old payload capacity,
 * and the freed predecessor recycles exactly (buckets below the
 * ceiling, the bigfree LIFO above it), so a doubling ladder reuses
 * its own history.  In-place growth arrives when bulk storage moves
 * behind Memory.qa's buddy (docs/2026-08-29-MEMORY-V2-PLAN.md), where
 * buddy_realloc already provides it. */
V fpr_realloc(V v, V want) {
  if (!v) return fpr_alloc_raw(want);
  uw old = RAW_TOTAL(v) - FPR_RAW_PREFIX; /* payload capacity */
  if (old >= (uw)want) return v;
  V n = fpr_alloc_raw(want);
  __builtin_memcpy((void *)n, (void *)v, old);
  fpr_free_raw(v);
  return n;
}
V fpr_realloc_bulk(V v, V want) {
  if (!v) return fpr_alloc_bulk(want);
  uw old = RAW_TOTAL(v) - FPR_RAW_PREFIX;
  if (old >= (uw)want) return v;
  V n = fpr_alloc_bulk(want);
  __builtin_memcpy((void *)n, (void *)v, old);
  fpr_free_raw(v);
  return n;
}
V fpr_realloc_raw(V v,V want) { return fpr_realloc(v,want); }

static void free_block(V v,uw prefix,uw total) {
  char *p = (char *)v-prefix;
  fpr_slab_t *sl = *(fpr_slab_t **)((char *)v-8);
  if (total == 0) return; /* corrupt or double-freed: stays in slab */
  if (!sl || !sl->owner) return;
  /* All recycled blocks expose the same link/owner/size slots, even if
   * the next allocation uses the other prefix. */
  *(fpr_slab_t **)(p+8)=sl;
  *(uw *)p=total;
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
  *(uw *)p = 0; /* initialize the free-list link */
  void *old;
  if (!pool->buckets) return;
  sl->pushed = 1; /* an arena's turn reset zeroes the buckets only then */
  do {
    old = __atomic_load_n(&pool->buckets[idx], __ATOMIC_RELAXED);
    *(void **)p = old;
  } while (!__atomic_compare_exchange_n(&pool->buckets[idx], &old, p, 0,
                                        __ATOMIC_RELEASE, __ATOMIC_RELAXED));
}

void fpr_free(V v) { free_block(v,FPR_MANAGED_PREFIX,PREHEADER(v)); }
void fpr_free_raw(V v) { free_block(v,FPR_RAW_PREFIX,RAW_TOTAL(v)); }

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
 * Field discovery uses the allocation extent: compact cells derive it
 * from constructor metadata; legacy cells retain it in the preheader.
 * The uniform-V span is (total-FPR_MANAGED_PREFIX-8)/W, including any
 * zeroed rounding pad. A zero word is copied verbatim, never recursed.
 * Special tids:
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
/* Both physical spines are traversed iteratively. The private cell's
 * final field is its tail; every preceding slot is a tagged value. */
static inline unsigned spine_payloads(V value) {
  hdr_t *h = (hdr_t *)value;
  if (h->tid == T_STORED_LIST) return 1 + (h->var & 7);
  return h->tid == T_LIST && h->var == 1;
}
static inline V *spine_slots(V value) { return (V *)((char *)value + sizeof(hdr_t)); }

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
    case T_STORED_LIST: case T_LIST: {
      V c = v;
      unsigned heads;
      while (!ISINT(c) && fpr_in_heap(c) && (heads = spine_payloads(c))) {
        for (unsigned i=0; i<heads; ++i) dc_release(spine_slots(c)[i]);
        c = spine_slots(c)[heads];
      }
      return;
    }
    default: {
      uw total = PREHEADER(v);
      uw nf = (total - FPR_MANAGED_PREFIX - 8) / sizeof(uw);
      V *f = (V *)((char *)v + 8);
      for (uw i = 0; i < nf; i++) dc_release(f[i]);
      return;
    }
  }
}

typedef struct {
  char *hp;
  fpr_slab_t *sl;
  const char *novec; /* set: a Vector in the graph is refused by this name
                      * (a turn's state: its storage IS the arena) */
  int movevec;       /* a compiler-placed turn's state: a Vector this actor's
                      * base pool owns, raw columns only, crosses by handle
                      * (vec_movable_here); every other Vector is copied */
  int released;      /* a movevec copy copied some Vector (not moved): the old
                      * state's Vectors are released after the copy */
  fpr_slab_t *retain; /* state append: old nodes in this ONE slab stay by identity */
  char *end;         /* set: the copy may not write past here (a packing
                      * slab's end); a cell that would overflow sets the flag
                      * and is not written, so the caller can discard the
                      * uncommitted partial copy and take the sizing path */
  int overflow;
  struct fpr_pool *region; /* set: a pure loop region's copy-out; a cell another
                            * pool owns outlives the region and stays by identity */
  struct dc_share *share;  /* set: copy each shared cell once (source -> copy) */
  V mut_root;              /* set: the component a consuming twin writes in place;
                            * its subtree is copied whole (no outside rule) */
} dctx_t;
/* a Vector that may cross a turn boundary by handle: its header is in this
 * actor's base pool (so every piece is, vec.c allocates bulk there and a
 * turn's reset never touches it) and no column is boxed (a boxed element
 * could live in the turn's arena).  Anything else -- a message's Vector in
 * an ownerless slab, a boxed column -- is copied as before. */
static fpr_slab_t *slab_of(V v);
static int vec_movable_here(V v) {
#ifdef FPR_BUILTIN
  /* the builtin heap: bulk pieces are untracked, outliving every region */
  if (!fpr_builtin_untracked(v)) return 0;
  vec_t *bx = (vec_t *)v;
  for (uw k = 0; k < bx->ncols; k++) if (!VK_RAW(bx->kinds[k])) return 0;
  return 1;
#else
  fpr_hart_t *h = fpr_hart();
  if (!h) return 0;
  fpr_pool_t *base = h->current ? fpr_acb_pool(h->current) : &h->pool;
  fpr_slab_t *sl = slab_of(v);
  if (!sl || sl->owner != base) return 0;
  vec_t *x = (vec_t *)v;
  for (uw k = 0; k < x->ncols; k++) if (!VK_RAW(x->kinds[k])) return 0;
  return 1;
#endif
}

/* a fresh cell's slab footprint: fpr_alloc's exact rounding + header */
static uw dc_cellsz(uw raw) { return (raw+FPR_MANAGED_PREFIX+15)&~(uw)15; }
static uw dc_rawsz(uw raw) { return (raw+FPR_RAW_PREFIX+15)&~(uw)15; }

/* A STATIC from another process's image may not travel by identity: the
 * image goes when its process ends.  Data is copied -- the code generator
 * and the runtime make only these shapes of static: a string, a header
 * alone (a nullary constructor, Unit, a Bool, Nil), a Result over one
 * value, a device handle.  A function is code in that image and cannot be
 * copied: the send is refused, and the sender ends (fail-stop, like any
 * other refused send).  Returns the cell's raw bytes. */
static uw img_static_raw(V v, uw pid) {
  hdr_t *h = (hdr_t *)v;
  switch (h->tid) {
    case T_STR: return 16 + ((str_t *)v)->len;
    case T_RESULT: case T_DEVICE: return 16;
    case T_PAP:
      (void)pid;
      fpr_actor_fail("send: a function of another process cannot leave it "
                     "(its code goes when that process ends)");
    case T_STORED_LIST: case T_TUP2: case T_TUP3: case T_ATOM: case T_REGISTER: case T_BITS:
    case T_ACTOR: case T_VEC: case T_SSTR:
      fpr_actor_fail("send: a static of an unexpected kind in another process's image");
    default:
      if (h->tid >= T_TUP4 && h->tid <= T_TUP8)
        fpr_actor_fail("send: a static of an unexpected kind in another process's image");
      if (h->tid >= T_TUPN && h->tid < T_TUPN_END)
        fpr_actor_fail("send: a static of an unexpected kind in another process's image");
      return 8; /* a header alone */
  }
}

/* A retained transfer graph is self-contained in one slab. Comparing its
 * address range first avoids reading a preheader for immortal actor handles.
 * This context is explicit: ordinary message/admission copies never retain. */
/* A pure loop region's copy-out copies only what its reset frees: cells of
 * its arena, and of ownerless slabs (the previous transfer slab, messages,
 * orphans).  A cell another pool owns -- the caller's pool, an enclosing
 * region's arena, the base pool -- cannot be reset while the loop runs
 * (regions nest LIFO), so the new state may keep pointing at it.  Copying it
 * anyway made every full compaction re-copy, say, a fold's remaining input.
 * Vectors keep their own move-or-copy rule. */
/* Sharing.  The copier walks a tree: a cell reached twice is copied twice.
 * In a loop's state that can multiply (a list of versions of one tree), so a
 * region copy that finds more bytes than the region can hold -- a tree walk
 * of distinct cells never could -- copies again with a table that maps each
 * copied source cell to its copy.  The common unshared state pays only the
 * byte cap below.  The table lives in an ownerless slab for the one copy. */
/* A key is the cell's address with the pass in its low bits (cells are word
 * aligned): the sizing pass writes tag 1, the copy pass tag 2.  The copy
 * meets only cells the sizing counted, each at the end of the same probe
 * chain, so it takes over their slots and the table is never cleared between
 * the passes (that clear was a memset of the whole table at every cycle). */
typedef struct dc_share { uw mask, n, limit, tag, occupied; int full; uw *key; V *val; } dc_share_t;
static uw region_shared_copies, region_shared_full;
/* the sizing pass's context, passed down (a thread-local read was a call per
 * cell on macOS): the retained state slab, a region copy's arena, the byte
 * cap and whether it was passed, and the table that counts cells once */
typedef struct dc_sz { fpr_slab_t *retain; struct fpr_pool *region; dc_share_t *share; uw left; int over; V mut_root; } dc_sz_t;
static uw dc_share_slot(dc_share_t *t, V v) {
  uw i = (((uw)v >> 4) * (uw)0x9E3779B97F4A7C15ull) >> 20 & t->mask;
  while (t->key[i] && (t->key[i] & ~(uw)7) != (uw)v) i = (i + 1) & t->mask;
  return i;
}
static V dc_share_get(dc_share_t *t, V v) { uw i = dc_share_slot(t, v); return t->key[i] == ((uw)v | t->tag) ? t->val[i] : 0; }
static void dc_share_put(dc_share_t *t, V v, V n) {
  uw i = dc_share_slot(t, v);
  if (t->key[i] != ((uw)v | t->tag)) t->n++;
  if (!t->key[i] && ++t->occupied >= t->mask) fpr_cpanic("copy: the share table filled");
  t->key[i] = (uw)v | t->tag; t->val[i] = n;
}
/* the sizing pass meets a heap cell of a region copy: 0 = do not count it
 * (seen before, or the cap was passed and the walk is abandoned) */
static inline int dc_size_visit(dc_sz_t *z, V v) {
  if (z->share) {
    dc_share_t *t = z->share;
    if (t->full) return 1; /* abandoned: the caller falls back to the tree copy */
    uw i = dc_share_slot(t, v);
    if (t->key[i]) return 0;
    if (t->n >= t->limit) { t->full = 1; return 1; }
    t->key[i] = (uw)v | t->tag; t->n++; t->occupied++;
    return 1;
  }
  if (z->over) return 0;
  uw t = PREHEADER(v);
  if (t > z->left) { z->over = 1; return 0; }
  z->left -= t;
  return 1;
}
static int dc_outside(V v, struct fpr_pool *region) {
  if (!region || ((hdr_t *)v)->tid == T_VEC) return 0;
  struct fpr_pool *o = __atomic_load_n(&slab_of(v)->owner, __ATOMIC_RELAXED);
  return o && o != region;
}
static int dc_retained(V v, fpr_slab_t *retain) {
  if (!retain || ISINT(v) || !v) return 0;
  uw address = (uw)v;
  return address >= (uw)(retain + 1) && address < (uw)retain->hp && slab_of(v) == retain;
}
static uw dc_size_in(V v, dc_sz_t *z, int *immutable) {
  if (ISINT(v) || !v) return 0;
  if (z && z->mut_root && v == z->mut_root) {
    struct fpr_pool *r = z->region;
    z->mut_root = 0; z->region = 0;
    uw n = dc_size_in(v, z, immutable);
    z->region = r; z->mut_root = v;
    return n;
  }
  fpr_slab_t *retain = z ? z->retain : 0;
  struct fpr_pool *region = z ? z->region : 0;
  if (!fpr_in_heap(v)) {
    uw pid = img_foreign((const void *)v);
    if (!pid) return 0; /* an immortal static, or the receiver's own image */
    uw n = dc_cellsz(img_static_raw(v, pid));
    if (TID(v) == T_RESULT) n += dc_size_in(*(V *)((char *)v + 8), z, immutable);
    return n;
  }
  if (dc_retained(v, retain) || dc_outside(v, region)) return 0;
  if (region && !dc_size_visit(z, v)) return 0;
  uw total = PREHEADER(v);
  hdr_t *h = (hdr_t *)v;
  switch (h->tid) {
    case T_ACTOR: return 0; /* immortal acb: shared, not copied */
    case T_VEC: {
      if (immutable) *immutable = 0;
      { fpr_hart_t *mh = fpr_hart(); if (mh && mh->copy_movevec && vec_movable_here(v)) return 0; } /* moved, not copied */
      vec_t *x = (vec_t *)v;
      uw n = dc_cellsz(sizeof(vec_t));
      if (x->shape_len) n += dc_rawsz(x->shape_len * sizeof(vec_shape_t));
      if (x->ncols) n += dc_rawsz(x->ncols * sizeof(col_t *)) + dc_rawsz(VKINDS_BYTES(x->ncols));
      for (uw k = 0; k < x->ncols; k++) {
        if (!x->cols[k]) continue;
        n += dc_rawsz(sizeof(col_t));
        if (x->len) n += dc_rawsz(x->len * sizeof(uw));
        if (!VK_RAW(x->kinds[k])) /* boxed column: elements recurse */
          for (uw i = 0; i < x->len; i++)
            n += dc_size_in((V)x->cols[k]->base[i], z, immutable);
      }
      return n;
    }
    case T_SSTR: fpr_cpanic("send/keep: SString is linear-local");
    case T_DEVICE: case T_REGISTER: if (immutable) *immutable = 0; return total;
    case T_STR: case T_BITS: return total;
    case T_PAP: {
      pap_t *p = (pap_t *)v;
      if (img_foreign((const void *)p->fn))
        fpr_actor_fail("send: a function of another process cannot leave it "
                       "(its code goes when that process ends)");
      uw n = total;
      for (uw i = 0; i < p->nargs; i++) n += dc_size_in((V)p->args[i], z, immutable);
      return n;
    }
    case T_STORED_LIST: case T_LIST: {
      uw n = 0;
      V c = v;
      unsigned heads;
      while (!ISINT(c) && fpr_in_heap(c) && (heads = spine_payloads(c)) && !dc_retained(c, retain) && !dc_outside(c, region)) {
        if (c != v && region && !dc_size_visit(z, c)) return n; /* the rest of this spine is counted */
        n += PREHEADER(c);
        for (unsigned i=0; i<heads; ++i) n += dc_size_in(spine_slots(c)[i], z, immutable);
        c = spine_slots(c)[heads];
      }
      /* the tail: the static nil (not in the heap: 0); a nil a primitive built
       * on the heap (Sys.memInfo, growLog, actInfo...: its cell and nothing
       * more -- the default case below would derive a field count from the
       * allocation's padding and follow garbage, which hung a send forever);
       * or an improper tail */
      if (dc_retained(c, retain)) return n;
      if (!ISINT(c) && c && fpr_in_heap(c) && dc_outside(c, region)) return n;
      if (!ISINT(c) && c && fpr_in_heap(c) && TID(c) == T_LIST) return n + PREHEADER(c);
      return n + dc_size_in(c, z, immutable);
    }
    default: { /* uniform-V constructor: derive field count */
      if (h->tid == T_LIST) return total; /* a heap nil reached directly (var 0): no fields */
      uw nf = (total - FPR_MANAGED_PREFIX - 8) / sizeof(uw);
      uw n = total;
      V *f = (V *)((char *)v + 8);
      for (uw i = 0; i < nf; i++) n += dc_size_in(f[i], z, immutable);
      return n;
    }
  }
}

static uw dc_size(V v) { return dc_size_in(v, 0, 0); }

/* Admission walks only as much graph as the receiver can accept. A compact
 * source can share subtrees whose copied representation is exponential.
 * Saturating subtraction and a depth ceiling refuse it before any copy. */
static int budget_take(uw *left, uw bytes) {
  if (bytes > *left) return 0;
  *left -= bytes; return 1;
}
static int budget_cells(uw *left, uw count, uw width) {
  if (count > ((uw)-1 - 31) / width) return 0;
  return budget_take(left, dc_rawsz(count * width));
}
static int dc_budget(V v, uw *left, unsigned depth) {
  if (ISINT(v) || !v) return 1;
  if (depth > 256) return 0;
  if (!fpr_in_heap(v)) {
    uw pid = img_foreign((const void *)v);
    if (!pid) return 1;
    uw raw = img_static_raw(v, pid);
    if (raw > (uw)-1 - 31 || !budget_take(left, dc_cellsz(raw))) return 0;
    return TID(v) != T_RESULT || dc_budget(*(V *)((char *)v + 8), left, depth + 1);
  }
  uw total = PREHEADER(v);
  switch (TID(v)) {
    case T_ACTOR: return 1;
    case T_VEC: {
      vec_t *x = (vec_t *)v;
      if (!budget_take(left, dc_cellsz(sizeof(vec_t)))) return 0;
      if (x->shape_len && !budget_cells(left, x->shape_len, sizeof(vec_shape_t))) return 0;
      if (x->ncols && (!budget_cells(left, x->ncols, sizeof(col_t *)) ||
                       !budget_cells(left, VKINDS_BYTES(x->ncols), 1))) return 0;
      for (uw k = 0; k < x->ncols; k++) {
        if (!x->cols[k]) continue;
        if (!budget_take(left, dc_rawsz(sizeof(col_t)))) return 0;
        if (x->len && !budget_cells(left, x->len, sizeof(uw))) return 0;
        if (!VK_RAW(x->kinds[k]))
          for (uw i = 0; i < x->len; i++)
            if (!dc_budget((V)x->cols[k]->base[i], left, depth + 1)) return 0;
      }
      return 1;
    }
    case T_SSTR: fpr_cpanic("send/keep: SString is linear-local");
    case T_STR: case T_BITS: case T_DEVICE: case T_REGISTER: return budget_take(left, total);
    case T_PAP: {
      pap_t *p = (pap_t *)v;
      if (img_foreign((const void *)p->fn))
        fpr_actor_fail("send: a function of another process cannot leave it (its code goes when that process ends)");
      if (!budget_take(left, total)) return 0;
      for (uw i = 0; i < p->nargs; i++) if (!dc_budget((V)p->args[i], left, depth + 1)) return 0;
      return 1;
    }
    case T_STORED_LIST: case T_LIST: {
      V c = v;
      unsigned heads;
      while (!ISINT(c) && fpr_in_heap(c) && (heads = spine_payloads(c))) {
        if (!budget_take(left, PREHEADER(c))) return 0;
        for (unsigned i=0; i<heads; ++i) if (!dc_budget(spine_slots(c)[i], left, depth + 1)) return 0;
        c = spine_slots(c)[heads];
      }
      if (!ISINT(c) && c && fpr_in_heap(c) && TID(c) == T_LIST)
        return budget_take(left, PREHEADER(c));
      return dc_budget(c, left, depth + 1);
    }
    default: {
      if (!budget_take(left, total)) return 0;
      uw nf = (total - FPR_MANAGED_PREFIX - 8) / sizeof(uw);
      V *fields = (V *)((char *)v + 8);
      for (uw i = 0; i < nf; i++) {
        V child = fields[i];
        if (child && !ISINT(child) && !dc_budget(child, left, depth + 1)) return 0;
      }
      return 1;
    }
  }
}

static V dc_dup(V v, dctx_t *c); /* fwd */

static V dc_cell(V v, dctx_t *c, uw total) {
  char *p = c->hp;
  if (c->end && p + total > c->end) { c->overflow = 1; return 0; }
  c->hp += total;
  allocation_header(p,total,c->sl,FPR_MANAGED_PREFIX);
  __builtin_memcpy(p+FPR_MANAGED_PREFIX,(char *)v,total-FPR_MANAGED_PREFIX);
  return (V)(p+FPR_MANAGED_PREFIX);
}

/* a FRESH cell in the slab (no source memcpy): the vec copier builds
 * its header/cols/data cells directly */
static V dc_bump_size(dctx_t *c, uw raw,uw prefix) {
  uw total = (raw+prefix+15)&~(uw)15;
  char *p = c->hp;
  if (c->end && p + total > c->end) { c->overflow = 1; return 0; }
  c->hp += total;
  allocation_header(p,total,c->sl,prefix);
  /* Generic constructor walkers include alignment padding in their field
   * count. A foreign image's nullary constructor only supplies its header;
   * clear the remaining bytes just as fpr_alloc does before copying it. */
  if (total-prefix>raw) __builtin_memset(p+prefix+raw,0,total-prefix-raw);
  return (V)(p+prefix);
}

static V dc_bump(dctx_t *c,uw raw) { return dc_bump_size(c,raw,FPR_MANAGED_PREFIX); }
static V dc_buffer(dctx_t *c,uw raw) { return dc_bump_size(c,raw,FPR_RAW_PREFIX); }

static V dc_dup(V v, dctx_t *c) {
  if (ISINT(v) || !v) return v;
  if (c && c->mut_root && v == c->mut_root) {
    struct fpr_pool *r = c->region;
    c->mut_root = 0; c->region = 0;
    V n = dc_dup(v, c);
    c->region = r; c->mut_root = v;
    return n;
  }
  if (!fpr_in_heap(v)) {
    uw pid = img_foreign((const void *)v);
    if (!pid) return v;
    uw raw = img_static_raw(v, pid);
    V n = dc_bump(c, raw);
    if (c->overflow) return 0;
    __builtin_memcpy((char *)n, (char *)v, raw);
    if (TID(v) == T_RESULT) {
      *(V *)((char *)n + 8) = dc_dup(*(V *)((char *)v + 8), c);
      if (c->overflow) return 0;
    }
    return n;
  }
  if (c && (dc_retained(v, c->retain) || dc_outside(v, c->region))) return v;
  if (c && c->share) { V f = dc_share_get(c->share, v); if (f) return f; }
  uw total = PREHEADER(v);
  hdr_t *h = (hdr_t *)v;
  switch (h->tid) {
    case T_VEC: {
      if (c && c->movevec && vec_movable_here(v)) return v; /* the handle crosses; the storage stays put */
      if (c && c->movevec) c->released = 1; /* copied: the boundary releases the original after the copy */
      if (c->novec) fpr_cpanic(c->novec);
      /* the whole vector -- header, col_t's, column spans -- lands in
       * the message slab: one message = one slab, vectors included.
       * cap = len (tight): a later push on the receiver's side grows
       * through fpr_realloc into ITS pool; the slab cell is then
       * "freed" as a no-op and dies with the slab at root drop. */
      vec_t *x = (vec_t *)v;
      vec_t *n = (vec_t *)dc_bump(c, sizeof(vec_t));
      if (c->overflow) return 0;
      if (c->share) dc_share_put(c->share, v, (V)n);
      n->tid = T_VEC;
      n->var = x->var;
      n->len = x->len; n->eltid = x->eltid; n->elvar = x->elvar;
      n->ncols = x->ncols; n->kinds = 0; n->cols = 0;
      n->shape_len=x->shape_len; n->shape=0;
      if (x->shape_len) {
        n->shape=(vec_shape_t *)dc_buffer(c,x->shape_len*sizeof(vec_shape_t));
        if (c->overflow) return 0;
        __builtin_memcpy(n->shape,x->shape,x->shape_len*sizeof(vec_shape_t));
      }
      if (x->ncols) {
        n->cols = (col_t **)dc_buffer(c, x->ncols * sizeof(col_t *));
        if (c->overflow) return 0;
        n->kinds = (uint8_t *)dc_buffer(c, VKINDS_BYTES(x->ncols));
        if (c->overflow) return 0;
        for (uw k = 0; k < VKINDS_BYTES(x->ncols); k++) n->kinds[k] = k < x->ncols ? x->kinds[k] : 0;
        for (uw k = 0; k < x->ncols; k++) n->cols[k] = 0;
      }
      for (uw k = 0; k < x->ncols; k++) {
        if (!x->cols[k]) continue;
        col_t *nc = (col_t *)dc_buffer(c, sizeof(col_t));
        if (c->overflow) return 0;
        nc->cap = 0;
        nc->base = 0;
        if (x->len) {
          nc->base = (uw *)dc_buffer(c, x->len * sizeof(uw));
          if (c->overflow) return 0;
          nc->cap = x->len;
          if (VK_RAW(x->kinds[k]))
            __builtin_memcpy(nc->base, x->cols[k]->base,
                             x->len * sizeof(uw));
          else /* boxed column: elements are Vs, copy them too */
            for (uw i = 0; i < x->len; i++) {
              nc->base[i] = (uw)dc_dup((V)x->cols[k]->base[i], c);
              if (c->overflow) return 0;
            }
        }
        n->cols[k] = nc;
      }
      return (V)n;
    }
    case T_ACTOR: return v;
    case T_STR: case T_BITS: case T_DEVICE: case T_REGISTER: {
      V n = dc_cell(v, c, total);
      if (n && c->share) dc_share_put(c->share, v, n);
      return n;
    }
    case T_PAP: {
      V n = dc_cell(v, c, total);
      if (c->overflow) return 0;
      if (c->share) dc_share_put(c->share, v, n);
      pap_t *p = (pap_t *)n;
      for (uw i = 0; i < p->nargs; i++) {
        p->args[i] = (uw)dc_dup((V)p->args[i], c);
        if (c->overflow) return 0;
      }
      return n;
    }
    case T_STORED_LIST: case T_LIST: {
      if (!spine_payloads(v)) { /* heap nil */
        V n = dc_cell(v, c, total);
        if (n && c->share) dc_share_put(c->share, v, n);
        return n;
      }
      V first = 0, *patch = &first;
      V cur = v;
      unsigned heads;
      while (!ISINT(cur) && fpr_in_heap(cur) && (heads = spine_payloads(cur)) && !(c && (dc_retained(cur, c->retain) || dc_outside(cur, c->region)))) {
        if (c && c->share) {
          V f = dc_share_get(c->share, cur);
          if (f) { *patch = f; return first; } /* a shared tail: already copied */
        }
        V n = dc_cell(cur, c, PREHEADER(cur));
        if (c->overflow) return 0;
        if (c->share) dc_share_put(c->share, cur, n);
        *patch = n;
        for (unsigned i=0; i<heads; ++i) {
          spine_slots(n)[i] = dc_dup(spine_slots(cur)[i], c);
          if (c->overflow) return 0;
        }
        patch = &spine_slots(n)[heads];
        cur = spine_slots(cur)[heads];
      }
      *patch = dc_dup(cur, c);
      return first;
    }
    default: {
      uw nf = (total - FPR_MANAGED_PREFIX - 8) / sizeof(uw);
      V n = dc_cell(v, c, total);
      if (c->overflow) return 0;
      if (c->share) dc_share_put(c->share, v, n);
      V *f = (V *)((char *)n + 8);
      for (uw i = 0; i < nf; i++) {
        /* dc_cell already copied immediate fields, including correlation
         * IDs in request tuples. Only references can require rewriting. */
        V child = f[i];
        if (!child || ISINT(child)) continue;
        f[i] = dc_dup(child, c);
        if (c->overflow) return 0;
      }
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
static unsigned clz64(uint64_t x);
uw fpr_msg_slab_charge(uw need) {
  if (!need) return 0;
  if (need > (uw)-1 - sizeof(fpr_slab_t) - FPR_SLAB_PAD - 32) return (uw)-1;
  uw want = need + sizeof(fpr_slab_t) + FPR_SLAB_PAD + 32;
  if (want < MSG_SLAB_SZ) want = MSG_SLAB_SZ;
  /* The ordinary floor is already a power of two. Oversized graphs and
   * non-power-of-two floors round up with one leading-zero count. */
  if (!(want & (want - 1))) return want;
  if (want > ((uw)-1 >> 1)) return (uw)-1;
  return (uw)1 << (64 - clz64(want - 1));
}
/* Charge a whole potential message slab per queued graph. Packing can share
 * slabs, so this deliberately overcounts; it includes the slab floor and
 * buddy rounding. Allocator arenas and the sender's reusable hold are separate.
 * Size walking does not allocate or park, so the hart-local copy pid is safe. */
uw fpr_msg_charge_to(V v, uw pid, int shared, uw limit) {
  if (ISINT(v) || !v) return 0;
  fpr_hart_t *h = fpr_hart();
  uw prior = h ? h->copy_pid : 0;
  if (h) h->copy_pid = pid;
  uw left = limit;
  int fits = dc_budget(v, &left, 0);
  uw need = limit - left;
  if (h) h->copy_pid = prior;
  if (!fits) return (uw)-1;
  if (shared && !ISINT(v) && fpr_in_heap(v) && TID(v) != T_ACTOR) {
    fpr_slab_t *sl = *(fpr_slab_t **)((char *)v - 8);
    if (sl && (uw)(sl->end - (char *)sl) > need) need = (uw)(sl->end - (char *)sl);
  }
  return fpr_msg_slab_charge(need);
}
#if FPR_INL_CELL
/* a slot-carried message is one cell of exactly its preheader total (its
 * fields add nothing: fpr_msg_inline_size admits only what dc_budget counts
 * as free), so its charge is fpr_msg_charge_to's without the walk */
uw fpr_msg_inline_charge(uw total) { return fpr_msg_slab_charge(total); }
#endif
static fpr_slab_t *msg_slab_new(uw need) {
  if (need>(uw)-1-sizeof(fpr_slab_t)-FPR_SLAB_PAD) fpr_cpanic("message allocation size overflow");
  fpr_slab_t *sl = 0;
  uw want = need + sizeof(fpr_slab_t) + FPR_SLAB_PAD;
  if (want < MSG_SLAB_SZ) want = MSG_SLAB_SZ;
  if (!fpr_mem_own && fpr_is_process && fpr_grow_memory) sl = grant_take(need);
  if (!sl) {
    fpr_grant_t g = fpr_grow_counted(want, 6); /* msg */
    if (!g.ptr || g.size < need + sizeof(fpr_slab_t) + FPR_SLAB_PAD)
      fpr_exhausted("send: no block for the message slab");
    sl = (fpr_slab_t *)g.ptr;
    sl->end = (char *)g.ptr + g.size;
  }
  sl->owner = 0; /* ownerless from birth: freed wholesale on last drop */
  sl->escaped = 0;
  sl->holds = 0;
  sl->promoted = 0;
  sl->pushed = 0;
  sl->hp = fpr_slab_start(sl);
  sl->next = 0;
  return sl;
}
/* Build a flat outgoing string without first allocating the joined bytes in
 * the sender's pool. The caller owns the slab hold until ARC promotion. */
uw fpr_msg_concat_size(V left, V right) {
  str_t *x = (str_t *)left, *y = (str_t *)right;
  if (ISINT(left) || ISINT(right) || x->tid != T_STR || y->tid != T_STR)
    fpr_trap("sendConcat: not strings");
  uw overhead = sizeof(str_t) + FPR_MANAGED_PREFIX + 15 + sizeof(fpr_slab_t) + FPR_SLAB_PAD;
  if (x->len > (uw)-1 - overhead || y->len > (uw)-1 - overhead - x->len)
    fpr_trap("sendConcat: string size overflow");
  return dc_cellsz(sizeof(str_t) + x->len + y->len);
}
/* Reserve a construction hold independently of the sender's packing hold.
 * Large dedicated cells leave the current packing slab intact. */
static V msg_build_cell(uw raw, uw size, fpr_slab_t **hold) {
  fpr_slab_t **slot = fpr_acb_msg_slot(fpr_hart()->current);
  int pack = size <= MSG_SLAB_SZ - sizeof(fpr_slab_t) - FPR_SLAB_PAD;
  fpr_slab_t *sl = pack ? *slot : 0;
  if (sl && size > (uw)(sl->end - sl->hp)) {
    *slot = 0;
    fpr_slab_unhold(sl, 0);
    sl = 0;
  }
  if (sl) {
    fpr_lock(&arc_lock);
    sl->holds++;
    fpr_unlock(&arc_lock);
  } else {
    sl = msg_slab_new(size);
    sl->holds = pack ? 2 : 1;
    if (pack) *slot = sl;
    FPR_COST_ADD(fpr_hart(), cost_msg_slabs, 1);
  }
  *hold = sl;
  dctx_t c = {.hp=sl->hp, .sl=sl, .end=sl->end};
  V root = dc_bump(&c, raw);
  sl->hp = c.hp;
  return root;
}
uw fpr_msg_pair_size(void) { return dc_cellsz(8 + 2 * sizeof(V)); }
V fpr_msg_int_pair(V a, V b, fpr_slab_t **hold) {
  hdr_t *t = (hdr_t *)msg_build_cell(8 + 2 * sizeof(V), fpr_msg_pair_size(), hold);
  t->tid = T_TUP2; t->var = 0;
  FPR_FLD(t, 0) = a; FPR_FLD(t, 1) = b;
  return (V)t;
}
V fpr_msg_concat(V left, V right, uw size, fpr_slab_t **hold) {
  str_t *x = (str_t *)left, *y = (str_t *)right;
  uw n = x->len + y->len;
  str_t *s = (str_t *)msg_build_cell(sizeof(str_t) + n, size, hold);
  s->tid = T_STR;
  s->var = 0;
  s->len = n;
  __builtin_memcpy(s->bytes, x->bytes, x->len);
  __builtin_memcpy(s->bytes + x->len, y->bytes, y->len);
  return (V)s;
}

/* holds--; the slab goes home once nothing keeps it (arc_lock) */
static void slab_unhold_locked(fpr_slab_t *sl, uw count) {
  sl->holds -= count;
  if (sl->holds == 0 && sl->escaped == 0 && !sl->owner) fpr_slab_release(sl);
}
void fpr_slab_unhold(fpr_slab_t *sl, int locked) {
  if (!locked) fpr_lock(&arc_lock);
  slab_unhold_locked(sl, 1);
  if (!locked) fpr_unlock(&arc_lock);
}
void fpr_slabs_unhold(fpr_slab_t **sls, uw n) {
  fpr_lock(&arc_lock);
  for (uw i = 0; i < n;) {
    uw first = i++;
    while (i < n && sls[i] == sls[first]) i++;
    slab_unhold_locked(sls[first], i - first);
  }
  fpr_unlock(&arc_lock);
}
static void slab_free_ownerless(fpr_slab_t *sl); /* fwd: defined by the state copies */
static V msg_copy_held_in(V v, int fresh, uw pid, fpr_slab_t **hold) {
  if (ISINT(v) || !v) {
#ifdef FPR_COST_PROBE
    fpr_hart_t *probe_hart = fpr_hart();
    FPR_COST_ADD(probe_hart, cost_copies, 1);
#endif
    return v;
  }
  fpr_hart_t *h = fpr_hart();
  if (h) h->copy_pid = pid;
  if (!fpr_in_heap(v)) { /* statics and bare actor handles: an image lookup */
    uw need = dc_size(v);
    FPR_COST_ADD(h, cost_copies, 1);
    FPR_COST_ADD(h, cost_copy_bytes, need);
    if (!need) return dc_dup(v, 0);
    /* a foreign static, or a Result whose payload is on the heap: copy below */
  }
  fpr_slab_t **slot = (!fresh && h && h->current) ? fpr_acb_msg_slot(h->current) : 0;
  fpr_slab_t *sl = slot ? *slot : 0;
  /* One pass: copy straight into the packing slab with its end as the
   * limit, commit the bump pointer on success.  The exact size walk
   * (dc_size) remains only for the overflow fallbacks below.  The
   * uncommitted bytes of a failed copy are never published; the next
   * copy overwrites them. */
  if (sl) {
    dctx_t c = {.hp=sl->hp, .sl=sl, .end=sl->end};
    V r = dc_dup(v, &c);
    if (!c.overflow) {
      uw need = c.hp - sl->hp;
      FPR_COST_ADD(h, cost_copies, 1);
      FPR_COST_ADD(h, cost_copy_bytes, need);
      sl->hp = c.hp;
      if (need && hold) {
        fpr_lock(&arc_lock);
        sl->holds++;
        fpr_unlock(&arc_lock);
        *hold = sl;
      }
      return r;
    }
    /* full: the sender's hold ends */
    *slot = 0;
    fpr_slab_unhold(sl, 0);
    sl = 0;
  }
  /* A flat heap string carries its exact copy footprint. Request room for
   * it on the first allocation, even when it exceeds the packing floor. */
  uw first_need = MSG_SLAB_SZ - sizeof(fpr_slab_t);
  if (TID(v) == T_STR && fpr_in_heap(v) && PREHEADER(v) > first_need)
    first_need = PREHEADER(v);
  sl = msg_slab_new(first_need);
  FPR_COST_ADD(fpr_hart(), cost_msg_slabs, 1);
  /* Allocation above can park; another actor on this hart can change it. */
  h = fpr_hart(); /* the sender may also have migrated while parked */
  if (h) h->copy_pid = pid;
  {
    dctx_t c = {.hp=sl->hp, .sl=sl, .end=sl->end};
    V r = dc_dup(v, &c);
    if (!c.overflow) {
      uw need = c.hp - sl->hp;
      FPR_COST_ADD(h, cost_copies, 1);
      FPR_COST_ADD(h, cost_copy_bytes, need);
      sl->hp = c.hp;
      if (!need) { slab_free_ownerless(sl); return r; } /* unreachable today: heap graphs copy at least one cell */
      if (slot && need + sizeof(fpr_slab_t) + FPR_SLAB_PAD <= MSG_SLAB_SZ) {
        sl->holds = 1; /* the sender keeps packing into it */
        *slot = sl;
      }
      if (hold) {
        fpr_lock(&arc_lock);
        sl->holds++;
        fpr_unlock(&arc_lock);
        *hold = sl;
      }
      return r;
    }
  }
  /* Bigger than a floor slab: the exact two-pass path, a slab of its own. */
  slab_free_ownerless(sl);
  {
    uw need = dc_size(v);
    FPR_COST_ADD(fpr_hart(), cost_copies, 1);
    FPR_COST_ADD(fpr_hart(), cost_copy_bytes, need);
    sl = msg_slab_new(need);
    FPR_COST_ADD(fpr_hart(), cost_msg_slabs, 1);
    h = fpr_hart();
    if (h) h->copy_pid = pid;
    dctx_t c = {sl->hp, sl};
    V r = dc_dup(v, &c);
    sl->hp = c.hp;
    if (hold) {
      fpr_lock(&arc_lock);
      sl->holds++;
      fpr_unlock(&arc_lock);
      *hold = sl;
    }
    return r;
  }
}
static V msg_copy_in(V v, int fresh, uw pid) { return msg_copy_held_in(v, fresh, pid, 0); }
/* copy v into the sender's message slab; returns the new root (or v
 * itself when there is nothing to copy: ints, statics, bare handles) */
#ifndef FPR_MSG_PACK
#define FPR_MSG_PACK 1 /* 0: a slab per message (the bisecting switch) */
#endif
V fpr_msg_copy(V v) { return msg_copy_in(v, !FPR_MSG_PACK, fpr_current_pid()); }
/* ... for a receiver in process pid: what may leave a mortal image is
 * decided against it (img_foreign) */
V fpr_msg_copy_to(V v, uw pid) { return msg_copy_in(v, !FPR_MSG_PACK, pid); }
V fpr_msg_copy_held_to(V v, uw pid, fpr_slab_t **hold) { return msg_copy_held_in(v, !FPR_MSG_PACK, pid, hold); }

/* ---- small flat messages, carried in the ring (actors.c) -------------
 * QOS docs/2026-11-09-ACTOR-ROUND-TRIP.md, step 3.  A message that is ONE
 * heap cell whose every field passes by value -- ints, nil, actor handles,
 * statics of the receiver's own image: exactly the fields dc_dup returns
 * unchanged -- needs no message slab, no generic copy and no ARC entry.
 * The sender copies the cell into its channel slot's cell area; the
 * receiver copies it into its own memory before it frees the slot, so
 * what it holds is an ordinary local value.  A cell in a slot carries
 * &inl_mark as its slab word: never promoted, so a drop of one is the
 * lock-free no-op (arc_decref_in's pre-check). */
#if FPR_INL_CELL
static fpr_slab_t inl_mark;
uw fpr_msg_inline_size(V v, uw pid) {
  if (ISINT(v) || !v || !fpr_in_heap(v)) return 0;
  uw tid = TID(v);
  if (tid == T_LIST || (tid >= T_STR && tid <= T_STORED_LIST)) return 0;
  uw total = PREHEADER(v);
  if (total > FPR_INL_CELL) return 0;
  uw nf = (total - FPR_MANAGED_PREFIX - 8) / sizeof(uw);
  V *f = (V *)((char *)v + 8);
  uw ok = total;
  for (uw i = 0; i < nf; i++) {
    V x = f[i];
    if (ISINT(x) || !x) continue;
    if (fpr_in_heap(x)) {
      if (TID(x) == T_ACTOR) continue;
      ok = 0;
      break;
    }
    uw owner = image_owner_pid((const void *)x);
    if (owner && owner != pid) { ok = 0; break; }
  }
  return ok;
}
V fpr_msg_inline_put(char *cell, V v, uw total) {
  allocation_header(cell, total, &inl_mark, FPR_MANAGED_PREFIX);
  __builtin_memcpy(cell + FPR_MANAGED_PREFIX, (char *)v, total - FPR_MANAGED_PREFIX);
  return (V)(cell + FPR_MANAGED_PREFIX);
}
uw fpr_msg_inline_total(V v) { return PREHEADER(v); }
/* the receiver's own copy, in its current pool or region */
V fpr_msg_inline_take(V v) {
  uw raw = PREHEADER(v) - FPR_MANAGED_PREFIX;
  V n = fpr_alloc(raw);
  __builtin_memcpy((char *)n, (char *)v, raw);
  return n;
}
#endif /* FPR_INL_CELL */
/* An unpublished actor's entry gets an independent ownerless slab.  Its
 * hold replaces an ARC root reservation: no table growth can panic after
 * admission.  Captures can still escape through the usual ARC rules; the
 * slab returns only after both that escape count and this hold reach zero. */
int fpr_entry_copy_try(V v, uw pid, V *out, fpr_slab_t **hold) {
  fpr_hart_t *h = fpr_hart();
  h->copy_pid = pid;
  uw need = dc_size(v);
  *hold = 0;
  if (!need) { *out = dc_dup(v, 0); return 1; }
  if (need > (uw)-1 - sizeof(fpr_slab_t) - FPR_SLAB_PAD) return 0;
  fpr_slab_t *sl = fpr_slab_new(need + sizeof(fpr_slab_t) + FPR_SLAB_PAD);
  if (!sl) return 0;
  sl->owner = 0; sl->escaped = 0; sl->holds = 1; sl->promoted = 0; sl->pushed = 0;
  sl->hp = fpr_slab_start(sl); sl->next = 0;
  /* The slab allocation can park this actor and resume it on another hart. */
  fpr_hart()->copy_pid = pid;
  dctx_t c = {sl->hp, sl};
  *out = dc_dup(v, &c);
  sl->hp = c.hp;
  *hold = sl;
  FPR_COST_ADD(h, cost_copies, 1);
  FPR_COST_ADD(h, cost_copy_bytes, need);
  FPR_COST_ADD(h, cost_msg_slabs, 1);
  return 1;
}
/* ... into a slab of its own: Sys.arena's transfer copy, freed by hand */
V fpr_msg_copy_fresh(V v) { return msg_copy_in(v, 1, fpr_current_pid()); }

/* keep: retain a received value past its message's drop -- a deep copy
 * into the CALLER'S OWN pool (fpr_alloc), vectors included (v2: a
 * kept vector is the keeper's own; nothing outlives its slab by
 * reference).  This is the one retention annotation the turn-scoped
 * model needs. */
static V kp_dup(V v);
/* Keep the ordinary one-head loop constant-width. For private cells the
 * encoded width determines how many payloads precede the tail. */
static inline __attribute__((always_inline)) V keep_spine(V v, int packed) {
  V first = 0, *patch = &first;
  V cur = v;
  unsigned heads;
  while (!ISINT(cur) && fpr_in_heap(cur) && (heads = packed ? spine_payloads(cur) : (TID(cur) == T_LIST && ((hdr_t *)cur)->var == 1))) {
    uw t = PREHEADER(cur);
    V n = fpr_alloc(t - FPR_MANAGED_PREFIX);
    __builtin_memcpy((void *)n, (void *)cur, t - FPR_MANAGED_PREFIX);
    *patch = n;
    for (unsigned i=0; i<heads; ++i) spine_slots(n)[i] = kp_dup(spine_slots(cur)[i]);
    patch = &spine_slots(n)[heads];
    cur = spine_slots(cur)[heads];
  }
  *patch = kp_dup(cur);
  return first;
}

static V kp_dup(V v) {
  if (ISINT(v) || !v || !fpr_in_heap(v)) return v;
  uw total = PREHEADER(v);
  hdr_t *h = (hdr_t *)v;
  switch (h->tid) {
    case T_VEC: {
      { fpr_hart_t *mh = fpr_hart(); if (mh && mh->copy_movevec && vec_movable_here(v)) return v; } /* a turn's final state */
      vec_t *x = (vec_t *)v;
      vec_t *n = (vec_t *)fpr_alloc(sizeof(vec_t));
      n->tid = T_VEC;
      n->var = x->var;
      n->len = x->len; n->eltid = x->eltid; n->elvar = x->elvar;
      n->ncols = x->ncols; n->kinds = 0; n->cols = 0;
      n->shape_len=x->shape_len; n->shape=0;
      if (x->shape_len) {
        n->shape=(vec_shape_t *)fpr_alloc_raw(x->shape_len*sizeof(vec_shape_t));
        __builtin_memcpy(n->shape,x->shape,x->shape_len*sizeof(vec_shape_t));
      }
      if (x->ncols) {
        n->cols = (col_t **)fpr_alloc_raw(x->ncols * sizeof(col_t *));
        n->kinds = (uint8_t *)fpr_alloc_raw(VKINDS_BYTES(x->ncols));
        for (uw k = 0; k < VKINDS_BYTES(x->ncols); k++) n->kinds[k] = k < x->ncols ? x->kinds[k] : 0;
        for (uw k = 0; k < x->ncols; k++) n->cols[k] = 0;
      }
      for (uw k = 0; k < x->ncols; k++) {
        if (!x->cols[k]) continue;
        col_t *nc = (col_t *)fpr_alloc_raw(sizeof(col_t));
        nc->cap = 0;
        nc->base = 0;
        if (x->len) {
          nc->base = (uw *)fpr_alloc_raw(x->len * sizeof(uw));
          nc->cap = x->len;
          if (VK_RAW(x->kinds[k]))
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
      V n = fpr_alloc(total - FPR_MANAGED_PREFIX);
      __builtin_memcpy((void *)n, (void *)v, total - FPR_MANAGED_PREFIX);
      return n;
    }
    case T_PAP: {
      V n = fpr_alloc(total - FPR_MANAGED_PREFIX);
      __builtin_memcpy((void *)n, (void *)v, total - FPR_MANAGED_PREFIX);
      pap_t *p = (pap_t *)n;
      for (uw i = 0; i < p->nargs; i++) p->args[i] = (uw)kp_dup((V)p->args[i]);
      return n;
    }
    case T_LIST:
      if (h->var == 1) return keep_spine(v, 0);
      /* Heap Nil has no fields. */
      {
        V n = fpr_alloc(total - FPR_MANAGED_PREFIX);
        __builtin_memcpy((void *)n, (void *)v, total - FPR_MANAGED_PREFIX);
        return n;
      }
    case T_STORED_LIST:
      return keep_spine(v, 1);
    default: {
      uw nf = (total - FPR_MANAGED_PREFIX - 8) / sizeof(uw);
      V n = fpr_alloc(total - FPR_MANAGED_PREFIX);
      __builtin_memcpy((void *)n, (void *)v, total - FPR_MANAGED_PREFIX);
      V *f = (V *)((char *)n + 8);
      for (uw i = 0; i < nf; i++) f[i] = kp_dup(f[i]);
      return n;
    }
  }
}
/* kp_dup's walk without the copy: does copying v cost at least *left bytes?
 * Counts what kp_dup would allocate (a cell each time it is reached, a moved
 * Vector nothing) and stops as soon as the answer is yes, so the walk never
 * goes further than the bytes it asks about. */
static int kp_reaches(V v, uw *left) {
  for (;;) {
    if (ISINT(v) || !v || !fpr_in_heap(v)) return 0;
    hdr_t *h = (hdr_t *)v;
    if (h->tid == T_ACTOR || h->tid == T_SSTR) return 0; /* shared; refused by the copy */
    if (h->tid == T_VEC) {
      fpr_hart_t *mh = fpr_hart();
      if (mh && mh->copy_movevec && vec_movable_here(v)) return 0;
      vec_t *x = (vec_t *)v;
      uw n = dc_cellsz(sizeof(vec_t));
      for (uw k = 0; k < x->ncols; k++) if (x->cols[k]) n += dc_rawsz(sizeof(col_t)) + dc_rawsz(x->len * sizeof(uw));
      if (n >= *left) return 1;
      *left -= n;
      for (uw k = 0; k < x->ncols; k++)
        if (x->cols[k] && !VK_RAW(x->kinds[k]))
          for (uw i = 0; i < x->len; i++) if (kp_reaches((V)x->cols[k]->base[i], left)) return 1;
      return 0;
    }
    uw total = PREHEADER(v);
    if (total >= *left) return 1;
    *left -= total;
    switch (h->tid) {
      case T_STR: case T_BITS: case T_DEVICE: case T_REGISTER: return 0;
      case T_PAP: {
        pap_t *pp = (pap_t *)v;
        for (uw i = 0; i < pp->nargs; i++) if (kp_reaches((V)pp->args[i], left)) return 1;
        return 0;
      }
      case T_STORED_LIST: case T_LIST: {
        unsigned heads = spine_payloads(v);
        if (!heads) return 0;
        for (unsigned i=0; i<heads; ++i) if (kp_reaches(spine_slots(v)[i], left)) return 1;
        v = spine_slots(v)[heads];
        continue;
      }
      default: {
        uw nf = (total - FPR_MANAGED_PREFIX - 8) / sizeof(uw);
        V *f = (V *)((char *)v + 8);
        for (uw i = 0; i < nf; i++) if (kp_reaches(f[i], left)) return 1;
        return 0;
      }
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
    case T_STORED_LIST: case T_LIST: {
      V c = v;
      unsigned heads;
      while (!ISINT(c) && fpr_in_heap(c) && (heads = spine_payloads(c))) {
        for (unsigned i=0; i<heads; ++i) if (has_vec(spine_slots(c)[i])) return 1;
        c = spine_slots(c)[heads];
      }
      /* the tail: the static nil (not in the heap), a nil ON the heap -- a
       * primitive's, or another process's nil, copied with the message it
       * ended (its image's statics are foreign there) -- whose cell holds
       * nothing, or an improper tail.  The heap nil used to be followed as
       * a list again, onto itself: a Sys.loop whose state held a list a
       * program had sent spun for ever (dc_size had the same fix). */
      if (!ISINT(c) && c && fpr_in_heap(c) && TID(c) == T_LIST) return 0;
      return has_vec(c);
    }
    default: {
      uw total = PREHEADER(v);
      uw nf = (total - FPR_MANAGED_PREFIX - 8) / sizeof(uw);
      V *f = (V *)((char *)v + 8);
      for (uw i = 0; i < nf; i++)
        if (has_vec(f[i])) return 1;
      return 0;
    }
  }
}

/* a boundary's old state dies: every Vector in it that the copy COPIED (one
 * not movable here) is released, the moved ones live on in the new state.
 * Vectors are linear: the dying state is their one owner. */
static int vec_movable_here(V v);
static void vec_release_in(V v) {
  if (ISINT(v) || !v || !fpr_in_heap(v)) return;
  hdr_t *h = (hdr_t *)v;
  switch (h->tid) {
    case T_VEC: if (!vec_movable_here(v)) fpr_vec_release(v); return;
    case T_ACTOR: case T_STR: case T_BITS: case T_DEVICE: case T_REGISTER:
    case T_SSTR: return;
    case T_PAP: {
      pap_t *p = (pap_t *)v;
      for (uw i = 0; i < p->nargs; i++) vec_release_in((V)p->args[i]);
      return;
    }
    case T_STORED_LIST: case T_LIST: {
      V c = v;
      unsigned heads;
      while (!ISINT(c) && fpr_in_heap(c) && (heads = spine_payloads(c))) {
        for (unsigned i=0; i<heads; ++i) vec_release_in(spine_slots(c)[i]);
        c = spine_slots(c)[heads];
      }
      if (!ISINT(c) && c && fpr_in_heap(c) && TID(c) == T_LIST) return;
      vec_release_in(c);
      return;
    }
    default: {
      uw total = PREHEADER(v);
      uw nf = (total - FPR_MANAGED_PREFIX - 8) / sizeof(uw);
      V *f = (V *)((char *)v + 8);
      for (uw i = 0; i < nf; i++) vec_release_in(f[i]);
      return;
    }
  }
}

static void arena_open(struct fpr_pool **slot, fpr_pool_t *ap) {
  if (cur_pool(fpr_hart())->fixed_heap)
    fpr_actor_fail("fixed heap: scratch arenas require separate admission");
  fpr_pool_init(ap, fpr_bkt_take()); /* bigfree=0 matters: a stack pool
                                      * with garbage there walked it as
                                      * a freelist on any >ceiling alloc */
  if (!ap->buckets) fpr_exhausted("Sys.arena: no memory for a bucket array");
  fpr_bump_close(fpr_hart());
  *slot = (struct fpr_pool *)ap;
}
/* teardown, poolReset-style, under arc_lock (owner/escaped race) */
static void arena_close(struct fpr_pool **slot, fpr_pool_t *ap, struct fpr_pool *prev) {
  fpr_bump_close(fpr_hart());
  fpr_lock(&arc_lock);
  fpr_slab_t *sl = ap->cur;
  while (sl) {
    fpr_slab_t *nx = sl->next;
    if (sl->escaped == 0) slab_home(sl);
    else sl->owner = 0; /* something was sent from inside: orphan it */
    sl = nx;
  }
  fpr_unlock(&arc_lock);
  if (ap->buckets) fpr_bkt_put(ap->buckets); /* a compiler region has none */
  *slot = prev;
}
/* TURN END, the arena staying open for the next turn: everything
 * allocated this turn is dead.  The chain head -- the newest and largest
 * slab, the size the turn's doubling settled on -- stays with its bump
 * pointer rewound; the slabs behind it go home; a slab something escaped
 * from (sent by reference from inside the turn) is orphaned and returns
 * when its last promoted object drops.  The bucket array is cleared, not
 * returned: every recorded free cell was in a slab this walk just rewound,
 * recycled or orphaned (poolReset says the same).  Closing and reopening
 * the arena every turn -- a slab and a bucket array taken and returned,
 * the array zeroed on the way -- was most of a small turn
 * (docs/2026-10-19-RECEIVE-TURN-ARENA.md). */
static void arena_reset(fpr_pool_t *ap) {
  uw pushed = 0; /* did any cell of any slab reach the buckets this turn */
  fpr_bump_close(fpr_hart());
  fpr_lock(&arc_lock);
  fpr_slab_t *sl = ap->cur, *keep = 0;
  while (sl) {
    fpr_slab_t *nx = sl->next;
    pushed |= sl->pushed;
    if (sl->escaped) sl->owner = 0;
    else if (!keep) keep = sl;
    else slab_home(sl);
    sl = nx;
  }
  if (keep) {
    keep->hp = fpr_slab_start(keep);
    keep->next = 0;
    keep->promoted = 0; /* reissued: nothing in it is referenced (fpr_arc_decref) */
    keep->pushed = 0;
  }
  ap->cur = keep;
  ap->bigfree = 0; /* big free blocks were in the slabs just rewound or recycled */
  fpr_unlock(&arc_lock);
  /* nothing pushes after the unlock: a clean slab had no promoted object
   * to drop, an orphaned one is owned by no pool.  A turn that freed
   * nothing leaves the heads as the last zeroing left them. */
  if (pushed && ap->buckets) __builtin_memset(ap->buckets, 0, FPR_NBUCKETS * sizeof(void *));
}
static void no_vec_out(V r, const char *who) {
  if (has_vec(r))
    fpr_cpanic(who);
}

/* ---- transfer slabs ---------------------------------------------------
 * The state that crosses a turn boundary is copied into an ownerless slab
 * of its own (a message slab in all but name).  A scope keeps two: `held`,
 * the state the next turn reads, and `spare`, the slab the previous state
 * was in, kept once nothing else references it, for the next copy -- so a
 * loop in its steady state takes no slab from the buddy at all.  A state
 * that does not fit the spare takes a fresh, bigger slab and the spare goes
 * home; a state slab retired into an occupied spare keeps the larger of the
 * two.  Loop exit and death free both.  A slab a promoted object still
 * pins is never reused: it returns when that object drops, as before. */
/* These frames live on the actor's stack. The reaper visits them before
 * recycling that stack, including when a region is parked in receive or
 * allocation. Keep this separate from the one pending external request:
 * a scoped callback may itself wait for heap admission or a syscall. */
struct fpr_scope {
  struct fpr_scope *previous;
  fpr_pool_t *arena;
  V held;
  fpr_slab_t *spare;
  fpr_slab_t *state_slab, *next_slab; /* each carries one scope hold */
  uw generations;
  int immutable_state, preserve_state;
  uw rx_mark; /* the actor's received-root count at entry: the roots above it
               * were taken inside this region and die at its boundary */
  /* a compiler-placed region (fpr.h): heap-allocated in the base pool, its
   * arena inside it; 0 seq for the stack scopes of Sys.arena/loop/loopWith */
  uw seq;
  struct fpr_pool *prev_override;
  /* the message slab the last received root was charged for (fpr_rx_push):
   * a receive loop's turns are charged a slab once per slab they pin */
  fpr_slab_t *msg_slab;
  /* a pure loop region's copy-out schedule (g_region_cycle): the bytes its
   * last copy produced, and the arena's bump gauge when it was taken */
  uw live_bytes, alloc_mark;
  int receive; /* opened at a receive loop's entry (g_region_open) */
  int mutating; /* its loop runs a consuming twin (REGION_MUT_BIT): see transfer_copy_in */
  uw mut_comp;  /* which component of the packed state the twin writes: 0 unknown
                 * (the whole state), k > 0 the (k-1)th, REGION_MUT_ALL the state */
  int declined; uw declined_bytes; /* transfer_copy_in found too much would survive */
  uw retry_at; /* after a declined copy: the arena gauge to reach before the next try */
  uw decline_run; /* declines since the last copy: each waits twice as long */
  fpr_pool_t ap;
};
static struct fpr_scope *bootstrap_scopes[FPR_NHARTS];
static struct fpr_scope **scope_push(struct fpr_scope *scope) {
  fpr_hart_t *h = fpr_hart();
  struct fpr_scope **head = h->current ? fpr_acb_scope_slot(h->current)
                                     : &bootstrap_scopes[h->id];
  scope->previous = *head;
  scope->arena = 0;
  scope->held = 0;
  scope->spare = 0;
  scope->state_slab = scope->next_slab = 0;
  scope->generations = 0; scope->immutable_state = scope->preserve_state = 0;
  scope->live_bytes = scope->alloc_mark = 0; scope->receive = 0; scope->mutating = 0; scope->mut_comp = 0; scope->declined = 0; scope->declined_bytes = 0; scope->retry_at = 0; scope->decline_run = 0;
  scope->rx_mark = h->current ? fpr_acb_rx(h->current)->n : 0;
  scope->seq = 0;
  scope->prev_override = 0;
  scope->msg_slab = 0;
  *head = scope;
  return head;
}
/* a scope leaves the chain from wherever it is: the copy out of a closing
 * region allocates in the enclosing pool, and that allocation can open a
 * pending call region (region_trip), whose scope then sits ABOVE the one
 * closing.  It belongs to the enclosing call and stays; only `scope` goes. */
static void scope_unlink(struct fpr_scope **head, struct fpr_scope *scope) {
  for (struct fpr_scope **at = head; *at; at = &(*at)->previous)
    if (*at == scope) { *at = scope->previous; return; }
}
/* a turn boundary: the next state (or the arena's result) has just been copied
 * out, so the message roots this region's turn took have no reader left */
static void scope_roots_die(struct fpr_scope *scope) {
  fpr_hart_t *h = fpr_hart(); /* re-read: the actor may have migrated */
  if (h && h->current) fpr_rx_release(h->current, scope->rx_mark);
}
static uw slab_room(fpr_slab_t *sl) { return (uw)(sl->end - fpr_slab_start(sl)); }
/* an ownerless slab nothing references any more goes home (arc_lock: the
 * owner/escaped protocol slab_home's callers keep) */
static void slab_free_ownerless(fpr_slab_t *sl) {
  fpr_lock(&arc_lock);
  slab_home(sl);
  fpr_unlock(&arc_lock);
}
/* Generations stay INSIDE one transfer slab, so even an exported ARC root
 * still pins its whole graph. At most eight turns append before a deep
 * compaction; lack of capacity or any mutable state forces a full copy.
 * Borrowed state is immutable: native constructor reuse requires a fresh,
 * nonescaping root and cannot cross a region reset (Reuse.hs). Foreign code
 * must honor that same value contract; arbitrary writes into tuples are not
 * a supported state API. Vectors/device/register storage never appends.
 * Zero/one restores full copying. Builtin heaps retain their existing path. */
#ifndef FPR_STATE_GENERATIONS
#define FPR_STATE_GENERATIONS 8
#endif
static V transfer_copy_in(V v, struct fpr_scope *scope, const char *novec, int movevec, struct fpr_pool *region, uw survive_limit, V mut_root) {
  fpr_hart_t *h = fpr_hart();
  uw pid = fpr_current_pid();
  fpr_slab_t *retain = scope->state_slab;
  if (FPR_STATE_GENERATIONS <= 1 || !scope->immutable_state || scope->mutating ||
      scope->generations >= FPR_STATE_GENERATIONS ||
      (retain && __atomic_load_n(&retain->promoted, __ATOMIC_ACQUIRE))) retain = 0;
  if (h) { h->copy_pid = pid; h->copy_movevec = (uw)movevec; }
  int immutable = 1;
  /* a region copy: the bytes a tree walk of distinct cells could find -- what
   * the arena bumped since its reset, the state slab, and a slab of slack for
   * the ownerless slabs the state may still reach */
  uw cap = 0;
  if (region) {
    cap = scope->ap.allocated - scope->alloc_mark + (uw)FPR_REGION_SLAB;
    if (scope->state_slab) cap += (uw)(scope->state_slab->hp - fpr_slab_start(scope->state_slab));
  }
  /* in a run of declines (a builder), the walk need only learn that more than
   * the limit survives: it stops there.  The first walk after a copy goes to
   * the cap, where passing it proves sharing rather than survival. */
  int quick = region && survive_limit && scope->decline_run && survive_limit < cap;
  dc_sz_t z = {.retain = retain, .region = region, .left = quick ? survive_limit : cap, .mut_root = mut_root};
  uw need = dc_size_in(v, &z, &immutable);
  if (quick && z.over) {
    if (h) h->copy_movevec = 0;
    scope->declined = 1;
    scope->declined_bytes = survive_limit + 1;
    return v;
  }
  if (retain && !z.over && (!immutable || need > (uw)(retain->end - retain->hp))) {
    retain = 0;
    immutable = 1;
    z.retain = 0; z.left = cap;
    need = dc_size_in(v, &z, &immutable);
  }
  fpr_slab_t *table = 0;
  dc_share_t share;
  /* shared: size again counting each cell once, then copy once.  Either the
   * walk passed the cap, which only sharing can do, or it would decline the
   * copy: a state of versions sharing their tails looks, walked as a tree,
   * like one that survives -- counted once, it may be mostly garbage. */
  if (z.over || (region && survive_limit && need > survive_limit)) {
    retain = 0;
    immutable = 1;
    uw slots = 64;
    while (slots < 2 * (cap / 16)) slots *= 2;
    /* msg_slab_new may park: the actor can migrate */
    table = msg_slab_new(slots * 2 * sizeof(uw));
    h = fpr_hart();
    if (h) { h->copy_pid = pid; h->copy_movevec = (uw)movevec; }
    share.mask = slots - 1; share.n = 0; share.limit = slots / 4 * 3; share.full = 0;
    share.tag = 1; share.occupied = 0;
    share.key = (uw *)fpr_slab_start(table);
    share.val = (V *)(share.key + slots);
    __builtin_memset(share.key, 0, slots * sizeof(uw));
    z.retain = 0; z.share = &share;
    need = dc_size_in(v, &z, &immutable);
    if (share.full) { /* more distinct cells than the region could hold: a tree copy, as before */
      z.share = 0;
      slab_free_ownerless(table);
      table = 0;
      immutable = 1;
      z.left = ~(uw)0; z.over = 0;
      need = dc_size_in(v, &z, &immutable);
      __atomic_fetch_add(&region_shared_full, 1, __ATOMIC_RELAXED);
    } else {
      share.n = 0;
      share.tag = 2; /* the copy's map starts empty: its entries carry the new tag */
      __atomic_fetch_add(&region_shared_copies, 1, __ATOMIC_RELAXED);
    }
  }
  if (h) h->copy_movevec = 0;
  /* a copy that would keep more than the limit frees too little to pay for
   * itself (a builder: all it allocates is its result); the caller keeps the
   * arena and asks again once it has grown past this size */
  if (survive_limit && need > survive_limit) {
    if (table) slab_free_ownerless(table);
    scope->declined = 1;
    scope->declined_bytes = need;
    return v;
  }
  FPR_COST_ADD(h, cost_copies, 1);
  FPR_COST_ADD(h, cost_copy_bytes, need);
  FPR_COST_ADD(h, cost_state_copies, 1);
  FPR_COST_ADD(h, cost_state_bytes, need);
  scope->immutable_state = immutable;
  if (retain && (need || dc_retained(v, retain))) {
    scope->preserve_state = 1; /* cancellation also owns the slab mid-copy */
    scope->generations++;
    dctx_t c = {.hp=retain->hp, .sl=retain, .novec=novec, .movevec=movevec, .retain=retain, .region=region, .mut_root=mut_root};
    V r = dc_dup(v, &c);
    retain->hp = c.hp;
    return r;
  }
  scope->generations = 0;
  if (table && !need) { slab_free_ownerless(table); table = 0; }
  /* a region copy that finds nothing to copy: everything it reaches lies
   * outside the region (or is an int, static, handle or moved Vector) */
  if (!need && region) return v;
  if (!need) { /* ints, statics, handles, or a moved Vector */
    if (movevec && !ISINT(v) && v && fpr_in_heap(v) && TID(v) == T_VEC && vec_movable_here(v)) return v;
    return dc_dup(v, 0);
  }
  fpr_slab_t *sl = scope->spare;
  if (!sl || slab_room(sl) < need) {
    if (sl) { scope->spare = 0; slab_free_ownerless(sl); }
    sl = msg_slab_new(need); /* may park: the actor can migrate meanwhile */
    FPR_COST_ADD(fpr_hart(), cost_msg_slabs, 1);
  }
  sl->hp = fpr_slab_start(sl);
  sl->promoted = 0; sl->pushed = 0;
  sl->holds = 1; /* the scope owns this unseen/reusable slab before publication */
  scope->spare = 0;
  scope->next_slab = sl; /* cancellation can find it before the boundary commits */
  scope->generations = 1;
  h = fpr_hart();
  if (h) h->copy_pid = pid;
  dctx_t c = {.hp=sl->hp, .sl=sl, .novec=novec, .movevec=movevec, .region=region, .share=table ? &share : 0, .mut_root=mut_root};
  V r = dc_dup(v, &c);
  sl->hp = c.hp;
  if (table) slab_free_ownerless(table);
  if (c.released) vec_release_in(v);
  return r;
}
static V transfer_copy(V v, struct fpr_scope *scope, const char *novec) { return transfer_copy_in(v, scope, novec, 0, 0, 0, 0); }
/* Commit the next state after arena/root teardown. A retained graph keeps its
 * existing hold; otherwise the previous slab loses exactly this scope's hold.
 * Exported roots/borrow windows can still pin it. Only an unreferenced slab
 * becomes the warm spare. No root walk is needed, including during reaping. */
static void transfer_retire(struct fpr_scope *scope) {
  scope->held = 0;
  if (scope->preserve_state) { scope->preserve_state = 0; return; }
  fpr_slab_t *ts = scope->state_slab;
  scope->state_slab = scope->next_slab;
  scope->next_slab = 0;
  if (!ts) return;
  fpr_lock(&arc_lock);
  if (!ts->holds) fpr_cpanic("state copy: missing scope hold");
  ts->holds--;
  int reusable = !ts->owner && !ts->escaped && !ts->holds;
  fpr_unlock(&arc_lock);
  if (!reusable) return;
  if (!scope->spare) { scope->spare = ts; return; }
  fpr_slab_t *lesser = ts;
  if (slab_room(ts) > slab_room(scope->spare)) { lesser = scope->spare; scope->spare = ts; }
  slab_free_ownerless(lesser);
}
static void scope_release(struct fpr_scope *scope) {
  /* An actor may die between copy and commit: release current AND pending. */
  scope->preserve_state = 0;
  transfer_retire(scope);
  transfer_retire(scope);
  if (scope->spare) { slab_free_ownerless(scope->spare); scope->spare = 0; }
}

#ifndef FPR_BUILTIN
/* ---- compiler-placed regions (fpr.h; docs/2026-10-25-REGIONS-LOOPS-CALLS.md)
 * The scope of a compiler region lives in the base pool (it outlives the C
 * frame that opens it: a back edge or the allocator); its arena has no bucket
 * array (a freed cell waits for the reset, which is a region's nature) and
 * takes its first slab on its first allocation.  Regions nest LIFO with the
 * stack scopes of Sys.arena/loop/loopWith: the compiler closes each before
 * its opener returns.  In a loaded process image (fpr_plane_memory) these
 * are no regions at all: the plane predates them, and the program runs as it
 * did before stage 2 -- correct, without the reclamation. */
#define REGION_MASK (((uw)1 << (sizeof(uw) * 8 - 3)) - 1) /* fits a tagged Int */
/* A consuming twin (Reuse.hs regionEntry) adds this bit to its region's
 * sequence number. Its loop overwrites state cells in place, which can make a
 * cell outside the region, or one retained in the state slab, point into the
 * arena; immutable data only points at older data. So a mutating region's
 * copy-out descends everything it reaches: no outside rule, no retained
 * generations. Sequence numbers never reach this bit. */
#define REGION_MUT_BIT ((uw)1 << 58)
/* bits 52..57: which component of the packed state the twin writes (0 = not
 * said: copy the whole state with no outside rule; 63 = the packed state is
 * that one value). The other components keep the outside rule: the written
 * structure is unique, so no other component reaches its cells. */
#define REGION_MUT_SHIFT 52
#define REGION_MUT_ALL ((uw)63)
#define REGION_SEQ_BITS (~(REGION_MUT_BIT | ((uw)63 << REGION_MUT_SHIFT)))
static uw region_opens, region_cycles, region_call_opens, pend_grows, region_deferrals, region_declines;
#ifndef FPR_REGION_SURVIVAL
#define FPR_REGION_SURVIVAL 16 /* copy only when at most 1/this of the arena survives: a steady state copies at about 16x live (at most ~9% more work on the app suite), a builder (all of it survives) never */
#endif
uw fpr_region_declines_count(void) { return __atomic_load_n(&region_declines, __ATOMIC_RELAXED); }
uw fpr_region_shared_copies_count(void) { return __atomic_load_n(&region_shared_copies, __ATOMIC_RELAXED); }
#ifndef FPR_REGION_GROWTH
#define FPR_REGION_GROWTH 2
#endif
uw fpr_region_deferrals_count(void) { return __atomic_load_n(&region_deferrals, __ATOMIC_RELAXED); }
uw fpr_region_opens_count(void) { return __atomic_load_n(&region_opens, __ATOMIC_RELAXED); }
uw fpr_region_cycles_count(void) { return __atomic_load_n(&region_cycles, __ATOMIC_RELAXED); }
uw fpr_region_call_opens_count(void) { return __atomic_load_n(&region_call_opens, __ATOMIC_RELAXED); }
uw fpr_pend_grows_count(void) { return __atomic_load_n(&pend_grows, __ATOMIC_RELAXED); }
static uw region_seq_next[FPR_NHARTS];
static fpr_pends_t boot_pends[FPR_NHARTS];
static fpr_pends_t *pends_of(fpr_hart_t *h) { return h->current ? fpr_acb_pends(h->current) : &boot_pends[h->id]; }
static struct fpr_scope **scope_head(fpr_hart_t *h) {
  return h->current ? fpr_acb_scope_slot(h->current) : &bootstrap_scopes[h->id];
}
/* open a compiler region now: its scope at the chain's head, its arena the
 * actor's current pool from here on */
static struct fpr_scope *region_open(fpr_hart_t *h, uw seq) {
  struct fpr_scope *sc = (struct fpr_scope *)fpr_alloc_bulk(sizeof(struct fpr_scope));
  h = fpr_hart(); /* allocation can park; the actor can migrate */
  struct fpr_scope **head = scope_head(h);
  sc->previous = *head;
  sc->held = 0; sc->spare = 0;
  sc->state_slab = sc->next_slab = 0;
  sc->generations = 0; sc->immutable_state = sc->preserve_state = 0;
  sc->live_bytes = sc->alloc_mark = 0; sc->receive = 0; sc->mutating = 0; sc->mut_comp = 0; sc->declined = 0; sc->declined_bytes = 0; sc->retry_at = 0; sc->decline_run = 0;
  sc->rx_mark = h->current ? fpr_acb_rx(h->current)->n : 0;
  sc->seq = seq;
  struct fpr_pool **slot = override_slot(h);
  sc->prev_override = *slot;
  sc->msg_slab = 0;
  fpr_pool_init(&sc->ap, 0);
  sc->arena = &sc->ap;
  *head = sc;
  fpr_bump_close(h);
  *slot = (struct fpr_pool *)&sc->ap;
  return sc;
}
/* close the region at the head: the result is copied into the pool that was
 * current when it opened (an owned Vector moves), the arena and the transfer
 * slabs go home, the scope is freed */
/* a closing region whose result is at least as large as what it leaves
 * behind: copying the result would cost as much as the memory the copy frees,
 * so its slabs join the pool it closes into instead, the garbage with them
 * (at most the result's size, and that pool's own to reclaim).  A builder
 * called under a pending region, its whole allocation the list it returns,
 * paid a copy of the list for nothing (tests/bench/strbuild.fpr, +15%).  A
 * fixed-heap pool keeps its cap: never adopted into. */
static uw region_adoptions, region_adopted_bytes;
uw fpr_region_adoptions_count(void) { return __atomic_load_n(&region_adoptions, __ATOMIC_RELAXED); }
uw fpr_region_adopted_bytes_count(void) { return __atomic_load_n(&region_adopted_bytes, __ATOMIC_RELAXED); }
static int region_adopt(fpr_hart_t *h, fpr_pool_t *ap, fpr_pool_t *into, V r) {
  uw used = ap->allocated;
  if (into->fixed_heap || !ap->cur || !used) return 0;
  uw left = used - used / 2; /* the result is at least half of what was bumped */
  h->copy_movevec = 1;
  int big = kp_reaches(r, &left);
  h->copy_movevec = 0;
  if (!big) return 0;
  fpr_lock(&arc_lock);
  fpr_slab_t *last = 0;
  for (fpr_slab_t *sl = ap->cur; sl; sl = sl->next) { sl->owner = into; last = sl; }
  if (into->cur) { last->next = into->cur->next; into->cur->next = ap->cur; } /* behind its bump slab */
  else into->cur = ap->cur;
  into->allocated += used; /* an outer pending region counts it as its call's */
  ap->cur = 0; ap->bigfree = 0; /* freed big blocks stay where they lie, as garbage */
  fpr_unlock(&arc_lock);
  __atomic_fetch_add(&region_adoptions, 1, __ATOMIC_RELAXED);
  __atomic_fetch_add(&region_adopted_bytes, used, __ATOMIC_RELAXED);
  return 1;
}
/* a pure loop region that cycled, closing with a result at least half of
 * what it holds (its arena since the last reset, and the state slab): the
 * state slab and the arena's slabs join the pool it closes into, as
 * region_adopt does for a region that never cycled.  Copying the result out
 * instead re-copied a builder's whole list -- every line of a file -- after a
 * single early copy had made the region "cycled". */
static int region_adopt_state(fpr_hart_t *h, struct fpr_scope *sc, fpr_pool_t *into, V r) {
  fpr_slab_t *ts = sc->state_slab;
  if (into->fixed_heap || sc->receive || sc->next_slab || sc->preserve_state || !ts) return 0;
  uw used = sc->ap.allocated - sc->alloc_mark + (uw)(ts->hp - fpr_slab_start(ts));
  if (!used) return 0;
  uw left = used - used / 2;
  h->copy_movevec = 1;
  int big = kp_reaches(r, &left);
  h->copy_movevec = 0;
  if (!big) return 0;
  fpr_lock(&arc_lock);
  if (ts->owner || ts->holds != 1) { fpr_unlock(&arc_lock); return 0; } /* another keeper: copy */
  ts->holds = 0;
  ts->owner = into;
  ts->pushed = 0;
  fpr_slab_t *tail = ts;
  ts->next = sc->ap.cur;
  for (fpr_slab_t *sl = sc->ap.cur; sl; sl = sl->next) { sl->owner = into; tail = sl; }
  if (into->cur) { tail->next = into->cur->next; into->cur->next = ts; } /* behind its bump slab */
  else { tail->next = 0; into->cur = ts; }
  into->allocated += used;
  sc->ap.cur = 0; sc->ap.bigfree = 0;
  fpr_unlock(&arc_lock);
  sc->state_slab = 0; sc->held = 0;
  __atomic_fetch_add(&region_adoptions, 1, __ATOMIC_RELAXED);
  __atomic_fetch_add(&region_adopted_bytes, used, __ATOMIC_RELAXED);
  return 1;
}
static V region_close(fpr_hart_t *h, struct fpr_scope *sc, V r) {
  struct fpr_pool **slot = override_slot(h);
  fpr_bump_close(h);
  *slot = sc->prev_override;
  /* a loop region that cycled holds its state in transfer slabs the result
   * may point into: those close by copy.  So does one that received
   * messages since it opened (a receive loop's last turns): the result may
   * point into a message, and the messages die here, after the copy */
  int received = h->current && fpr_acb_rx(h->current)->n > sc->rx_mark;
  if (!received && ((!sc->held && !sc->spare && region_adopt(h, &sc->ap, cur_pool(h), r)) ||
                    (sc->held && region_adopt_state(h, sc, cur_pool(h), r)))) {
    scope_release(sc);
    scope_unlink(scope_head(h), sc);
    fpr_free_raw((V)sc);
    return r;
  }
  h->copy_movevec = 1;
  V out = kp_dup(r);
  h = fpr_hart();
  h->copy_movevec = 0;
  vec_release_in(r);
  struct fpr_pool *dummy = 0;
  arena_close(&dummy, &sc->ap, 0);
  if (received) scope_roots_die(sc); /* kp_dup copied the result deep: nothing kept points into them */
  scope_release(sc);
  scope_unlink(scope_head(h), sc);
  fpr_free_raw((V)sc);
  return out;
}
static V g_region_seq(V u) {
  (void)u;
  fpr_hart_t *h = fpr_hart();
  uw n = ++region_seq_next[h->id];
  return TAG((sw)(((n << 6) | h->id) & REGION_MASK)); /* unique across harts: the actor may migrate */
}
static V g_region_mark(V u) {
  (void)u;
  return TAG((sw)(fpr_hart()->region_bytes & REGION_MASK));
}
/* the back edge, every iteration: is there room left, has this hart bumped
 * less than a slab since the mark?  The typed IR inlines it (ORegionRoom);
 * this is its out-of-line form.  A plane-routed process never bumps here:
 * its pool grows in the kernel, so its loops always have room, as they never
 * had regions. */
static V g_region_room(V mark) {
  uw now = fpr_hart()->region_bytes & REGION_MASK;
  return ((now - (uw)UNTAG(mark)) & REGION_MASK) < (uw)FPR_REGION_SLAB ? (V)&fpr_true : (V)&fpr_false;
}
/* A checked receive boundary has evaluated its next state but has not entered
 * the next activation. Copy that state and release the preceding roots before
 * an empty/selective receive can park. After cycling, no roots remain above
 * rx_mark, so the boundary proceeds rather than repeatedly cycling. */
static V g_receive_ready(V kind, V peer) {
  if (fpr_plane_memory) return (V)&fpr_true;
  fpr_hart_t *h = fpr_hart();
  if (!h || !h->current) return (V)&fpr_true;
  struct fpr_scope *sc = *scope_head(h);
  if (!sc || fpr_acb_rx(h->current)->n <= sc->rx_mark) return (V)&fpr_true;
  return BOOL(fpr_actor_receive_ready((uw)UNTAG(kind), peer));
}
/* a receive loop's entry: its region opens now, so every message its turns
 * take is above the region's mark and dies at a cycle or at the close; the
 * loop is passed the returned sequence number, which keeps the call
 * (docs/2026-10-26-RECEIVE-TURNS-PER-SLAB.md) */
static V g_region_open(V seqv) {
  if (fpr_plane_memory) return seqv;
  region_open(fpr_hart(), (uw)UNTAG(seqv))->receive = 1;
  __atomic_fetch_add(&region_opens, 1, __ATOMIC_RELAXED);
  return seqv;
}
/* the back edge tripped: the first time, the region opens (the state was
 * built in the caller's pool, which outlives the loop: nothing to copy);
 * after that the changing arguments are copied out and the region reset */
static V g_region_cycle(V seqv, V packed) {
  if (fpr_plane_memory) return packed;
  fpr_hart_t *h = fpr_hart();
  struct fpr_scope *sc = *scope_head(h);
  uw seq = (uw)UNTAG(seqv) & REGION_SEQ_BITS;
  int mutating = ((uw)UNTAG(seqv) & REGION_MUT_BIT) != 0;
  uw comp = ((uw)UNTAG(seqv) >> REGION_MUT_SHIFT) & 63;
  if (sc && sc->seq == seq && mutating) { sc->mutating = 1; if (comp) sc->mut_comp = comp; } /* a twin now writes this region's state */
  if (!sc || sc->seq != seq) {
    struct fpr_scope *o = region_open(h, seq);
    o->mutating = mutating; o->mut_comp = comp;
    __atomic_fetch_add(&region_opens, 1, __ATOMIC_RELAXED);
    return packed;
  }
  /* A pure loop copies its live state out only once the arena has grown by
   * FPR_REGION_GROWTH times what the last copy produced: the copy work is
   * then at most 1/FPR_REGION_GROWTH of the allocation, and the region holds
   * at most about FPR_REGION_GROWTH + 1 times the live state.  Copying at
   * every slab, a state of 1.3 MB was copied twenty times per byte freed.
   * Declining keeps the arena; the back edge re-marks and asks again a slab
   * later.  A receive loop cycles every slab: its cycle also releases the
   * messages its turns took. */
  if (!sc->receive && (sc->ap.allocated - sc->alloc_mark < (uw)FPR_REGION_GROWTH * sc->live_bytes ||
                       sc->ap.allocated < sc->retry_at)) {
    __atomic_fetch_add(&region_deferrals, 1, __ATOMIC_RELAXED);
    return packed;
  }
  /* ...and only when the copy frees at least half of what the arena holds:
   * a loop whose state is everything it allocates (a list builder admitted
   * with persistent copy-out) pays a sizing walk, never a copy */
  uw bumped = sc->ap.allocated - sc->alloc_mark;
  sc->declined = 0;
  /* a mutating region whose twin said which component it writes copies that
   * component whole and keeps the outside rule for the rest */
  V mut_root = 0;
  int whole = sc->mutating && !sc->mut_comp;
  if (sc->mutating && sc->mut_comp == REGION_MUT_ALL) mut_root = packed;
  else if (sc->mutating && sc->mut_comp && !ISINT(packed) && packed && fpr_in_heap(packed)) {
    hdr_t *ph = (hdr_t *)packed;
    uw nf = (PREHEADER(packed) - FPR_MANAGED_PREFIX - 8) / sizeof(uw);
    if (ph->tid < T_STR && sc->mut_comp - 1 < nf) mut_root = ((V *)((char *)packed + 8))[sc->mut_comp - 1];
    else whole = 1;
  } else if (sc->mutating && sc->mut_comp) whole = 1;
  V t = transfer_copy_in(packed, sc, 0, 1, sc->receive || whole ? 0 : &sc->ap, sc->receive ? 0 : bumped / FPR_REGION_SURVIVAL + 1, mut_root);
  if (sc->declined) {
    /* try again once the arena has doubled from here: the sizing walks then
     * cost at most twice the allocation, whatever fraction survives (a loop
     * keeping just over half re-walked its state at every slab) */
    sc->live_bytes = sc->declined_bytes;
    sc->retry_at = sc->ap.allocated + (bumped << (sc->decline_run < 3 ? sc->decline_run : 3));
    sc->decline_run++;
    __atomic_fetch_add(&region_declines, 1, __ATOMIC_RELAXED);
    return packed;
  }
  fpr_slab_t *ns = sc->preserve_state ? sc->state_slab : sc->next_slab;
  sc->live_bytes = ns ? (uw)(ns->hp - fpr_slab_start(ns)) : 0;
  scope_roots_die(sc);
  arena_reset(&sc->ap);
  sc->alloc_mark = sc->ap.allocated;
  sc->retry_at = 0; sc->decline_run = 0;
  transfer_retire(sc);
  sc->held = t;
  __atomic_fetch_add(&region_cycles, 1, __ATOMIC_RELAXED);
  return t;
}
/* the loop returned: its region, if one opened, closes with the result */
static V g_loop_leave(V seqv, V r) {
  if (fpr_plane_memory) return r;
  fpr_hart_t *h = fpr_hart();
  struct fpr_scope *sc = *scope_head(h);
  if (!sc || sc->seq != ((uw)UNTAG(seqv) & REGION_SEQ_BITS)) return r;
  return region_close(h, sc, r);
}
/* a costly call begins: a pending region, opened only if the call uses a
 * slab of this pool (region_trip); the token is its depth, for the leave */
static V g_call_pend(V u) {
  (void)u;
  if (fpr_plane_memory) return TAG(0);
  fpr_hart_t *h = fpr_hart();
  fpr_pends_t *ps = pends_of(h);
  if (!ps->v) { ps->v = ps->v0; ps->cap = FPR_PEND_INLINE; ps->n = 0; ps->block = 0; }
  if (ps->n == ps->cap) {
    /* doubling, counted, into a buddy block (fpr.h says why not the pool) */
    uw ncap = ps->cap * 2;
    fpr_slab_t *sl = fpr_slab_new(ncap * sizeof(fpr_pend_t) + sizeof(fpr_slab_t)); /* may park */
    if (!sl) fpr_exhausted("call region: no block for the pending regions");
    h = fpr_hart();
    ps = pends_of(h);
    fpr_pend_t *nv = (fpr_pend_t *)(sl + 1);
    __builtin_memcpy(nv, ps->v, ps->n * sizeof(fpr_pend_t));
    if (ps->block) fpr_slab_release(ps->block);
    ps->block = sl; ps->v = nv;
    ps->cap = (uw)(sl->end - (char *)nv) / sizeof(fpr_pend_t);
    __atomic_fetch_add(&pend_grows, 1, __ATOMIC_RELAXED);
  }
  fpr_pool_t *pool = cur_pool(h);
  fpr_pend_t *e = &ps->v[ps->n++];
  e->seq = 0; e->pool = (struct fpr_pool *)pool; e->mark = pool->allocated; e->scope = 0;
  h->pend_stack = ps; /* generated code pushes the next ones itself (fpr.h) */
  return TAG((sw)(ps->n - 1));
}
/* A private multiword result is already in registers. Materialize a
 * copy root only when this pending call actually opened a region. */
static V g_call_active(V tok) {
  if (fpr_plane_memory) return (V)&fpr_false;
  fpr_pends_t *ps = pends_of(fpr_hart());
  if (!ps->n || ps->n - 1 != (uw)UNTAG(tok)) fpr_cpanic("call region: left out of order");
  return ps->v[ps->n - 1].scope ? (V)&fpr_true : (V)&fpr_false;
}
FPR_FN(fpr_g__x24callActive, g_call_active, 1);
static V g_call_leave(V tok, V r) {
  if (fpr_plane_memory) return r;
  fpr_hart_t *h = fpr_hart();
  fpr_pends_t *ps = pends_of(h);
  if (!ps->n || ps->n - 1 != (uw)UNTAG(tok)) fpr_cpanic("call region: left out of order");
  fpr_pend_t e = ps->v[--ps->n];
  h->pend_stack = ps;
  if (!e.scope) return r;
  if (*scope_head(h) != e.scope) fpr_cpanic("call region: a nested region is still open");
  return region_close(h, e.scope, r);
}
/* the allocator needs a new slab for `pool`: if the innermost pending call
 * region started in this pool and has used a slab of it, open it now */
static int region_trip(fpr_hart_t *h, fpr_pool_t *pool) {
  if (fpr_plane_memory) return 0;
  fpr_pends_t *ps = pends_of(h);
  if (!ps->n) return 0;
  fpr_pend_t *e = &ps->v[ps->n - 1];
  if (e->scope || e->pool != (struct fpr_pool *)pool) return 0;
  /* a Sys.poolReset since the pend restarted the gauge: count from there */
  uw used = pool->allocated >= e->mark ? pool->allocated - e->mark : pool->allocated;
  if (used < (uw)FPR_REGION_SLAB) return 0;
  struct fpr_scope *sc = region_open(h, 0);
  ps = pends_of(fpr_hart()); /* region_open may park */
  ps->v[ps->n - 1].scope = sc;
  __atomic_fetch_add(&region_call_opens, 1, __ATOMIC_RELAXED);
  return 1;
}
#else /* FPR_BUILTIN: the builtin heap's regions (machine/builtin/heap.c) */
#define REGION_MASK (((uw)1 << (sizeof(uw) * 8 - 3)) - 1)
static uw region_seq_next;
uw fpr_region_opens_count(void) { uw o, r; fpr_builtin_region_counts(&o, &r); return o; }
uw fpr_region_cycles_count(void) { return 0; }
uw fpr_region_call_opens_count(void) { return 0; }
uw fpr_pend_grows_count(void) { return 0; }
static uw region_adoptions, region_adopted_bytes;
uw fpr_region_adopted_bytes_count(void) { return region_adopted_bytes; }
uw fpr_region_adoptions_count(void) { return region_adoptions; }
/* adopt: a compiler-placed region whose result is at least as large as what
 * it allocated since its last reset hands its blocks to the enclosing region
 * instead of copying the result (region_adopt on the host says why); an
 * explicit Sys.arena or Sys.loop always copies, as its programmer asked */
static V region_close_builtin(V r, int adopt) {
  void *tok = fpr_builtin_region_close_begin(); /* allocations go to the enclosing region */
  fpr_hart_t *h = fpr_hart();
  if (adopt) {
    uw used = fpr_builtin_region_scratch(tok), left = used - used / 2;
    h->copy_movevec = 1;
    int big = used && kp_reaches(r, &left);
    h->copy_movevec = 0;
    if (big) { fpr_builtin_region_adopt(tok); region_adoptions++; region_adopted_bytes += used; return r; }
  }
  h->copy_movevec = 1;
  V out = kp_dup(r);
  h->copy_movevec = 0;
  vec_release_in(r); /* before the lists go: a released Vector's boxed cells are in them */
  fpr_builtin_region_close_end(tok);
  return out;
}
static V g_region_seq(V u) { (void)u; return TAG((sw)((++region_seq_next) & REGION_MASK)); }
static V g_region_mark(V u) { (void)u; return TAG((sw)(fpr_hart()->region_bytes & REGION_MASK)); }
static V g_region_room(V mark) {
  uw now = fpr_hart()->region_bytes & REGION_MASK;
  return ((now - (uw)UNTAG(mark)) & REGION_MASK) < (uw)FPR_REGION_SLAB ? (V)&fpr_true : (V)&fpr_false;
}
static V g_region_open(V seqv) { fpr_builtin_region_open((uw)UNTAG(seqv)); return seqv; }
static V g_receive_ready(V kind, V peer) { (void)kind; (void)peer; return (V)&fpr_true; }
static V g_region_cycle(V seqv, V packed) {
  uw seq = (uw)UNTAG(seqv);
  if (fpr_builtin_region_seq() != seq) { fpr_builtin_region_open(seq); return packed; }
  fpr_builtin_region_cycle_begin();
  fpr_hart_t *h = fpr_hart();
  h->copy_movevec = 1;
  V t = kp_dup(packed);
  h->copy_movevec = 0;
  vec_release_in(packed);
  fpr_builtin_region_cycle_end();
  return t;
}
static V g_loop_leave(V seqv, V r) {
  if (fpr_builtin_region_seq() != (uw)UNTAG(seqv) || !seqv) return r;
  return region_close_builtin(r, 1);
}
static V g_call_pend(V u) { (void)u; return TAG((sw)fpr_builtin_pend()); }
static V g_call_leave(V tok, V r) {
  if (!fpr_builtin_pend_pop((uw)UNTAG(tok))) return r;
  return region_close_builtin(r, 1);
}
#endif
FPR_FN(fpr_g__x24regionSeq, g_region_seq, 1);
FPR_FN(fpr_g__x24regionMark, g_region_mark, 1);
FPR_FN(fpr_g__x24regionRoom, g_region_room, 1);
FPR_FN(fpr_g__x24receiveReady, g_receive_ready, 2);
FPR_FN(fpr_g__x24regionCycle, g_region_cycle, 2);
FPR_FN(fpr_g__x24regionOpen, g_region_open, 1);

FPR_FN(fpr_g__x24loopLeave, g_loop_leave, 2);
FPR_FN(fpr_g__x24callPend, g_call_pend, 1);
FPR_FN(fpr_g__x24callLeave, g_call_leave, 2);

static V g_arena(V f) {
  if (fpr_plane_memory) return fpr_plane_memory->arena(f);
#ifdef FPR_BUILTIN
  /* the builtin heap's region: the call's allocations die at its end, the
   * result copied out first (machine/builtin/heap.c) */
  if (!fpr_builtin_region_open(0)) return fpr_apply(f, (V)&fpr_unit); /* ARC builds: no regions */
  return region_close_builtin(fpr_apply(f, (V)&fpr_unit), 0);
#else
  /* Capture actor-owned storage, not its current hart: allocation and the
   * thunk may park, and a resumed actor can migrate before teardown. */
  struct fpr_pool **slot = override_slot(fpr_hart());
  struct fpr_pool *prev = *slot;
  struct fpr_scope scope;
  struct fpr_scope **head = scope_push(&scope);
  fpr_pool_t ap;
  arena_open(slot, &ap);
  scope.arena = &ap;
  V r = fpr_apply(f, (V)&fpr_unit);
  /* its own slab: survives the teardown, freed below */
  V t = transfer_copy(r, &scope, "Sys.arena: Vector results cannot escape an arena "
                                 "(their storage IS the arena) -- return scalars/trees, "
                                 "or build pool-owned vectors outside");
  scope.held = t;
  scope_roots_die(&scope);
  arena_close(slot, &ap, prev);
  scope.arena = 0;
  /* copy the result into the CALLER's pool; free the transfer slab */
  V out = kp_dup(t);
  scope_release(&scope);
  scope_unlink(head, &scope);
  return out;
#endif
}

/* ---- Sys.loopWith: a loop whose every step is an arena --------------
 * A long-lived loop in one actor allocates a little per turn (a key, a
 * closure, a tuple); its pool is reclaimed only at death, so it grows
 * forever.  loopWith runs each step `f state vec` under a fresh arena,
 * copies the NEXT state out into a transfer slab of its own, tears the
 * arena down and frees the previous state's slab: memory is the live
 * state, twice at most, however long it runs.  Nothing is allocated in
 * the caller's pool until the loop ends.
 *
 * The one linear Vector is threaded BY IDENTITY: the caller sizes it
 * (two frame buffers are two halves of one), each step reads and
 * writes it in place, and it must come back with the same storage --
 * Vec.set/put/get/at never allocate; a push past capacity, a fresh
 * vector or a free would leave it in the torn-down arena, and is
 * refused rather than copied.  The state may hold no Vector.
 *
 *   Sys.loopWith vec s0 (fn s v -> (continue, s', v))  ->  (sFinal, vec) */
/* the snapshot is sized to the vector's own column count: the directory
 * pointer, the kinds pointer, and each column's col_t and base */
typedef struct { vec_t *x; uw ncols; col_t **dir; uint8_t *kinds; vec_shape_t *shape; col_t **cols; uw **base; } vec_snap_t;
static void vec_snap(vec_snap_t *sn, V v) {
  sn->x = (vec_t *)v;
  sn->ncols = sn->x->ncols;
  sn->dir = sn->x->cols;
  sn->kinds = sn->x->kinds;
  sn->shape = sn->x->shape;
  sn->cols = sn->ncols ? (col_t **)fpr_alloc_raw(sn->ncols * sizeof(col_t *)) : 0;
  sn->base = sn->ncols ? (uw **)fpr_alloc_raw(sn->ncols * sizeof(uw *)) : 0;
  for (uw i = 0; i < sn->ncols; i++) {
    sn->cols[i] = sn->x->cols[i];
    sn->base[i] = sn->cols[i] ? sn->cols[i]->base : 0;
  }
}
static int vec_same(const vec_snap_t *sn, V v) {
  if ((vec_t *)v != sn->x) return 0;
  if (sn->x->ncols != sn->ncols || sn->x->cols != sn->dir || sn->x->kinds != sn->kinds || sn->x->shape != sn->shape) return 0;
  for (uw i = 0; i < sn->ncols; i++) {
    if (sn->x->cols[i] != sn->cols[i]) return 0;
    if (sn->cols[i] && sn->cols[i]->base != sn->base[i]) return 0;
  }
  return 1;
}
/* Sys.loop state step -> finalState. The value-only form of loopWith is
 * the default engine for library receive/frame loops. A callback cannot
 * smuggle mutable storage around the state check through a capture. */
/* movevec: the compiler-placed turn ($receiveLoop): an owned Vector in the
 * state crosses by handle (vec_movable_here) instead of being refused; the
 * Sys.loop primitive keeps its contract (loopWith threads a buffer). */
static V g_loop_in(V s, V f, int movevec) {
  if (fpr_plane_memory) {
    if (!movevec) return fpr_plane_memory->loop(s, f);
    if (fpr_plane_memory->abi < 4 || !fpr_plane_memory->loop_turn)
      fpr_cpanic("receive loop: the memory plane predates turn regions with Vectors (rebuild the kernel)");
    return fpr_plane_memory->loop_turn(s, f);
  }
#ifdef FPR_BUILTIN
  /* each turn in the builtin heap's region: the next state copied out, the
   * turn's garbage freed (machine/builtin/heap.c) */
  (void)movevec;
  { V state = s;
  int regions = fpr_builtin_region_open(0);
  for (;;) {
    V r = fpr_apply(f, state);
    if (ISINT(r) || !fpr_in_heap(r) || TID(r) != T_TUP2)
      fpr_cpanic("Sys.loop: a step must return (continue, state)");
    V go = FPR_FLD(r, 0);
    V nx = FPR_FLD(r, 1);
    if (ISINT(go) || !go || TID(go) != T_BOOL || ((hdr_t *)go)->var > 1)
      fpr_cpanic("Sys.loop: continue must be a Bool");
    if (((hdr_t *)go)->var != 1) return regions ? region_close_builtin(nx, 0) : nx;
    if (regions) {
      fpr_builtin_region_cycle_begin();
      state = kp_dup(nx);
      fpr_builtin_region_cycle_end();
    } else state = nx;
  } }
#else
  if (!movevec) {
    no_vec_out(s, "Sys.loop: the state may not hold a Vector (use Sys.loopWith)");
    no_vec_out(f, "Sys.loop: the callback may not capture a Vector (use Sys.loopWith)");
  }
  struct fpr_pool **slot = override_slot(fpr_hart());
  struct fpr_pool *prev = *slot;
  struct fpr_scope scope;
  struct fpr_scope **head = scope_push(&scope);
  /* ONE arena for the whole loop, rewound at every turn boundary (arena_reset) */
  fpr_pool_t ap;
  arena_open(slot, &ap);
  scope.arena = &ap;
  V state = s;
  for (;;) {
    FPR_COST_ADD(fpr_hart(), cost_turns, 1);
    V r = fpr_apply(f, state);
    if (ISINT(r) || !fpr_in_heap(r) || TID(r) != T_TUP2)
      fpr_cpanic("Sys.loop: a step must return (continue, state)");
    V go = FPR_FLD(r, 0), nx = FPR_FLD(r, 1);
    if (ISINT(go) || !go || TID(go) != T_BOOL || ((hdr_t *)go)->var > 1)
      fpr_cpanic("Sys.loop: continue must be a Bool");
    int more = ((hdr_t *)go)->var == 1;
    V t = transfer_copy_in(nx, &scope, movevec ? 0 : "Sys.loop: the state may not hold a Vector (use Sys.loopWith)", movevec, 0, 0, 0);
    scope_roots_die(&scope);
    arena_reset(&ap);
    transfer_retire(&scope);
    state = scope.held = t;
    if (!more) break;
  }
  arena_close(slot, &ap, prev);
  scope.arena = 0;
  { fpr_hart_t *fh = fpr_hart(); if (fh) fh->copy_movevec = (uw)movevec; }
  V out = kp_dup(state); /* into the caller's pool; an owned Vector stays where it is */
  { fpr_hart_t *fh = fpr_hart(); if (fh) fh->copy_movevec = 0; }
  scope_release(&scope);
  scope_unlink(head, &scope);
  return out;
#endif
}
static V g_loop(V s, V f) { return g_loop_in(s, f, 0); }
static V g_loop_turn(V s, V f) { return g_loop_in(s, f, 1); }
FPR_FN(fpr_g_Sys_x2eloop, g_loop, 2);

/* Compiler-private tail-call trampoline. A checked receive SCC returns
 * (True, next partially-applied step) or (False, its original result).
 * Only closed value-state SCCs are lowered; g_loop also checks the actual
 * graphs so unsafe/foreign code cannot smuggle mutable storage through.
 * Reusing g_loop retains migration, nested scopes and cancellation cleanup. */
static V receive_step(V thunk) {
  if (ISINT(thunk) || !thunk || TID(thunk) != T_PAP)
    fpr_cpanic("receive loop: expected a next-turn closure");
  return fpr_apply(thunk, (V)&fpr_unit);
}
static const pap0_t receive_step_fn = {T_PAP, 0, (uw)(uintptr_t)receive_step, 1, 0};
/* `packed` is the stub's word on the thunk's one argument: the number of
 * live parameters it bundled.  Two or more means the argument is a tuple
 * the stub made for this call alone; one means the parameter itself,
 * which may be the caller's own value and is not ours to free.
 *
 * The thunk and that tuple are allocated by the entry stub in the caller's
 * pool (there is no arena yet).  The first turn unpacks them into locals
 * and every later turn's state is a fresh copy in transfer storage, so once
 * the loop has returned both cells are dead.  Hand them back to the pool's
 * buckets: otherwise every activation of a receive loop -- each
 * `Clock.receiveWithin`, each `Poller` wait -- bumps them anew and leaks
 * them until the actor dies (112 bytes on a 64-bit host: tests/std/poller.fpr,
 * docs/2026-10-19-STD-SUITE-REPAIRS.md). */
static V g_receive_loop(V thunk, V packed) {
  V out = g_loop_in(thunk, (V)&receive_step_fn, 1); /* the compiler's turn: owned Vectors move */
  if (!ISINT(thunk) && thunk && fpr_in_heap(thunk) && TID(thunk) == T_PAP) {
    pap_t *p = (pap_t *)thunk;
    if (p->nargs == 1 && ISINT(packed) && UNTAG(packed) > 1) {
      V state = (V)p->args[0];
      if (!ISINT(state) && state && fpr_in_heap(state)) fpr_free(state);
    }
    fpr_free(thunk);
  }
  return out;
}
FPR_FN(fpr_g__x24receiveLoop, g_receive_loop, 2);

static V g_loop_with(V vec, V s, V f) {
  if (fpr_plane_memory) return fpr_plane_memory->loop_with(vec, s, f);
#ifdef FPR_BUILTIN
  { V state = s, v = vec;
  for (;;) {
    V r = fpr_apply(fpr_apply(f, state), v);
    if (ISINT(r) || !fpr_in_heap(r) || TID(r) != T_TUP3)
      fpr_cpanic("Sys.loopWith: a step must return (continue, state, vector)");
    V go = FPR_FLD(r, 0);
    state = FPR_FLD(r, 1); v = FPR_FLD(r, 2);
    if (ISINT(go) || !go || TID(go) != T_BOOL || ((hdr_t *)go)->var > 1)
      fpr_cpanic("Sys.loopWith: continue must be a Bool");
    if (((hdr_t *)go)->var != 1) break;
  }
  hdr_t *tup = (hdr_t *)fpr_alloc(8 + 2 * sizeof(uw));
  tup->tid = T_TUP2; tup->var = 0;
  *(V *)((char *)tup + 8) = state;
  *(V *)((char *)tup + 8 + sizeof(uw)) = v;
  return (V)tup; }
#else
  if (ISINT(vec) || !fpr_in_heap(vec) || TID(vec) != T_VEC)
    fpr_cpanic("Sys.loopWith: not a Vector");
  no_vec_out(s, "Sys.loopWith: the state may not hold a Vector "
                "(thread the one buffer, keep the rest in it)");
  vec_snap_t sn;
  vec_snap(&sn, vec);
  struct fpr_pool **slot = override_slot(fpr_hart());
  struct fpr_pool *prev = *slot;
  struct fpr_scope scope;
  struct fpr_scope **head = scope_push(&scope);
  fpr_pool_t ap;
  arena_open(slot, &ap);
  scope.arena = &ap;
  V state = s;
  for (;;) {
    FPR_COST_ADD(fpr_hart(), cost_turns, 1);
    V r = fpr_apply(fpr_apply(f, state), vec);
    if (ISINT(r) || !fpr_in_heap(r) || TID(r) != T_TUP3)
      fpr_cpanic("Sys.loopWith: a step must return (continue, state, vector)");
    V go = *(V *)((char *)r + 8);
    V nx = *(V *)((char *)r + 8 + sizeof(uw));
    V v2 = *(V *)((char *)r + 8 + 2 * sizeof(uw));
    if (!vec_same(&sn, v2))
      fpr_cpanic("Sys.loopWith: the vector must come back as it went in "
                 "-- same storage: size it before the loop, only read "
                 "and write it in a step (no push past capacity, no "
                 "new vector)");
    V t = transfer_copy(nx, &scope, "Sys.loopWith: the state may not hold a Vector "
                                    "(thread the one buffer, keep the rest in it)");
    scope_roots_die(&scope);
    int more = !ISINT(go) && TID(go) == T_BOOL && ((hdr_t *)go)->var == 1;
    arena_reset(&ap);
    transfer_retire(&scope);
    state = scope.held = t;
    if (!more) break;
  }
  arena_close(slot, &ap, prev);
  scope.arena = 0;
  V out = kp_dup(state);
  scope_release(&scope);
  hdr_t *tup = (hdr_t *)fpr_alloc(8 + 2 * sizeof(uw));
  tup->tid = T_TUP2;
  tup->var = 0;
  *(V *)((char *)tup + 8) = out;
  *(V *)((char *)tup + 8 + sizeof(uw)) = vec;
  scope_unlink(head, &scope);
  return (V)tup;
#endif
}
FPR_FN(fpr_g_Sys_x2eloopWith, g_loop_with, 3);
FPR_FN(fpr_g_Sys_x2earena, g_arena, 1);
/* Region bookkeeping must live with the plane's ARC lock and recycler,
 * including callbacks executing code in a loaded process. Export the whole
 * operation rather than mixing process-local teardown with shared slabs. */
void fpr_memory_scopes_export(fpr_plane_memory_t *memory) {
  memory->arena = g_arena;
  memory->loop = g_loop;
  memory->loop_turn = g_loop_turn;
  memory->loop_with = g_loop_with;
}

/* death teardown (hart loop, after the switch OFF the actor's stack):
 * slabs with no escaped objects return to buddy now; the rest are
 * orphaned and return when their last promoted object is dropped.
 * The stack never escapes: always reclaimed. */
void fpr_arc_teardown_pool(fpr_pool_t *pool); /* below, with the ARC state */
void fpr_pool_reclaim(struct fpr_acb *a) {
  struct fpr_scope **head = fpr_acb_scope_slot(a);
  for (struct fpr_scope *s = *head; s; s = s->previous) {
    if (s->arena) fpr_arc_teardown_pool(s->arena);
    scope_release(s); /* the state's slab and the spare */
  }
  *head = 0;
  *fpr_acb_override_slot(a) = 0;
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
 * pass 70% and at least a quarter of the slots are live -- so a
 * long-running hub with ten thousand shared values in flight costs a
 * bigger table, not a panic (the old fixed table died at 1024) -- and
 * rehashes at the SAME size when they are not (arc_grow: tombstones
 * alone never double it).  Growth happens under arc_lock on the insert path, before
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
/* the next table's size (docs/2026-10-18-ARC-TABLE-CHURN.md): the 70%
 * rule counts tombstones, so a table can fill with the remains of
 * dropped messages while almost nothing is live.  Doubling then buys
 * nothing -- the rehash drops the tombstones anyway -- so when fewer
 * than a quarter of the slots are LIVE the rehash keeps the size
 * (compaction); the table doubles only when live entries need the
 * room.  Live below a quarter leaves at least 45% of the slots free
 * after a compaction, so the next rehash is at least that many new
 * keys away; 25% live after a doubling leaves the same. */
static uw arc_next_cap(uw cap, uw live) { return live * 4 < cap ? cap : cap * 2; }
/* a table block goes back where arc_block got it */
static void arc_block_free(arcent_t *t) {
  if (t == arct0) return; /* the static first table is never freed */
  if (fpr_mem_own) fpr_mem_give(t); else if (!fpr_is_process) buddy_free(t);
}
static void arc_reserve(void) {
  uw cap = __atomic_load_n(&arc_cap, __ATOMIC_RELAXED);
  if ((__atomic_load_n(&arc_used, __ATOMIC_RELAXED) + 1) * 10 <= cap * 7) return;
  uw ncap = arc_next_cap(cap, __atomic_load_n(&arc_live, __ATOMIC_RELAXED));
  arcent_t *sp = __atomic_load_n(&arc_spare, __ATOMIC_ACQUIRE);
  if (sp) {
    if (__atomic_load_n(&arc_spare_cap, __ATOMIC_RELAXED) == ncap) return;
    /* a spare of the wrong size (the last compaction's old table, and
     * now live wants a doubling, or the reverse): retire it here, off
     * the lock, so the right one can be taken below */
    fpr_lock(&arc_lock);
    if (arc_spare == sp && arc_spare_cap != ncap) arc_spare = 0; else sp = 0;
    fpr_unlock(&arc_lock);
    if (sp) arc_block_free(sp);
  }
  arcent_t *nt = (arcent_t *)arc_block(ncap * sizeof(arcent_t), 0);
  if (!nt) return; /* the direct fallback under the lock has the last word */
  fpr_lock(&arc_lock);
  if (!arc_spare && arc_cap == cap) { arc_spare = nt; arc_spare_cap = ncap; nt = 0; }
  fpr_unlock(&arc_lock);
  if (nt) arc_block_free(nt);
}
/* under arc_lock: rehash the live entries into a table of arc_next_cap
 * slots -- the same size when little is live (a compaction, counted in
 * arc_compactions), twice the size otherwise (counted in arc_grows).
 * Tombstones are left behind either way.  A spare of the right size
 * (arc_reserve, taken before the lock) is used; one of the wrong size
 * -- live moved between the reservation and now -- goes back (the
 * reservation retires a wrong-sized spare too).  After a compaction the OLD
 * table becomes the spare for the next one: same-size rehashing in
 * steady churn then allocates nothing. */
static uw arc_compactions;
static void arc_grow(void) {
  uw ncap = arc_next_cap(arc_cap, arc_live);
  arcent_t *nt = 0;
  if (arc_spare) {
    if (arc_spare_cap == ncap) nt = arc_spare;
    else arc_block_free(arc_spare);
    arc_spare = 0;
  }
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
  if (ncap == ocap) { arc_spare = ot; arc_spare_cap = ocap; arc_compactions++; }
  else { arc_block_free(ot); arc_grows++; }
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
uw fpr_arc_compactions_count(void) { return arc_compactions; }
uw fpr_arc_used(void) { return arc_used; }

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
/* under arc_lock, at an insertion: the slab now has (had) a promoted
 * object -- fpr_arc_decref's pre-check reads this before the lock */
static void arc_mark_promoted(fpr_slab_t *sl) {
  if (!sl->promoted) __atomic_store_n(&sl->promoted, 1, __ATOMIC_RELEASE);
}
void fpr_arc_incref(V v) {
  if (fpr_plane_memory) { fpr_plane_memory->arc_incref(v); return; }
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
    if (sl) { sl->escaped++; arc_mark_promoted(sl); }
  }
  arct[i].cnt++;
  fpr_unlock(&arc_lock);
}

static void arc_decref_in(V v);
void fpr_arc_decref(V v) {
  if (fpr_plane_memory) { fpr_plane_memory->arc_decref(v); return; }
  if (arc_by_value(v)) return;
  /* a holder letting go of a root it received this turn: the turn's list
   * forgets it, or the boundary would release it a second time */
  fpr_hart_t *fh = fpr_hart();
  if (fh && fh->current) fpr_rx_forget(fh->current, v);
  arc_decref_in(v);
}
static void arc_decref_in(V v) {
  /* THE LOCK-FREE PRE-CHECK.  A value whose slab has never held a
   * promoted object has no entry: the lock would be taken only to find
   * nothing.  Sound because (1) only a holder of v drops it; (2) a
   * second holder exists only after a send or share, which inserts the
   * handed-over pointer under arc_lock -- setting the flag -- before the
   * mailbox push that publishes it (a release), and the receiver's pop
   * acquires: the flag's store happens-before every decref that has an
   * entry to find; (3) the flag is set for every insertion (the two
   * `arc_live++` sites) and cleared only when the slab is reissued, when
   * nothing in it is referenced.  A flag seen set takes the old path. */
  fpr_slab_t *psl = slab_of(v);
  if (psl && !__atomic_load_n(&psl->promoted, __ATOMIC_ACQUIRE)) {
    FPR_COST_ADD(fpr_hart(), xr_drop_miss_n, 1);
    return;
  }
  fpr_lock(&arc_lock);
  int found;
  uw i = arc_probe(v, &found);
  if (!found) { fpr_unlock(&arc_lock); FPR_COST_ADD(fpr_hart(), xr_drop_miss_n, 1); return; } /* never shared: no-op */
  FPR_COST_ADD(fpr_hart(), xr_drop_hit_n, 1);
  /* Every holder's post-drop borrow counts, including a non-final drop.
   * Otherwise the final holder could reset a fixed grant underneath an
   * earlier reader whose borrow window has not closed. */
  fpr_slab_t *fixed_sl = slab_of(v);
  if (fixed_sl && fixed_sl->owner && fixed_sl->owner->fixed_heap)
    fpr_drop_park(fixed_sl);
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
      } else if (sl->owner->fixed_heap) {
        /* A retained fixed grant may reset while another actor is still
         * reading after drop. Keep that borrow visible to reset/death. */
        /* Retain locally until reset; the hold was recorded above. */
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
  fpr_bump_close(fpr_hart()); /* the window can only be over a pool of this hart's */
  fpr_lock(&arc_lock);
  fpr_slab_t *sl = pool->cur;
  while (sl) {
    fpr_slab_t *nx = sl->next;
    if (sl->escaped == 0 && sl->holds == 0) slab_home(sl); /* home: the memory actor, or the
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
  if (fpr_plane_memory) { fpr_plane_memory->pool_reset(); return (V)&fpr_unit; }
  fpr_hart_t *h = fpr_hart();
  fpr_pool_t *pool = cur_pool(h);
  fpr_bump_close(h);
  if (h->current) fpr_rx_release_outer(h->current); /* the turn's received roots die with it */
  fpr_drop_drain_current(); /* soft death = end of frame: borrows are done */
  fpr_lock(&arc_lock);
  fpr_slab_t *sl = pool->cur;
  if (pool->fixed_heap) {
    if (!sl || sl->escaped || sl->holds) {
      fpr_unlock(&arc_lock);
      fpr_actor_fail("fixed heap: reset blocked by escaped data");
    }
    sl->hp = fpr_slab_start(sl);
    pool->allocated = 0; pool->bigfree = 0;
    if (pool->buckets)
      for (int i = 0; i < FPR_NBUCKETS; i++) pool->buckets[i] = 0;
    fpr_unlock(&arc_lock);
    return (V)&fpr_unit;
  }
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
 * ARC.qa (docs/2026-08-29-MEMORY-V2-PLAN.md phase 4) replaces the table+lock
 * underneath without changing this contract. */
void fpr_arc_promote_share(V v) {
  if (fpr_plane_memory) { fpr_plane_memory->arc_incref(v); return; }
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
    if (sl) { sl->escaped++; arc_mark_promoted(sl); }
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
  if (fpr_plane_memory) return 0; /* shared plane: conservative copy path */
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

/* ---- the received roots of a turn (fpr.h fpr_rx_t) -------------------
 * Owner-only: the actor itself pushes, forgets and releases; the reaper
 * reclaims once the actor can no longer run.  No lock. */
static uw rx_grows, rx_hwm;
uw fpr_rx_grows_count(void) { return __atomic_load_n(&rx_grows, __ATOMIC_RELAXED); }
uw fpr_rx_hwm(void) { return __atomic_load_n(&rx_hwm, __ATOMIC_RELAXED); }
static void rx_inline(fpr_rx_t *r) { r->roots = r->rx0; r->cap = FPR_RX_INLINE; r->n = 0; r->block = 0; }
#ifndef FPR_RX_CHARGE
#define FPR_RX_CHARGE ((uw)64) /* a root: at least a message header and its slot; 1,024 to a slab */
#endif
void fpr_rx_push(struct fpr_acb *a, V m) {
  if (!a || arc_by_value(m)) return; /* ints, statics, actor handles: nothing to release */
  /* A received root holds its message, and the message holds the sender's
   * message slab, until the root is released at a region boundary.  A
   * receive loop cycles its region when the hart's allocation clock has
   * moved a slab since its mark (docs/2026-10-26-RECEIVE-TURNS-PER-SLAB.md),
   * so the clock counts what the roots pin: FPR_RX_CHARGE per root (which
   * also bounds the roots a cycle holds) and a whole slab the first time a
   * root pins one the open region has not been charged for. */
#ifndef FPR_BUILTIN /* the builtin profile places no compiler regions */
  if (!fpr_plane_memory) {
    fpr_hart_t *h = fpr_hart();
    if (h && h->current == a) {
      uw charge = FPR_RX_CHARGE;
      struct fpr_scope *sc = *scope_head(h);
      fpr_slab_t *sl = slab_of(m);
      if (sc && sc->msg_slab != sl) { sc->msg_slab = sl; charge += FPR_REGION_SLAB; }
      h->region_bytes += charge;
    }
  }
#endif
  fpr_rx_t *r = fpr_acb_rx(a);
  if (!r->roots) rx_inline(r);
  if (r->n == r->cap) {
    /* doubling, counted: a turn that receives more than the inline eight
     * (a batch drain, or a receive loop the compiler did not recognise) */
    uw ncap = r->cap * 2;
    fpr_slab_t *sl = fpr_slab_new(ncap * sizeof(V) + sizeof(fpr_slab_t)); /* may park */
    if (!sl) fpr_exhausted("receive: no block for the turn's received roots");
    V *nb = (V *)(sl + 1);
    __builtin_memcpy(nb, r->roots, r->n * sizeof(V));
    if (r->block) fpr_slab_release(r->block);
    r->block = sl;
    r->roots = nb;
    r->cap = (uw)(sl->end - (char *)nb) / sizeof(V);
    __atomic_fetch_add(&rx_grows, 1, __ATOMIC_RELAXED);
  }
  r->roots[r->n++] = m;
  uw hwm = __atomic_load_n(&rx_hwm, __ATOMIC_RELAXED);
  while (r->n > hwm && !__atomic_compare_exchange_n(&rx_hwm, &hwm, r->n, 0, __ATOMIC_RELAXED, __ATOMIC_RELAXED)) {}
}
void fpr_rx_release(struct fpr_acb *a, uw mark) {
  fpr_rx_t *r = fpr_acb_rx(a);
  while (r->n > mark) {
    V m = r->roots[--r->n]; /* popped first: the decref must not forget it again */
    if (fpr_plane_memory) fpr_plane_memory->arc_decref(m); else arc_decref_in(m);
  }
}
void fpr_rx_forget(struct fpr_acb *a, V m) {
  fpr_rx_t *r = fpr_acb_rx(a);
  for (uw i = r->n; i-- > 0;) {
    if (r->roots[i] != m) continue;
    for (uw j = i + 1; j < r->n; j++) r->roots[j - 1] = r->roots[j]; /* order kept: the marks index it */
    r->n--;
    for (struct fpr_scope *sc = *fpr_acb_scope_slot(a); sc; sc = sc->previous)
      if (sc->rx_mark > i) sc->rx_mark--;
    return;
  }
}
/* Sys.poolReset: the actor's own turn boundary.  The roots no open region
 * owns -- those received outside every Sys.loop / arena scope, the ones a
 * hand-written loop with an explicit reset holds -- die here; a region
 * still open keeps the roots its current turn took (its state has not
 * been copied out yet).  The marks move down with the list. */
void fpr_rx_release_outer(struct fpr_acb *a) {
  fpr_rx_t *r = fpr_acb_rx(a);
  if (!r->roots || !r->n) return;
  uw k = r->n;
  for (struct fpr_scope *sc = *fpr_acb_scope_slot(a); sc; sc = sc->previous) k = sc->rx_mark; /* the oldest's */
  if (!k) return;
  for (uw i = k; i-- > 0;) {
    V m = r->roots[i];
    if (fpr_plane_memory) fpr_plane_memory->arc_decref(m); else arc_decref_in(m);
  }
  for (uw j = k; j < r->n; j++) r->roots[j - k] = r->roots[j];
  r->n -= k;
  for (struct fpr_scope *sc = *fpr_acb_scope_slot(a); sc; sc = sc->previous) sc->rx_mark -= k;
}
void fpr_pends_reclaim(struct fpr_acb *a) {
  fpr_pends_t *ps = fpr_acb_pends(a);
  if (ps->block) { fpr_slab_release(ps->block); ps->block = 0; }
  ps->v = 0; ps->n = 0; ps->cap = 0;
}
void fpr_rx_reclaim(struct fpr_acb *a) {
  fpr_rx_t *r = fpr_acb_rx(a);
  if (!r->roots) return;
  fpr_rx_release(a, 0);
  if (r->block) { fpr_slab_release(r->block); r->block = 0; }
  rx_inline(r);
}

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

static V g_drop(V v) {
#ifdef FPR_COST_PROBE
  uint64_t d0 = FPR_PROBE_NOW();
  fpr_arc_decref(v);
  FPR_COST_ADD(fpr_hart(), xr_drop_ns, FPR_PROBE_NOW() - d0);
#else
  fpr_arc_decref(v);
#endif
  return (V)&fpr_unit;
}

/* There are exactly 256 one-byte Strings. Like a string literal, each is an
 * immutable static: chr needs no actor allocation, even inside a tight text
 * encoder. A table in a mortal process image follows the existing static-data
 * copy rule when sent outside that image; it is not a global heap cache. */
typedef struct {
  uint32_t tid, var;
  uw len;
  uint8_t bytes[1];
} __attribute__((aligned(8))) byte_str_t;
_Static_assert(__builtin_offsetof(byte_str_t, bytes) == __builtin_offsetof(str_t, bytes),
               "byte String layout");
#define BYTE_STR(n) { T_STR, 0, 1, { (n) } }
#define BYTE_STR_16(n) \
  BYTE_STR((n)+0), BYTE_STR((n)+1), BYTE_STR((n)+2), BYTE_STR((n)+3), \
  BYTE_STR((n)+4), BYTE_STR((n)+5), BYTE_STR((n)+6), BYTE_STR((n)+7), \
  BYTE_STR((n)+8), BYTE_STR((n)+9), BYTE_STR((n)+10), BYTE_STR((n)+11), \
  BYTE_STR((n)+12), BYTE_STR((n)+13), BYTE_STR((n)+14), BYTE_STR((n)+15)
static const byte_str_t byte_strings[256] = {
  BYTE_STR_16(0), BYTE_STR_16(16), BYTE_STR_16(32), BYTE_STR_16(48),
  BYTE_STR_16(64), BYTE_STR_16(80), BYTE_STR_16(96), BYTE_STR_16(112),
  BYTE_STR_16(128), BYTE_STR_16(144), BYTE_STR_16(160), BYTE_STR_16(176),
  BYTE_STR_16(192), BYTE_STR_16(208), BYTE_STR_16(224), BYTE_STR_16(240)
};
#undef BYTE_STR_16
#undef BYTE_STR
static const byte_str_t empty_string = { T_STR, 0, 0, { 0 } };

/* substr s off len -- the bytes [off, off + len), 0-based, clamped. Mechanism, not
 * policy: diskfs chunks payloads into pages (write) and takes the used
 * prefix of a page (read) with this; doing it via chr+strcat would be
 * one allocation PER BYTE of every page moved. */
static V g_substr(V sv, V off, V len) {
  if (ISINT(sv) || TID(sv) != T_STR) fpr_trap("substr: not a String");
  str_t *s = (str_t *)sv;
  sw o = UNTAG(off), l = UNTAG(len);
  if (o < 0) { l += o; o = 0; } /* [off, off+len) cut to the string, both ends */
  if (l < 0) l = 0;
  if ((uw)o >= s->len) { o = 0; l = 0; }
  if ((uw)l > s->len - (uw)o) l = (sw)(s->len - (uw)o);
  if (!l) return (V)&empty_string;
  if (l == 1) return (V)&byte_strings[s->bytes[o]];
  /* A borrowed input can die at the next receive or explicit drop. Keep
   * heap-backed slices independently owned, even for a whole-string cut. */
  if (!o && (uw)l == s->len && !fpr_in_heap(sv)) return sv;
  return (V)fpr_mkstr(s->bytes + o, (uw)l);
}
/* ---- strJoin: the string operation a library cannot build cheaply -------
 * One allocation and a copy; joining n pieces by repeated strcat copies the
 * accumulator n times (docs/2026-09-19-PRELIM_BASE_LIBRARY_DESIGN.md).
 * strCmp, strIndexOf, strIndexFrom and parseInt are FP-RISC in
 * core/prelude.fpr, with Sol's names and contracts. */
static str_t *want_str(V v, const char *who) {
  if (ISINT(v) || TID(v) != T_STR) fpr_trap(who);
  return (str_t *)v;
}
static int is_cons(V v) { return !ISINT(v) && TID(v) == T_LIST && ((hdr_t *)v)->var == 1; }
static V g_strJoin(V sepv, V list) {
  str_t *sep = want_str(sepv, "strJoin: the separator is not a String");
  uw total = 0, n = 0;
  str_t *piece = 0;
  for (V c = list; is_cons(c); c = ((V *)((char *)c + 8))[1]) {
    str_t *x = want_str(((V *)((char *)c + 8))[0], "strJoin: not a List of String");
    if (x->len) {
      if (x->len > ~(uw)0 - total) fpr_trap("strJoin: size overflow");
      total += x->len;
      piece = x;
    }
    n++;
  }
  if (n > 1 && sep->len) {
    if (sep->len > (~(uw)0 - total) / (n - 1)) fpr_trap("strJoin: size overflow");
    total += (n - 1) * sep->len;
    if (!piece) piece = sep;
  }
  if (!total) return (V)&empty_string;
  if (total == 1) return (V)&byte_strings[piece->bytes[0]];
  if (total > ~(uw)0 - sizeof(str_t)) fpr_trap("strJoin: size overflow");
  if (piece->len == total) {
    if (!fpr_in_heap((V)piece)) return (V)piece;
    return (V)fpr_mkstr(piece->bytes, total);
  }
  str_t *out = (str_t *)fpr_alloc(sizeof(str_t) + total);
  out->tid = T_STR; out->var = 0; out->len = total;
  uw at = 0, i = 0;
  for (V c = list; is_cons(c); c = ((V *)((char *)c + 8))[1], i++) {
    str_t *x = (str_t *)((V *)((char *)c + 8))[0];
    if (i) { __builtin_memcpy(out->bytes + at, sep->bytes, sep->len); at += sep->len; }
    __builtin_memcpy(out->bytes + at, x->bytes, x->len);
    at += x->len;
  }
  return (V)out;
}
/* ---- strCompare: byte order, -1 / 0 / 1 (prelude strCmp) ---------------
 * memcmp (a byte loop off posix) over the shorter length, then the lengths: the answer the
 * prelude's byte loop gave, at memcmp's speed (a map keyed by String
 * compares at every node it passes). */
static V g_strCompare(V av, V bv) {
  str_t *a = want_str(av, "strCompare: not a String");
  str_t *b = want_str(bv, "strCompare: not a String");
  uw n = a->len < b->len ? a->len : b->len;
  /* a word at a time, no libc (freestanding images link no memcmp, and map
   * keys are short: the call cost more than the compare).  The first
   * differing word, read big-endian, orders as its first differing byte. */
  int c = 0;
  uw i = 0;
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
  for (; i + 8 <= n; i += 8) {
    uint64_t p, q;
    __builtin_memcpy(&p, a->bytes + i, 8);
    __builtin_memcpy(&q, b->bytes + i, 8);
    if (p != q) { p = __builtin_bswap64(p); q = __builtin_bswap64(q); c = p < q ? -1 : 1; break; }
  }
#endif
  for (; !c && i < n; i++) if (a->bytes[i] != b->bytes[i]) c = a->bytes[i] < b->bytes[i] ? -1 : 1;
  if (c == 0) c = a->len < b->len ? -1 : a->len > b->len ? 1 : 0;
  return TAG(c);
}
/* $fnIs f g: f is the function value g -- the same code, nothing captured
 * (Reuse lookupTwins: a map lookup's comparator, against the one the unit's
 * empty maps all carry).  Anything else answers False, and the caller takes
 * its general path. */
static V g_fn_is(V f, V g) {
  if (ISINT(f) || ISINT(g) || !f || !g || TID(f) != T_PAP || TID(g) != T_PAP) return (V)&fpr_false;
  pap_t *a = (pap_t *)f, *b = (pap_t *)g;
  return a->fn == b->fn && a->nargs == 0 && b->nargs == 0 && a->arity == b->arity ? (V)&fpr_true : (V)&fpr_false;
}
static V g_arcLive(V d) {
  (void)d;
  if (fpr_plane_memory) return TAG((sw)fpr_plane_memory->arc_live());
  return TAG(fpr_arc_live());
}



/* ---- panic ---------------------------------------------------------- */
/* The core writes '\n' and nothing else.  Whether a line also needs a
 * carriage return is a fact about the DEVICE -- a raw 16550 does, a posix
 * stream does not -- so it is hal_putc's to add (machine/virt, machine/builtin).
 * It used to be inserted here, which made every hosted program's stdout
 * CRLF and every check pipe its output through `tr -d '\r'`. */
/* Diagnostics -- a panic's last words, and [warn]/[ERR] log echo -- go to
 * hal_eputc.  On a board with one console it IS hal_putc (this weak
 * default); a hosted target (machine/posix) defines it to write stderr, so
 * a program's stdout carries only what the program printed and a pipeline
 * never mistakes a panic for data.  FPR_DIAG_STDOUT=1 restores the old
 * single-stream behaviour there (roadmap #39, item C). */
__attribute__((weak)) void hal_console_bytes(const char *bytes, uw len) {
  for (uw i = 0; i < len; i++) hal_putc(bytes[i]);
}
__attribute__((weak)) void hal_eputc(char c) { hal_putc(c); }
__attribute__((weak)) void hal_diag_bytes(const char *bytes, uw len) {
  for (uw i = 0; i < len; i++) hal_eputc(bytes[i]);
}
static void praw(const char *s) {
  while (*s) hal_eputc(*s++);
}

extern uw fpr_current_id(void);
static void pdec(uw u) {
  char b[24]; int i = 23;
  if (u == 0) b[i--] = '0';
  while (u) { b[i--] = '0' + (u % 10); u /= 10; }
  for (int j = i + 1; j <= 23; j++) hal_eputc(b[j]);
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
/* the message is (bytes, length), not a C string: a user's `error` text is
 * printed from its own String, whole, with no copy into a shared buffer */
void fpr_cpanic_n(const char *m, uw n) {
  static int in_panic;
  if (!in_panic) {
    in_panic = 1;
    fpr_logput(2, m, n); /* the error ring keeps the last words */
    if (fpr_panic_persist) fpr_panic_persist(m, n);
  }
  praw("\n*** FPRISC PANIC [actor ");
  pdec(fpr_current_id());
  praw("]: ");
  for (uw i = 0; i < n; i++) hal_eputc(m[i]);
  praw(" ***\n");
  hal_poweroff(1); /* QEMU: exit 1; real HW: no-op, park below */
  for (;;) FPR_PARK();
}
void fpr_cpanic(const char *m) {
  uw n = 0;
  while (m[n]) n++;
  fpr_cpanic_n(m, n);
}

#endif

/* the `error` builtin's V-taking twin: funnel through fpr_cpanic so a
 * user-level panic reaches the error ring and the persist hook exactly
 * like a runtime one (it previously printed raw and died -- last words
 * that never made /logs/errors). */
void fpr_panic(V s) {
  if (!ISINT(s) && TID(s) == T_STR) {
    str_t *t = (str_t *)s;
    fpr_trap_n((const char *)t->bytes, t->len);
  }
  fpr_trap("error: its reason is not a String");
}

/* A trap is the program's own failure: `error`, an Int overflow, a division
 * by zero (docs/2026-10-15-HARDENING-DIRECTION.md, 1).  On an actor other
 * than 0 it is that actor's failure, not the machine's: the reason is logged
 * and kept on the actor, the actor dies and its watchers hear "dead actor:
 * <reason>" (receiveFromRes, std/actor's askSure), and everything else keeps
 * running.  A LOADED PROCESS on the shared plane fails through the plane's
 * fail-stop (the launcher reports the root; QOS tools/error-process-check.sh).
 * Actor 0 is the program: a trap there panics as before, and a machine
 * invariant (fpr_cpanic) always does.  Builtin images have no actor plane. */
void fpr_trap_n(const char *m, uw n) {
#ifndef FPR_BUILTIN
  if (!fpr_plane_actors && fpr_actor_is_program()) fpr_cpanic_n(m, n); /* the whole text, however long */
  char why[FPR_WHY_BYTES + 80];
  uw k = n < sizeof why - 1 ? n : sizeof why - 1;
  for (uw i = 0; i < k; i++) why[i] = m[i];
  why[k] = 0;
  fpr_actor_fail(why);
#else
  fpr_cpanic_n(m, n);
#endif
}
void fpr_trap(const char *m) {
  uw n = 0;
  while (m[n]) n++;
  fpr_trap_n(m, n);
}

volatile uint32_t fpr_shutdown; /* hart loops park when set */

void fpr_exit(V result) {
  extern void fpr_render_to_uart(V v); /* below */
  __atomic_store_n(&fpr_shutdown, 1, __ATOMIC_RELEASE);
#if defined(FPR_POSIX) && !defined(FPR_QOSAPP)
  /* the Base profile (machine/posix): an ordinary process.  Nothing is
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
  fpr_cpanic("apply: arity > 64 (8 registers + FPR_ARGSPILL)");
}

V fpr_apply(V f, V a) {
  if (ISINT(f)) fpr_trap("apply: applied an integer");
  pap_t *p = (pap_t *)f;
  if (p->tid != T_PAP) fpr_trap("apply: not a function value");
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

/* ---- sortListWith: List.sortWith's engine (std/list.fpr) ---------------
 * A STABLE merge sort over an array of the list's elements, then one fresh
 * list.  std/list's Ordering-returning comparator is called through its
 * closure, once per comparison, exactly as the FP-RISC merge sort did; only
 * the merging and the cells move to C.  Stable: the right run's element
 * goes first only when strictly Less, so equal elements keep their input
 * order.
 *   comparisons  <= n * ceil(log2 n)   (one fewer per merge; a merge whose
 *                                      runs are already in order costs one)
 *   cells        n fresh cons cells (16 + 8 bytes each), the input's Nil reused
 *   scratch      3n words of raw pool memory (elements, permutation, merge
 *                buffer), freed before returning
 * The comparator answers std/order's Ordering (Less | Equal | Greater): a
 * nullary constructor, a static whose `var` is its index, 0 for Less.  An
 * immediate (tagged) answer is refused rather than guessed at. */
static inline V apply2(V f, V a, V b) {
  if (!ISINT(f) && TID(f) == T_PAP) {
    pap_t *p = (pap_t *)f;
    if (p->nargs == 0 && p->arity == 2) return ((F2)p->fn)(a, b);
    if (p->nargs == 1 && p->arity == 3) return ((F3)p->fn)(p->args[0], a, b);
    if (p->nargs == 2 && p->arity == 4) return ((F4)p->fn)(p->args[0], p->args[1], a, b);
    if (p->nargs + 2 == p->arity) {
      V args[8 + FPR_ARGSPILL];
      for (uw i = 0; i < p->nargs; i++) args[i] = p->args[i];
      args[p->nargs] = a;
      args[p->nargs + 1] = b;
      return callf(p->fn, p->arity, args);
    }
  }
  return fpr_apply(fpr_apply(f, a), b);
}
/* cmp b a answers Less: b goes first.  The argument order is the FP-RISC
 * merge's (`cmp y x`, y from the right run): the comparator sees its
 * arguments in the same roles.  For a comparator that is a total preorder
 * the result is exactly the old merge's; one that is not may see fewer
 * questions (the in-order shortcut) and so may order differently. */
static inline int sort_lt(V cmp, V b, V a) {
  V r = apply2(cmp, b, a);
  if (ISINT(r)) fpr_trap("sortWith: the comparator did not answer an Ordering");
  return ((hdr_t *)r)->var == 0;
}
/* merge runs src[lo..mid) and src[mid..hi) of indices into keys, to dst */
static void sort_merge(V cmp, const V *keys, const uw *src, uw *dst, uw lo, uw mid, uw hi) {
  uw i = lo, j = mid, k = lo;
  if (mid > lo && mid < hi && !sort_lt(cmp, keys[src[mid]], keys[src[mid - 1]])) {
    for (; k < hi; k++) dst[k] = src[k]; /* already in order: one comparison */
    return;
  }
  while (i < mid && j < hi) dst[k++] = sort_lt(cmp, keys[src[j]], keys[src[i]]) ? src[j++] : src[i++];
  while (i < mid) dst[k++] = src[i++];
  while (j < hi) dst[k++] = src[j++];
}
/* merge runs src[lo..mid) and src[mid..hi) of element values directly, to dst */
static void sort_merge_vals(V cmp, F2 fn2, const V *src, V *dst, uw lo, uw mid, uw hi) {
  uw i = lo, j = mid, k = lo;
  if (fn2) {
    if (mid > lo && mid < hi) {
      V r = fn2(src[mid], src[mid - 1]);
      if (ISINT(r)) fpr_trap("sortWith: the comparator did not answer an Ordering");
      if (((hdr_t *)r)->var != 0) {
        for (; k < hi; k++) dst[k] = src[k];
        return;
      }
    }
    while (i < mid && j < hi) {
      V r = fn2(src[j], src[i]);
      if (ISINT(r)) fpr_trap("sortWith: the comparator did not answer an Ordering");
      dst[k++] = (((hdr_t *)r)->var == 0) ? src[j++] : src[i++];
    }
  } else {
    if (mid > lo && mid < hi && !sort_lt(cmp, src[mid], src[mid - 1])) {
      for (; k < hi; k++) dst[k] = src[k];
      return;
    }
    while (i < mid && j < hi) dst[k++] = sort_lt(cmp, src[j], src[i]) ? src[j++] : src[i++];
  }
  while (i < mid) dst[k++] = src[i++];
  while (j < hi) dst[k++] = src[j++];
}
/* The stable order of keys[0..n) under cmp, as a permutation: answers the
 * buffer (idx or tmp, both n words) holding perm, keys[perm[0]] first.
 * Bottom-up: runs of width w merged into runs of 2w, ceil(log2 n) passes.
 * Shared by Vec.sortWith (vec.c), which moves every column by the same
 * permutation. */
uw *fpr_sort_perm(V cmp, const V *keys, uw *idx, uw *tmp, uw n) {
  for (uw i = 0; i < n; i++) idx[i] = i;
  uw *src = idx, *dst = tmp;
  for (uw w = 1; w < n; w *= 2) {
    for (uw lo = 0; lo < n; lo += 2 * w) {
      uw mid = lo + w < n ? lo + w : n;
      uw hi = lo + 2 * w < n ? lo + 2 * w : n;
      sort_merge(cmp, keys, src, dst, lo, mid, hi);
    }
    uw *t = src; src = dst; dst = t;
  }
  return src;
}
static V g_sortListWith(V cmp, V list) {
  uw n = 0;
  V c = list;
  for (; is_cons(c); c = ((V *)((char *)c + 8))[1]) n++;
  V nil = c; /* the input's own Nil: shared, it carries nothing */
  if (n < 2) return list; /* a list of 0 or 1 is its own sort (persistent: shared) */
  V *buf = (V *)fpr_alloc_raw((V)(2 * n * sizeof(V)));
  V *src = buf, *dst = buf + n;
  uw i = 0;
  for (c = list; is_cons(c); c = ((V *)((char *)c + 8))[1]) src[i++] = ((V *)((char *)c + 8))[0];
  F2 fn2 = (F2)0;
  if (!ISINT(cmp) && TID(cmp) == T_PAP) {
    pap_t *p = (pap_t *)cmp;
    if (p->nargs == 0 && p->arity == 2) fn2 = (F2)p->fn;
  }
  for (uw w = 1; w < n; w *= 2) {
    for (uw lo = 0; lo < n; lo += 2 * w) {
      uw mid = lo + w < n ? lo + w : n;
      uw hi = lo + 2 * w < n ? lo + 2 * w : n;
      sort_merge_vals(cmp, fn2, src, dst, lo, mid, hi);
    }
    V *t = src; src = dst; dst = t;
  }
  V acc = nil;
  for (uw k = n; k > 0; k--) {
    hdr_t *cell = (hdr_t *)fpr_alloc(8 + 2 * sizeof(uw));
    cell->tid = T_LIST;
    cell->var = 1;
    *(V *)((char *)cell + 8) = src[k - 1];
    *(V *)((char *)cell + 8 + sizeof(uw)) = acc;
    acc = (V)cell;
  }
  fpr_free_raw((V)buf);
  return acc;
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
    if (ISINT(f)) fpr_trap("apply: applied an integer");
    pap_t *p = (pap_t *)f;
    if (p->tid != T_PAP) fpr_trap("apply: not a function value");
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

int fpr_list_ints(V list, uw *out, uw n) {
  for (uw i = 0; i < n; i++) {
    if (ISINT(list) || !list) return 0;
    hdr_t *c = (hdr_t *)list;
    if (c->tid != T_LIST || c->var != 1) return 0; /* Nil before n, or not a list */
    V *f = (V *)((char *)c + 8);
    if (!ISINT(f[0])) return 0;
    out[i] = (uw)UNTAG(f[0]);
    list = f[1];
  }
  return 1;
}

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
/* Int arithmetic TRAPS on overflow (docs/2026-10-12-INT-OVERFLOW.md): the
 * mathematical result must fit the tagged Int, -2^(W-2) .. 2^(W-2)-1 for
 * a W-bit word.  Nothing wraps silently; I64 is the type that wraps, by
 * contract.  The inline fast paths (Codegen inlineTable, genU) check the
 * same condition and come HERE for the panic, which names the operands. */
static char *put_dec(char *p, sw n) {
  uw m = n < 0 ? (uw)0 - (uw)n : (uw)n;
  char d[24]; int k = 0;
  do { d[k++] = (char)('0' + m % 10); m /= 10; } while (m);
  if (n < 0) *p++ = '-';
  while (k) *p++ = d[--k];
  return p;
}
static char *put_str(char *p, const char *s) { while (*s) *p++ = *s++; return p; }
void fpr_cpanic_num(const char *pre, sw n, const char *post) {
  static char buf[192]; char *p = buf;
  p = put_str(p, pre); p = put_dec(p, n); p = put_str(p, post);
  fpr_cpanic_n(buf, (uw)(p - buf));
}
/* A refusal of a VALUE -- an index past the end, a code that is not a byte, a
 * divisor of zero, a full buffer -- is the program's own failure, so it is a
 * trap: it ends the actor that asked, with the reason, and not the machine
 * (fpr_trap_n; on actor 0 it is the panic it always was).  A value of the
 * wrong TYPE cannot reach a primitive from a typed program: that stays a
 * machine invariant (fpr_cpanic). */
void fpr_trap_num(const char *pre, sw n, const char *post) {
  char buf[192]; char *p = buf;
  p = put_str(p, pre); p = put_dec(p, n); p = put_str(p, post);
  fpr_trap_n(buf, (uw)(p - buf));
}
/* "<what> (<index>, length <len>)": which index, against what */
void fpr_trap_range(const char *what, sw k, uw len) {
  char buf[192]; char *p = buf;
  p = put_str(p, what); p = put_str(p, " ("); p = put_dec(p, k);
  p = put_str(p, ", length "); p = put_dec(p, (sw)len); p = put_str(p, ")");
  fpr_trap_n(buf, (uw)(p - buf));
}
#define INT_MIN_TAGGED (-((sw)1 << (sizeof(sw) * 8 - 2)))
#define INT_MAX_TAGGED (((sw)1 << (sizeof(sw) * 8 - 2)) - 1)
static int fits_int(sw n) { return ((sw)((uw)n << 1) >> 1) == n; }
static void int_overflow(const char *op, sw a, sw b) __attribute__((noreturn));
static void int_overflow(const char *op, sw a, sw b) {
  static char buf[192]; char *p = buf;
  p = put_str(p, "Int overflow: "); p = put_dec(p, a); p = put_str(p, " "); p = put_str(p, op);
  p = put_str(p, " "); p = put_dec(p, b); p = put_str(p, " does not fit an Int (");
  p = put_dec(p, INT_MIN_TAGGED); p = put_str(p, ".."); p = put_dec(p, INT_MAX_TAGGED);
  p = put_str(p, "); I64 is the type that wraps");
  fpr_trap_n(buf, (uw)(p - buf));
}
/* the traps of the unboxed vector kernels (Codegen genU, the NEON lanes):
 * entries, not strings, so a kernel links alone against a probe */
void fpr_int_overflow_kernel(void) {
  static char buf[160]; char *p = buf;
  p = put_str(p, "Int overflow in a vector kernel: the result does not fit an Int (");
  p = put_dec(p, INT_MIN_TAGGED); p = put_str(p, ".."); p = put_dec(p, INT_MAX_TAGGED);
  p = put_str(p, "); I64 is the type that wraps");
  fpr_trap_n(buf, (uw)(p - buf));
}
void fpr_div_zero_kernel(void) { fpr_trap("division by zero"); }
V fpr_prim_fn__x2b(V a, V b) {
  sw x = UNTAG(a), y = UNTAG(b), r;
  if (__builtin_add_overflow(x, y, &r) || !fits_int(r)) int_overflow("+", x, y);
  return TAG(r);
}
V fpr_prim_fn__x2d(V a, V b) {
  sw x = UNTAG(a), y = UNTAG(b), r;
  if (__builtin_sub_overflow(x, y, &r) || !fits_int(r)) int_overflow("-", x, y);
  return TAG(r);
}
V fpr_prim_fn__x2a(V a, V b) {
  sw x = UNTAG(a), y = UNTAG(b), r;
  if (__builtin_mul_overflow(x, y, &r) || !fits_int(r)) int_overflow("*", x, y);
  return TAG(r);
}
V fpr_prim_fn__x2f(V a, V b) {
  sw x = UNTAG(a), y = UNTAG(b);
  if (y == 0) fpr_trap("division by zero");
  sw r = x / y; /* the one overflow: the most negative Int / -1 */
  if (!fits_int(r)) int_overflow("/", x, y);
  return TAG(r);
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
static uint64_t u64(V);
/* Uniform boundaries use boxed float leaves on either word size. Ordinary
 * RV64 float primitives still use raw bits, so their dbits/fbits helpers must
 * not be used to interpret one of these managed objects. */
static double boxed_dbits(V v) {
  union { uint64_t u; double d; } c = {((fpr_num64_t *)v)->val};
  return c.d;
}
static float boxed_fbits(V v) {
  union { uint32_t u; float f; } c = {(uint32_t)((bits_t *)v)->val};
  return c.f;
}
#ifdef FPR_BUILTIN_RAW
extern uw fpr_builtin_field_count(V);
extern char fpr_builtin_field_kind(V,uw);
#endif
/* one pair, without descending: 0 differ, 1 equal, 2 compare the fields */
static int veq_shallow(V a, V b) {
  if (ISINT(a) || ISINT(b)) return a == b;
  /* IEEE equality also applies when both references name the same NaN. */
  if (a && b && TID(a) == T_BITS && TID(b) == T_BITS &&
      ((hdr_t *)a)->var == ((hdr_t *)b)->var) {
    if (((hdr_t *)a)->var == 5) return boxed_dbits(a) == boxed_dbits(b);
    if (((hdr_t *)a)->var == 6) return boxed_fbits(a) == boxed_fbits(b);
  }
  if (a == b) {
#ifdef FPR_BUILTIN_RAW
    /* A shared ADT may contain NaN, so identity cannot skip numeric equality. */
    if (!fpr_in_heap(a) || !fpr_builtin_field_count(a)) return 1;
#elif UINTPTR_MAX <= 0xFFFFFFFFu
    /* RV32 aggregates contain boxed numeric leaves. Even a value compared
     * with itself must visit those leaves: NaN remains unequal to itself.
     * Opaque handles, vectors and scalar leaves keep identity equality. */
    if (!fpr_in_heap(a)) return 1;
    switch (TID(a)) {
      case T_STR: case T_BITS: case T_VEC: case T_ACTOR: case T_PAP:
      case T_DEVICE: case T_REGISTER: case T_SSTR: return 1;
      default: break;
    }
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
  if (x->tid == T_BITS && x->var == 4) return u64(a) == u64(b);
  if (x->tid == T_BITS && x->var == 7)
    return (uint32_t)((bits_t *)a)->val == (uint32_t)((bits_t *)b)->val;
  if (x->tid == T_BITS && (x->var == 2 || x->var == 3)) /* Word, Addr */
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
    uw nf;
    if (TID(a) == T_STORED_LIST) {
      nf = spine_payloads(a) + 1;
    } else if (TID(a) == T_LIST) {
      /* Cons has exactly two fields. A coalescing allocator can give equal
       * lists different capacities when a free block is too small to split;
       * capacity and zero padding are not part of a list's value. */
      nf = ((hdr_t *)a)->var == 1 ? 2 : 0;
    } else {
      uw ta = PREHEADER(a), tb = PREHEADER(b);
      if (ta != tb) { eq = 0; break; }
      if (ta < 24) continue;
      nf = (ta - FPR_MANAGED_PREFIX - 8) / sizeof(uw);
    }
#endif
    if (n + nf > cap) {
      uw ncap = cap;
      while (n + nf > ncap) ncap *= 2;
      if (spill) spill = fpr_realloc_raw(spill, (V)(ncap * sizeof(veq_pair_t)));
      else {
        spill = fpr_alloc_raw((V)(ncap * sizeof(veq_pair_t)));
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
  if (spill) fpr_free_raw(spill);
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
    fpr_trap("str/print: render buffer full (4096B) -- build large "
             "strings with strcat, not interpolation");
  rbuf[rpos++] = c;
}
static void render_bytes(const void *src, uw len) {
  if (len > (uw)(FPR_RBUF_SZ - 1 - rpos))
    fpr_trap("str/print: render buffer full (4096B) -- build large "
             "strings with strcat, not interpolation");
  __builtin_memcpy(rbuf + rpos, src, len);
  rpos += len;
}
static void remits(const char *s) {
  uw len = 0;
  while (s[len]) len++;
  render_bytes(s, len);
}
/* Sizing an integer piece needs only its decimal width. */
static uw decimal_width(sw value) {
  uw magnitude = value < 0 ? (uw)0 - (uw)value : (uw)value;
  uw width = 1 + (value < 0);
  while (magnitude >= 10000) {
    magnitude /= 10000;
    width += 4;
  }
  return width + (magnitude >= 10) + (magnitude >= 100) + (magnitude >= 1000);
}
static void write_decimal(uint8_t *dest, uw width, sw value) {
  uw magnitude = value < 0 ? (uw)0 - (uw)value : (uw)value;
  do {
    dest[--width] = (uint8_t)('0' + magnitude % 10);
    magnitude /= 10;
  } while (magnitude);
  if (value < 0) dest[0] = '-';
}

static void rdec(sw n) {
  uw width = decimal_width(n);
  if (width > (uw)(FPR_RBUF_SZ - 1 - rpos))
    fpr_trap("str/print: render buffer full (4096B) -- build large "
             "strings with strcat, not interpolation");
  write_decimal((uint8_t *)rbuf + rpos, width, n);
  rpos += width;
}
static void rdec64(int64_t n) {
  char b[24]; int i = 24;
  uint64_t m = n < 0 ? (uint64_t)0 - (uint64_t)n : (uint64_t)n;
  do { b[--i] = (char)('0' + m % 10u); m /= 10u; } while (m);
  if (n < 0) b[--i] = '-';
  render_bytes(b + i, (uw)(24 - i));
}
static void render(V v);
static uw dtoa(char *,double,int);
static void renderField(V obj,uw i) {
  V v=((V *)(obj+8))[i];
#ifdef FPR_BUILTIN_RAW
  char k=fpr_in_heap(obj)?fpr_builtin_field_kind(obj,i):'t';
  if(k=='w'||k=='a') { rdec((sw)v); return; }
  if(k=='d'||k=='f') {
    union { V u; double d; } d={v}; union { uint32_t u; float f; } f={(uint32_t)v};
    char b[40]; uw n=dtoa(b,k=='d'?d.d:(double)f.f,k=='d'?15:7);
    render_bytes(b, n);
    return;
  }
#endif
  render(v);
}
/* ---- constructor names --------------------------------------------------
 * The root unit of a program carries a table of every constructor in the
 * image (Compile.hs conTab): typeid, variant, arity, name.  This weak empty
 * one serves an image without (a library unit, a plugin).  With it a value
 * prints the way it is written: `Some 42`, `Node 1 Leaf Leaf`, `Err bad`. */
typedef struct { uw tid, var, arity; const char *name; } fpr_con_t;
__attribute__((weak)) const fpr_con_t fpr_contab[1] = {{0, 0, 0, 0}};

static const fpr_con_t *con_find(uw tid, uw var) {
  const fpr_con_t *volatile t = fpr_contab; /* (volatile: the weak [1] bound is not the real one) */
  int shape = tid >= 0x10000u && tid < 0x10000000u; /* a record: one row per shape */
  for (const fpr_con_t *c = t; c->name; c++)
    if (c->tid == tid && (shape || c->var == var)) return c;
  return 0;
}
static void render(V v);
/* an argument of a constructor: parenthesized when it is itself an application */
static void renderArg(V obj, int i) {
  V f = ((V *)((char *)obj + 8))[i];
  int paren = 0;
  if (ISINT(f)) paren = UNTAG(f) < 0;
  else {
    hdr_t *fh = (hdr_t *)f;
    const fpr_con_t *c = fh->tid >= 0x20000000u ? con_find(fh->tid, fh->var) : 0;
    paren = fh->tid == T_RESULT || (c && c->arity > 0) ||
            (fh->tid == T_BITS && fh->var == 7 &&
             (int32_t)(uint32_t)((bits_t *)f)->val < 0);
  }
  if (paren) remit('(');
  renderField(obj, i);
  if (paren) remit(')');
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
      render_bytes(s->bytes, s->len);
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
    case T_RESULT: remits(h->var ? "Err " : "Ok "); renderArg(v, 0); break;
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
    case T_BITS:
      if (h->var == 4) rdec64((int64_t)u64(v));
      else if (h->var == 7) rdec64((int32_t)(uint32_t)((bits_t *)v)->val);
      else if (h->var == 5 || h->var == 6) {
        char b[40];
        uw n = dtoa(b, h->var == 5 ? boxed_dbits(v) : (double)boxed_fbits(v), h->var == 5 ? 15 : 7);
        render_bytes(b, n);
      }
      else rdec((sw)((bits_t *)v)->val);
      break;
    case T_PAP: remits("<fn>"); break;
    default:
      if (h->tid > T_TUPN && h->tid < T_TUPN_END) { /* a wide tuple: its arity is in its typeid */
        remit('(');
        for (uw i = 0; i < h->tid - T_TUPN; i++) { if (i) remits(", "); renderField(v,i); }
        remit(')');
        break;
      }
      {
        const fpr_con_t *c = con_find(h->tid, h->var);
        if (c && h->tid < 0x10000000u) { /* a record: {a = 1, b = x} */
          const char *n = c->name;
          remit('{');
          for (uw i = 0; i < c->arity; i++) {
            if (i) remits(", ");
            const char *start = n;
            while (*n && *n != ',') n++;
            render_bytes(start, (uw)(n - start));
            if (*n) n++;
            remits(" = ");
            renderField(v, i);
          }
          remit('}');
          break;
        }
        if (c) {
          remits(c->name);
          for (uw i = 0; i < c->arity; i++) { remit(' '); renderArg(v, (int)i); }
          break;
        }
      }
      remit('<'); rdec(h->tid); remit('.'); rdec(h->var); remit('>'); break;
  }
}

V fpr_prim_fn_str(V v) {
  /* a String renders as itself: return it unchanged rather than
   * copying it through the fixed render buffer. This is what makes
   * "{s}" safe for strings of any size (and it saves the copy). */
  if (ISINT(v)) {
    sw value = UNTAG(v);
    if (value >= 0 && value <= 9) return (V)&byte_strings['0' + value];
    uw width = decimal_width(value);
    str_t *out = (str_t *)fpr_alloc(sizeof(str_t) + width);
    out->tid = T_STR; out->var = 0; out->len = width;
    write_decimal(out->bytes, width, value);
    return (V)out;
  }
  if (TID(v) == T_STR) return v;
  rpos = 0;
  render(v);
  /* Allocating can park this actor for a slab grant. Another actor on the
   * same hart may then render into rbuf (or this actor may migrate). Keep
   * the rendered bytes on this actor's stack BEFORE that allocation. */
  uint8_t snapshot[FPR_RBUF_SZ];
  uw n = (uw)rpos;
  __builtin_memcpy(snapshot, rbuf, n);
  return (V)fpr_mkstr(snapshot, n);
}

/* An interpolation's pieces in one tuple (Core.Opt.Pipeline buildStrings):
 * one String and one copy, however many pieces, where a strcat chain made
 * a String per piece and copied the front again at every step.  A String
 * piece is copied; anything else renders as str would, twice (to size, then
 * to copy): render is deterministic, and nothing allocates between a render
 * and its copy, so the hart's buffer cannot change under it. */
static uw pieces_arity(V t) {
  if (ISINT(t)) fpr_trap("string pieces: not a tuple");
  uw tid = TID(t);
  if (tid == T_TUP2) return 2;
  if (tid == T_TUP3) return 3;
  if (tid >= T_TUP4 && tid <= T_TUP8) return tid - T_TUP4 + 4;
  if (tid > T_TUPN && tid < T_TUPN_END) return tid - T_TUPN;
  fpr_trap("string pieces: not a tuple");
  return 0;
}
V fpr_prim_fn__x24strcatT(V t) {
  uw n = pieces_arity(t);
  uw total = 0;
  for (uw i = 0; i < n; i++) {
    V v = ((V *)((char *)t + 8))[i];
    uw len;
    if (ISINT(v)) len = decimal_width(UNTAG(v));
    else if (TID(v) == T_STR) len = ((str_t *)v)->len;
    else { rpos = 0; render(v); len = (uw)rpos; }
    if (len > ~(uw)0 - sizeof(str_t) - total) fpr_trap("string pieces: size overflow");
    total += len;
  }
  str_t *out = (str_t *)fpr_alloc(sizeof(str_t) + total);
  out->tid = T_STR;
  out->var = 0;
  out->len = total;
  uw at = 0;
  for (uw i = 0; i < n; i++) {
    V v = ((V *)((char *)t + 8))[i];
    if (ISINT(v)) {
      sw value = UNTAG(v);
      uw width = decimal_width(value);
      write_decimal(out->bytes + at, width, value);
      at += width;
    } else if (TID(v) == T_STR) {
      str_t *x = (str_t *)v;
      __builtin_memcpy(out->bytes + at, x->bytes, x->len);
      at += x->len;
    } else {
      rpos = 0;
      render(v);
      __builtin_memcpy(out->bytes + at, rbuf, (uw)rpos);
      at += (uw)rpos;
    }
  }
  return (V)out;
}

fpr_lock_t fpr_con_lock; /* console: one LINE at a time across harts */

/* ---- the /logs substrate: C's lines, staged -------------------------
 * The rings are FP-RISC: a log actor in core/prelude.fpr keeps each
 * severity's last lines as a List (as many as Sys.logKeep says, any width),
 * echoes FP-RISC lines to the console and answers Sys.logSeq/logSnap.
 * What stays here is for writers that cannot message an actor: a panic,
 * an actor failing, a hosted program's host threads (QOS Portable's
 * entry.c, severity 3).  fpr_logput STAGES their line, which the log
 * actor drains before every answer, and echoes it at once, so the console
 * never waits on an actor.  Severities: 0 normal, 1 warn, 2 error, 3 host. */
#define LOG_SEVS 4
/* C's lines between two drains.  Fixed, because a host thread or a panic
 * cannot allocate; a line that does not fit is COUNTED (the log actor
 * reports the count), never cut. */
#define STAGE_BYTES (32u * 1024u)
#define STAGE_HDR 5u /* severity byte + 32-bit length */
static unsigned char stage[STAGE_BYTES];
static uw stage_used, stage_dropped;
static fpr_lock_t log_lock;

/* #25: C's console echo is rate-limited BY SEQUENCE, not by time
 * (runtime.c has no clock): 16 echoes per 64 lines.  At human rates
 * everything echoes; a storm gets a bounded 25% plus one honest summary
 * line when suppression ends.  Staging is never limited by the echo.
 * (The log actor applies the same rule to FP-RISC's lines.) */
#define ECHO_WIN 64
#define ECHO_ALLOW 16
static uw echo_total, echo_win_base, echo_used, echo_suppressed;

void fpr_logput(int sev, const char *b, uw n) {
  if (sev < 0) sev = 0;
  if (sev >= LOG_SEVS) sev = LOG_SEVS - 1;
  uw do_echo, supp_note = 0;
  fpr_lock(&log_lock);
  if (n <= STAGE_BYTES - STAGE_HDR && stage_used <= STAGE_BYTES - STAGE_HDR - n) {
    unsigned char *d = stage + stage_used;
    d[0] = (unsigned char)sev;
    d[1] = (unsigned char)n; d[2] = (unsigned char)(n >> 8);
    d[3] = (unsigned char)(n >> 16); d[4] = (unsigned char)(n >> 24);
    if (n) __builtin_memcpy(d + STAGE_HDR, b, n);
    stage_used += STAGE_HDR + n;
  } else stage_dropped++;
  echo_total++;
  if (echo_total - echo_win_base >= ECHO_WIN) { echo_win_base = echo_total; echo_used = 0; }
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
  void (*out)(const char *, uw) = sev == 1 || sev == 2 ? hal_diag_bytes : hal_console_bytes;
  static const uw prefix_len[LOG_SEVS] = {6, 7, 6, 7};
  out(pre[sev], prefix_len[sev]);
  if (n) out(b, n);
  out("\n", 1);
  fpr_unlock(&fpr_con_lock);
}

/* Sys.logStage sev line: an FP-RISC line by C's path -- what `log` falls
 * back to when the log actor has ended */
static V g_logStage(V sevv, V sv) {
  if (!ISINT(sevv)) fpr_trap("Sys.logStage: severity must be an Int");
  if (ISINT(sv) || TID(sv) != T_STR) fpr_trap("Sys.logStage: not a String");
  str_t *t = (str_t *)sv;
  fpr_logput((int)UNTAG(sevv), (const char *)t->bytes, t->len);
  return (V)&fpr_unit;
}

const hdr_t fpr_list_nil = {T_LIST, 0};

static V log_tup2(V a, V b) {
  hdr_t *t = (hdr_t *)fpr_alloc(8 + 2 * sizeof(uw));
  t->tid = T_TUP2;
  t->var = 0;
  FPR_FLD(t, 0) = a;
  FPR_FLD(t, 1) = b;
  return (V)t;
}
/* Sys.logStaged () -> (dropped, [(sev, line)] newest first): take what C
 * staged since the last call.  The copy is taken BEFORE the lock is held
 * for it, and the List built after it is let go: an allocation may wait on
 * the memory actor, and a writer on this hart would spin on the lock. */
static V g_logStaged(V u) {
  (void)u;
  fpr_confined_refuse("Sys.logStaged (the system log)");
  static const struct { hdr_t hdr; V dropped, entries; } empty = {
    {T_TUP2, 0}, TAG(0), (V)&fpr_list_nil
  };
  unsigned char *buf = 0;
  uw n, dropped, cap = 0;
  for (;;) {
    uw want = __atomic_load_n(&stage_used, __ATOMIC_RELAXED);
    if (want > cap) {
      if (buf) fpr_free_raw((V)buf);
      buf = (unsigned char *)fpr_alloc_raw((V)want);
      cap = want;
    }
    fpr_lock(&log_lock);
    if (stage_used > cap) { fpr_unlock(&log_lock); continue; }
    n = stage_used;
    if (n) __builtin_memcpy(buf, stage, n);
    dropped = stage_dropped;
    stage_used = 0;
    stage_dropped = 0;
    fpr_unlock(&log_lock);
    break;
  }
  if (!n && !dropped) {
    if (buf) fpr_free_raw((V)buf);
    return (V)&empty;
  }
  V list = (V)&fpr_list_nil;
  for (uw at = 0; at < n;) { /* oldest first, consed: the head is newest */
    uw len = (uw)buf[at + 1] | (uw)buf[at + 2] << 8 | (uw)buf[at + 3] << 16 | (uw)buf[at + 4] << 24;
    V line = (V)fpr_mkstr(buf + at + STAGE_HDR, len);
    V *cell = (V *)fpr_alloc(sizeof(hdr_t) + 2 * sizeof(V));
    ((hdr_t *)cell)->tid = T_LIST;
    ((hdr_t *)cell)->var = 1;
    FPR_FLD(cell, 0) = log_tup2(TAG((sw)buf[at]), line);
    FPR_FLD(cell, 1) = list;
    list = (V)cell;
    at += STAGE_HDR + len;
  }
  if (buf) fpr_free_raw((V)buf);
  return log_tup2(TAG((sw)dropped), list);
}

/* the log actor: installed once, like the interrupt router */
static V log_actor; /* an actor value; 0 until installed */
static V g_logInstall(V av) {
  fpr_confined_refuse("Sys.logInstall (the system logger)");
  if (ISINT(av) || TID(av) != T_ACTOR) fpr_cpanic("Sys.logInstall: not an actor");
  V none = 0;
  return __atomic_compare_exchange_n(&log_actor, &none, av, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)
             ? (V)&fpr_true : (V)&fpr_false;
}
/* a confined process holds no system actor: it is shown a log actor that
 * has ended, and the prelude's `log` then takes C's way -- the line is
 * staged for the system log and echoed on the program's own console */
static V g_logger(V u) {
  (void)u;
  if (fpr_actor_confined()) return fpr_ended_actor();
  V a = __atomic_load_n(&log_actor, __ATOMIC_ACQUIRE);
  return a ? a : TAG(0);
}
FPR_FN(fpr_g_Sys_x2elogStage, g_logStage, 2);
FPR_FN(fpr_g_Sys_x2elogStaged, g_logStaged, 1);
FPR_FN(fpr_g_Sys_x2elogInstall, g_logInstall, 1);
FPR_FN(fpr_g_Sys_x2elogger, g_logger, 1);

/* Sys.memStats () -> (grows, mib): the arena growth ledger */
static V g_memstats(V u) {
  (void)u;
  V *t = (V *)fpr_alloc(sizeof(hdr_t) + 2 * sizeof(V));
  ((hdr_t *)t)->tid = T_TUP2;
  ((hdr_t *)t)->var = 0;
  FPR_FLD(t, 0) = TAG((sw)__atomic_load_n(&fpr_grow_count, __ATOMIC_RELAXED));
  FPR_FLD(t, 1) = TAG((sw)(__atomic_load_n(&fpr_grow_bytes, __ATOMIC_RELAXED) >> 20));
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
  V list = (V)&fpr_list_nil;
  V *cells[8];
  for (int i = 7; i >= 0; i--) {
    V *cell = (V *)fpr_alloc(sizeof(hdr_t) + 2 * sizeof(V));
    ((hdr_t *)cell)->tid = T_LIST;
    ((hdr_t *)cell)->var = 1;
    FPR_FLD(cell, 1) = list;
    list = (V)cell;
    cells[i] = cell;
  }
  uw vals[8] = {fpr_mem_own ? buddy_arena_size() >> 10 : 0,
                fpr_mem_own ? (buddy_free_bytes() + fpr_mem_cached_bytes()) >> 10 : 0,
                fpr_mem_reqs, fpr_mem_waits, fpr_mem_direct, fpr_mem_frees,
                fpr_mem_denied, fpr_mem_inline};
  for (int i = 0; i < 8; i++) FPR_FLD(cells[i], 0) = TAG((sw)vals[i]);
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
  V list = (V)&fpr_list_nil;
  uw newest = __atomic_load_n(&fpr_grow_count, __ATOMIC_RELAXED);
  uw have = newest < GROWLOG_N ? newest : GROWLOG_N;
  /* build oldest -> newest by consing, so the head is newest */
  for (uw s = newest - have; s < newest; s++) {
    growev_t *e = &growlog[s % GROWLOG_N];
    uw seq1 = __atomic_load_n(&e->seq, __ATOMIC_ACQUIRE);
    if (seq1 != s + 1) continue;
    growev_t c = *e;
    uw seq2 = __atomic_load_n(&e->seq, __ATOMIC_ACQUIRE);
    if (seq2 != s + 1) continue; /* torn or overwritten */
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
    V *cell = (V *)fpr_alloc(sizeof(hdr_t) + 2 * sizeof(V));
    ((hdr_t *)cell)->tid = T_LIST;
    ((hdr_t *)cell)->var = 1;
    FPR_FLD(cell, 0) = str;
    FPR_FLD(cell, 1) = list;
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
  hal_console_bytes(out, n);
  hal_putc('\n');
  fpr_unlock(&fpr_con_lock);
  return (V)&fpr_unit;
}

/* String.len -- mangled: '.' = _x2e */
V fpr_prim_fn_String_x2elen(V s) {
  str_t *t = (str_t *)s;
  if (ISINT(s) || t->tid != T_STR) fpr_trap("String.len: not a string");
  return TAG(t->len);
}

/* ! : list lookup, 0-based */
V fpr_prim_fn__x21(V xs, V iv) {
  sw i = UNTAG(iv);
  V c = xs;
  for (;;) {
    if (i < 0 || ISINT(c) || TID(c) != T_LIST || ((hdr_t *)c)->var != 1)
      fpr_trap_num("!: index out of range (", UNTAG(iv), ")");
    V *f = (V *)((char *)c + 8);
    if (i == 0) return f[0];
    c = f[1];
    i--;
  }
}

V fpr_prim_fn_strcat(V a, V b) {
  str_t *x = (str_t *)a, *y = (str_t *)b;
  if (ISINT(a) || ISINT(b) || x->tid != T_STR || y->tid != T_STR)
    fpr_trap("strcat: not strings");
  if (!x->len || !y->len) {
    str_t *piece = x->len ? x : y;
    if (!piece->len) return (V)&empty_string;
    if (piece->len == 1) return (V)&byte_strings[piece->bytes[0]];
    if (!fpr_in_heap((V)piece)) return (V)piece;
    return (V)fpr_mkstr(piece->bytes, piece->len);
  }
  if (x->len > ~(uw)0 - sizeof(str_t) ||
      y->len > ~(uw)0 - sizeof(str_t) - x->len)
    fpr_trap("strcat: size overflow");
  str_t *s = (str_t *)fpr_alloc(sizeof(str_t) + x->len + y->len);
  s->tid = T_STR;
  s->var = 0;
  s->len = x->len + y->len;
  /* memcpy, not a byte loop: s is a fresh allocation, so nothing overlaps.
   * The byte loop ran at one byte a cycle at best, and at half that when
   * the arena put source and destination at an unlucky distance (a
   * load/store aliasing stall): tests/bench/strbuild.fpr's 20,000 appends
   * took 50 ms longer depending on where a call region's slab landed
   * (docs/2026-10-26-PERFORMANCE-REGRESSIONS.md) */
  __builtin_memcpy(s->bytes, x->bytes, x->len);
  __builtin_memcpy(s->bytes + x->len, y->bytes, y->len);
  return (V)s;
}

V fpr_prim_fn_error(V s) { fpr_panic(s); }

void fpr_render_to_uart(V v) {
  rpos = 0;
  render(v);
  hal_console_bytes(rbuf, (uw)rpos);
}

/* string helpers exposed through the fpr_g_ contract (0-based) */
static V g_charAt(V s, V i) {
  str_t *t = (str_t *)s;
  if (ISINT(s) || t->tid != T_STR) fpr_trap("charAt: not a string");
  sw k = UNTAG(i);
  if (k < 0 || (uw)k >= t->len) fpr_trap_range("charAt: index out of range", k, t->len);
  return TAG(t->bytes[k]);
}
static V g_strlen(V s) {
  str_t *t = (str_t *)s;
  if (ISINT(s) || t->tid != T_STR) fpr_trap("strlen: not a string");
  return TAG(t->len);
}

/* chr : Int -> String -- the inverse of charAt. One byte. The line
 * editor and path splitter build strings incrementally with this. */
/* the Int's bounds on this word, as primitives: a 63-bit literal is refused
 * where the Int is narrower, and a module cannot name a prelude constant */
static V g_intMax(V u) { (void)u; return TAG(INT_MAX_TAGGED); }
static V g_intMin(V u) { (void)u; return TAG(INT_MIN_TAGGED); }
static V g_chr(V c) {
  if (!ISINT(c)) fpr_trap("chr: not an Int");
  /* chr makes ONE BYTE; a value outside 0..255 used to be truncated
   * silently (chr 1114112 was a replacement character) */
  if (UNTAG(c) < 0 || UNTAG(c) > 255)
    fpr_trap_num("chr: ", UNTAG(c), " is not a byte (0..255); chr makes one byte, String.fromCodes makes UTF-8");
  return (V)&byte_strings[(uw)UNTAG(c)];
}

/* ---- floats: raw bits on RV64, boxed numeric leaves on RV32 ----------
 * A float is its IEEE bit pattern carried in an ordinary V -- moved by
 * the same ld/sd/mv, slots, argspill, PAP and constructor paths as any
 * word (nothing there interprets values). Type-directed elaboration routes
 * arithmetic to these primitives; saturated F64 calls can be emitted inline
 * by Codegen with the same raw-bits boundary. Other operations and generic
 * calls keep these C implementations as their reference. The lp64
 * integer ABI is untouched: prims take and return V.
 *
 * The two runtime functions that DO interpret values dynamically
 * (render, veq) never legally see a raw float: Infer refuses str/print
 * on float-containing structures and rewrites float ==/compare to
 * these prims.  Known v1 hazard, documented not hidden: a denormal
 * whose bits alias a heap address could fool fpr_in_heap on an
 * explicit send/drop of a bare float -- the same shallow-honesty class
 * as veq's "deep equality needs field counts".  NaN-boxing or typed
 * drops are the real fix, with the Sol JTy lattice as the reference.
 * RV32 uses aligned T_BITS numeric leaves instead: F64 needs all 64 bits,
 * and boxed F32 avoids interpreting an arbitrary float bit pattern as a
 * tagged Int or pointer. The generated ordinary-V call ABI is unchanged. */
#if UINTPTR_MAX > 0xFFFFFFFFu
static double dbits(V v) { union { uw u; double d; } c; c.u = (uw)v; return c.d; }
static V bitsd(double d) { union { uw u; double d; } c; c.d = d; return (V)c.u; }
static float fbits(V v) { union { uint32_t u; float f; } c; c.u = (uint32_t)(uw)v; return c.f; }
static V bitsf(float f) { union { uint32_t u; float f; } c; c.f = f; return (V)(uw)c.u; }
#else
static double dbits(V v) {
  if (ISINT(v) || !v || TID(v) != T_BITS || ((hdr_t *)v)->var != 5)
    fpr_cpanic("F64: invalid boxed value");
  union { uint64_t u; double d; } c = {((fpr_num64_t *)v)->val};
  return c.d;
}
static V bitsd(double d) {
  union { uint64_t u; double d; } c; c.d = d;
  fpr_num64_t *b = (fpr_num64_t *)fpr_alloc(sizeof(fpr_num64_t));
  *b = (fpr_num64_t){T_BITS, 5, 64, c.u};
  return (V)b;
}
static float fbits(V v) {
  if (ISINT(v) || !v || TID(v) != T_BITS || ((hdr_t *)v)->var != 6)
    fpr_cpanic("F32: invalid boxed value");
  union { uint32_t u; float f; } c = {(uint32_t)((bits_t *)v)->val};
  return c.f;
}
static V bitsf(float f) {
  union { uint32_t u; float f; } c; c.f = f;
  bits_t *b = (bits_t *)fpr_alloc(sizeof(bits_t));
  *b = (bits_t){T_BITS, 6, 32, c.u};
  return (V)b;
}
#endif

/* The compiler splices literal bits with the C integer ABI, before tagging.
 * A tagged RV32 Int cannot carry an arbitrary unsigned 32-bit half. */
V fpr_f64_from_bits32(uint32_t hi, uint32_t lo) {
  union { uint64_t u; double d; } c = {((uint64_t)hi << 32) | lo};
  return bitsd(c.d);
}
V fpr_f32_from_bits32(uint32_t bits) {
  union { uint32_t u; float f; } c = {bits};
  return bitsf(c.f);
}

/* literal splicing: the parser encodes 1.5 as f64frombits hi lo (two
 * tagged 32-bit halves -- a tagged V cannot carry 64 raw bits) */
V fpr_prim_fn_f64frombits(V hi, V lo) {
  return fpr_f64_from_bits32((uint32_t)UNTAG(hi), (uint32_t)UNTAG(lo));
}

/* F32 literals fit one tagged Int (32 bits < 62), so one arg */
V fpr_prim_fn_f32frombits(V b) { return fpr_f32_from_bits32((uint32_t)UNTAG(b)); }

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
#if defined(__riscv) && defined(__riscv_flen) && __riscv_flen >= 64
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
static V float_toInt(double d) {
  /* Check the full signed machine range before C's float-to-int cast,
   * then check the truncated integer's tagged range. On RV32, a value
   * such as -1073741824.5 truncates to the valid minimum Int. Checking
   * the original double against that minimum rejected it too early. */
  double machine_limit = (double)((uw)1 << (sizeof(uw) * 8 - 1));
  if (!(d >= -machine_limit && d < machine_limit))
    fpr_trap("float.toInt: does not fit an Int");
  sw n = (sw)d;
  if (!fits_int(n)) fpr_trap("float.toInt: does not fit an Int");
  return TAG(n); /* truncates toward zero */
}
V fpr_prim_fn_F64_x2etoInt(V a) { return float_toInt(dbits(a)); }
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
V fpr_prim_fn_F32_x2etoInt(V a) { return float_toInt((double)fbits(a)); }
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
  /* Display precision belongs to F64, not the target's pointer width.
   * RV32 still prints the full integer part up to the exponent cutoff. */
  uint64_t ip = (uint64_t)x;
  double fr = x - (double)ip;
  { /* integer part */
    char b[24]; int i = 23; uint64_t u = ip; int digs = 0;
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

/* ---- I64: a 64-bit two's-complement integer, BOXED ---------------------
 * Int is tagged and has XLEN-1 bits. I64 is the whole 64-bit word, for code
 * that needs exact 64-bit arithmetic (wasm i64, C interop, hashes, wire
 * formats).  It WRAPS on overflow, like C's uint64_t and wasm's i64; that
 * is its contract, not an accident, and why it is a separate type from Int.
 * Shift and rotate counts are taken modulo 64.  Division by zero and
 * INT64_MIN / -1 panic, as Int's / does.
 *
 * Boxed, not a raw word as F64 is: a raw word whose bits look like a heap
 * address is followed as a pointer by the copier on send (a value near
 * 2^40 hung a program on this Mac), and integers -- timestamps in
 * milliseconds are about 2^40 -- land there far more often than floats.
 * The box is a fpr_num64_t of variant 4 (fpr.h), which every walker already
 * treats as a leaf: send, drop, keep and arena copy-out copy it by size,
 * veq compares its value, and render prints it as a signed decimal.  So
 * an I64 can sit in lists, records, vectors and polymorphic code.  The
 * price is one 24-byte cell per result (docs/2026-10-05-I64.md). */
static uint64_t u64(V v) { return ((fpr_num64_t *)v)->val; }
static int64_t i64(V v) { return (int64_t)u64(v); }
static V vu64(uint64_t x) {
  fpr_num64_t *b = (fpr_num64_t *)fpr_alloc(sizeof(fpr_num64_t));
  *b = (fpr_num64_t){T_BITS, 4, 64, x};
  return (V)b;
}
static V vi64(int64_t x) { return vu64((uint64_t)x); }
static unsigned cnt64(V k) { return (unsigned)((uint64_t)UNTAG(k) & 63u); }

static V result_of(unsigned var, V payload) {
  V *r = (V *)fpr_alloc(8 + sizeof(uw));
  ((hdr_t *)r)->tid = T_RESULT;
  ((hdr_t *)r)->var = var;
  FPR_FLD(r, 0) = payload;
  return (V)r;
}
static V ok_v(V payload) { return result_of(0, payload); }
/* The length of a C string without the builtin: on the freestanding
 * targets gcc lowers a non-constant __builtin_strlen to a call to libc's
 * strlen, which the virt and native links do not have. */
static uw cstr_len(const char *s) { uw n = 0; while (s[n]) n++; return n; }
static V err_c(const char *msg) { return result_of(1, (V)fpr_mkstr((const uint8_t *)msg, cstr_len(msg))); }

static V i64_add(V a, V b) { return vu64(u64(a) + u64(b)); }
static V i64_sub(V a, V b) { return vu64(u64(a) - u64(b)); }
static V i64_mul(V a, V b) { return vu64(u64(a) * u64(b)); }
static V i64_div(V a, V b) {
  if (i64(b) == 0) fpr_trap("I64: division by zero");
  if (i64(a) == INT64_MIN && i64(b) == -1) fpr_trap("I64: division overflow (INT64_MIN / -1)");
  return vi64(i64(a) / i64(b));
}
/* the C remainder: its sign is the dividend's; INT64_MIN rem -1 is 0 */
static V i64_rem(V a, V b) {
  if (i64(b) == 0) fpr_trap("I64: division by zero");
  if (i64(b) == -1) return vi64(0);
  return vi64(i64(a) % i64(b));
}
static V i64_divU(V a, V b) {
  if (u64(b) == 0) fpr_trap("I64: division by zero");
  return vu64(u64(a) / u64(b));
}
static V i64_remU(V a, V b) {
  if (u64(b) == 0) fpr_trap("I64: division by zero");
  return vu64(u64(a) % u64(b));
}
static V i64_lt(V a, V b) { return BOOL(i64(a) < i64(b)); }
static V i64_gt(V a, V b) { return BOOL(i64(a) > i64(b)); }
static V i64_le(V a, V b) { return BOOL(i64(a) <= i64(b)); }
static V i64_ge(V a, V b) { return BOOL(i64(a) >= i64(b)); }
static V i64_eq(V a, V b) { return BOOL(u64(a) == u64(b)); }
static V i64_ne(V a, V b) { return BOOL(u64(a) != u64(b)); }
static V i64_ltU(V a, V b) { return BOOL(u64(a) < u64(b)); }
static V i64_gtU(V a, V b) { return BOOL(u64(a) > u64(b)); }
static V i64_leU(V a, V b) { return BOOL(u64(a) <= u64(b)); }
static V i64_geU(V a, V b) { return BOOL(u64(a) >= u64(b)); }
static V i64_and(V a, V b) { return vu64(u64(a) & u64(b)); }
static V i64_or(V a, V b) { return vu64(u64(a) | u64(b)); }
static V i64_xor(V a, V b) { return vu64(u64(a) ^ u64(b)); }
static V i64_not(V a) { return vu64(~u64(a)); }
static V i64_neg(V a) { return vu64(0u - u64(a)); }
static V i64_shl(V a, V k) { return vu64(u64(a) << cnt64(k)); }
static V i64_shr(V a, V k) { return vu64(u64(a) >> cnt64(k)); }
static V i64_sar(V a, V k) { return vi64(i64(a) >> cnt64(k)); } /* arithmetic on every target we build */
static V i64_rotl(V a, V k) { unsigned n = cnt64(k); return n ? vu64((u64(a) << n) | (u64(a) >> (64 - n))) : vu64(u64(a)); }
static V i64_rotr(V a, V k) { unsigned n = cnt64(k); return n ? vu64((u64(a) >> n) | (u64(a) << (64 - n))) : vu64(u64(a)); }
/* Bit counts written out: without the Zbb extension gcc turns the clz,
 * ctz and popcount builtins into libgcc calls (__clzdi2, ...), and the
 * virt and native links are -nostdlib with no -lgcc.  A zero argument
 * answers 64 for clz and ctz. */
static unsigned clz64(uint64_t x) {
  unsigned n = 0;
  if (!x) return 64;
  if (!(x & 0xFFFFFFFF00000000ull)) { n += 32; x <<= 32; }
  if (!(x & 0xFFFF000000000000ull)) { n += 16; x <<= 16; }
  if (!(x & 0xFF00000000000000ull)) { n += 8;  x <<= 8; }
  if (!(x & 0xF000000000000000ull)) { n += 4;  x <<= 4; }
  if (!(x & 0xC000000000000000ull)) { n += 2;  x <<= 2; }
  if (!(x & 0x8000000000000000ull)) { n += 1; }
  return n;
}
static unsigned ctz64(uint64_t x) {
  unsigned n = 0;
  if (!x) return 64;
  if (!(x & 0x00000000FFFFFFFFull)) { n += 32; x >>= 32; }
  if (!(x & 0x000000000000FFFFull)) { n += 16; x >>= 16; }
  if (!(x & 0x00000000000000FFull)) { n += 8;  x >>= 8; }
  if (!(x & 0x000000000000000Full)) { n += 4;  x >>= 4; }
  if (!(x & 0x0000000000000003ull)) { n += 2;  x >>= 2; }
  if (!(x & 0x0000000000000001ull)) { n += 1; }
  return n;
}
static unsigned popcnt64(uint64_t x) {
  x = x - ((x >> 1) & 0x5555555555555555ull);
  x = (x & 0x3333333333333333ull) + ((x >> 2) & 0x3333333333333333ull);
  x = (x + (x >> 4)) & 0x0F0F0F0F0F0F0F0Full;
  return (unsigned)((x * 0x0101010101010101ull) >> 56);
}
static V i64_clz(V a) { return TAG(clz64(u64(a))); }
static V i64_ctz(V a) { return TAG(ctz64(u64(a))); }
static V i64_popcnt(V a) { return TAG(popcnt64(u64(a))); }

/* conversions with Int: every Int fits; the reverse is checked */
static V i64_ofInt(V a) { return vi64((int64_t)UNTAG(a)); }
static V i64_toInt(V a) {
  int64_t x = i64(a);
  if (x > INT_MAX_TAGGED || x < INT_MIN_TAGGED)
#if UINTPTR_MAX > 0xFFFFFFFFu
    return err_c("I64.toInt: does not fit an Int (63 bits)");
#else
    return err_c("I64.toInt: does not fit an Int (31 bits)");
#endif
  return ok_v(TAG((sw)x));
}
/* the halves as unsigned 32-bit Ints, and back (each half masked to 32 bits) */
static V i64_half(uint32_t x) {
#if UINTPTR_MAX <= 0xFFFFFFFFu
  if ((uint64_t)x > (uint64_t)INT_MAX_TAGGED)
    fpr_trap("I64.hi/lo: unsigned half does not fit an Int; use hiWord/loWord");
#endif
  return TAG((sw)x);
}
static V i64_hi(V a) { return i64_half((uint32_t)(u64(a) >> 32)); }
static V i64_lo(V a) { return i64_half((uint32_t)u64(a)); }
static V i64_fromParts(V hi, V lo) {
  return vu64(((uint64_t)UNTAG(hi) & 0xFFFFFFFFu) << 32 | ((uint64_t)UNTAG(lo) & 0xFFFFFFFFu));
}
static V i64_halfWord(uint32_t x) {
#ifdef FPR_BUILTIN_RAW
  return (V)x;
#else
  bits_t *b = (bits_t *)fpr_alloc(sizeof(bits_t));
  *b = (bits_t){T_BITS, 2, sizeof(uw) * 8, (uw)x};
  return (V)b;
#endif
}
static V i64_hiWord(V a) { return i64_halfWord((uint32_t)(u64(a) >> 32)); }
static V i64_loWord(V a) { return i64_halfWord((uint32_t)u64(a)); }
static uw i64_wordBits(V v) {
#ifdef FPR_BUILTIN_RAW
  return (uw)v;
#else
  if (ISINT(v) || !v || TID(v) != T_BITS || ((hdr_t *)v)->var != 2)
    fpr_cpanic("I64.fromWords: not a Word");
  return ((bits_t *)v)->val;
#endif
}
static V i64_fromWords(V hi, V lo) {
  return vu64(((uint64_t)(uint32_t)i64_wordBits(hi) << 32) | (uint32_t)i64_wordBits(lo));
}

/* floats: to a double rounds to nearest; from one truncates toward zero
 * and refuses NaN and values outside the range */
static V i64_toF64(V a) { return bitsd((double)i64(a)); }
static V i64_toF64U(V a) { return bitsd((double)u64(a)); }
static V i64_ofF64(V a) {
  double d = dbits(a);
  if (d != d) return err_c("I64.ofF64: NaN");
  if (!(d >= -9223372036854775808.0 && d < 9223372036854775808.0)) return err_c("I64.ofF64: out of range");
  return ok_v(vi64((int64_t)d));
}
static V i64_ofF64U(V a) {
  double d = dbits(a);
  if (d != d) return err_c("I64.ofF64U: NaN");
  if (!(d > -1.0 && d < 18446744073709551616.0)) return err_c("I64.ofF64U: out of range");
  return ok_v(vu64((uint64_t)d));
}
/* the IEEE bits of a double, and back: what reinterpret means in wasm */
static V i64_ofF64Bits(V a) {
  union { uint64_t u; double d; } c; c.d = dbits(a);
  return vu64(c.u);
}
static V i64_toF64Bits(V a) {
  uint64_t u = u64(a);
  return fpr_f64_from_bits32((uint32_t)(u >> 32), (uint32_t)u);
}

/* text */
static V i64_digits(uint64_t m, int neg) {
  char buf[24]; int i = 24;
  do { buf[--i] = (char)('0' + m % 10u); m /= 10u; } while (m);
  if (neg) buf[--i] = '-';
  return (V)fpr_mkstr((const uint8_t *)buf + i, (uw)(24 - i));
}
static V i64_str(V a) { int64_t x = i64(a); return x < 0 ? i64_digits(0u - (uint64_t)x, 1) : i64_digits((uint64_t)x, 0); }
static V i64_strU(V a) { return i64_digits(u64(a), 0); }
static V i64_hex(V a) {
  char buf[16]; int i = 16; uint64_t m = u64(a);
  do { buf[--i] = "0123456789abcdef"[m & 15u]; m >>= 4; } while (m);
  return (V)fpr_mkstr((const uint8_t *)buf + i, (uw)(16 - i));
}
/* [+-]digits, or [+-]0x hex digits; `_` between digits.  A magnitude past
 * 2^64 is refused; one past the signed range wraps, as a wasm i64 literal
 * does (0xffff_ffff_ffff_ffff is -1). */
static V i64_parse(V s) {
  str_t *t = want_str(s, "I64.parse: not a String");
  uw i = 0, n = t->len, seen = 0;
  int neg = 0; unsigned base = 10; uint64_t m = 0;
  if (i < n && (t->bytes[i] == '-' || t->bytes[i] == '+')) neg = t->bytes[i++] == '-';
  if (i + 1 < n && t->bytes[i] == '0' && t->bytes[i + 1] == 'x') { base = 16; i += 2; }
  for (; i < n; i++) {
    unsigned c = t->bytes[i], d;
    if (c == '_') continue;
    if (c >= '0' && c <= '9') d = c - '0';
    else if (base == 16 && c >= 'a' && c <= 'f') d = c - 'a' + 10;
    else if (base == 16 && c >= 'A' && c <= 'F') d = c - 'A' + 10;
    else return err_c("I64.parse: not a number");
    if (d >= base) return err_c("I64.parse: not a number");
    if (m > (UINT64_MAX - d) / base) return err_c("I64.parse: more than 64 bits");
    m = m * base + d; seen++;
  }
  if (!seen) return err_c("I64.parse: no digits");
  return ok_v(vu64(neg ? 0u - m : m));
}

FPR_FN(fpr_g_I64_x2e_x2b, i64_add, 2);
FPR_FN(fpr_g_I64_x2e_x2d, i64_sub, 2);
FPR_FN(fpr_g_I64_x2e_x2a, i64_mul, 2);
FPR_FN(fpr_g_I64_x2e_x2f, i64_div, 2);
FPR_FN(fpr_g_I64_x2erem, i64_rem, 2);
FPR_FN(fpr_g_I64_x2edivU, i64_divU, 2);
FPR_FN(fpr_g_I64_x2eremU, i64_remU, 2);
FPR_FN(fpr_g_I64_x2e_x3c, i64_lt, 2);
FPR_FN(fpr_g_I64_x2e_x3e, i64_gt, 2);
FPR_FN(fpr_g_I64_x2e_x3c_x3d, i64_le, 2);
FPR_FN(fpr_g_I64_x2e_x3e_x3d, i64_ge, 2);
FPR_FN(fpr_g_I64_x2e_x3d_x3d, i64_eq, 2);
FPR_FN(fpr_g_I64_x2e_x21_x3d, i64_ne, 2);
FPR_FN(fpr_g_I64_x2eltU, i64_ltU, 2);
FPR_FN(fpr_g_I64_x2egtU, i64_gtU, 2);
FPR_FN(fpr_g_I64_x2eleU, i64_leU, 2);
FPR_FN(fpr_g_I64_x2egeU, i64_geU, 2);
FPR_FN(fpr_g_I64_x2eand, i64_and, 2);
FPR_FN(fpr_g_I64_x2eor, i64_or, 2);
FPR_FN(fpr_g_I64_x2exor, i64_xor, 2);
FPR_FN(fpr_g_I64_x2enot, i64_not, 1);
FPR_FN(fpr_g_I64_x2eneg, i64_neg, 1);
FPR_FN(fpr_g_I64_x2eshl, i64_shl, 2);
FPR_FN(fpr_g_I64_x2eshr, i64_shr, 2);
FPR_FN(fpr_g_I64_x2esar, i64_sar, 2);
FPR_FN(fpr_g_I64_x2erotl, i64_rotl, 2);
FPR_FN(fpr_g_I64_x2erotr, i64_rotr, 2);
FPR_FN(fpr_g_I64_x2eclz, i64_clz, 1);
FPR_FN(fpr_g_I64_x2ectz, i64_ctz, 1);
FPR_FN(fpr_g_I64_x2epopcnt, i64_popcnt, 1);
FPR_FN(fpr_g_I64_x2eofInt, i64_ofInt, 1);
FPR_FN(fpr_g_I64_x2etoInt, i64_toInt, 1);
FPR_FN(fpr_g_I64_x2ehi, i64_hi, 1);
FPR_FN(fpr_g_I64_x2elo, i64_lo, 1);
FPR_FN(fpr_g_I64_x2efromParts, i64_fromParts, 2);
FPR_FN(fpr_g_I64_x2ehiWord, i64_hiWord, 1);
FPR_FN(fpr_g_I64_x2eloWord, i64_loWord, 1);
FPR_FN(fpr_g_I64_x2efromWords, i64_fromWords, 2);
FPR_FN(fpr_g_I64_x2etoF64, i64_toF64, 1);
FPR_FN(fpr_g_I64_x2etoF64U, i64_toF64U, 1);
FPR_FN(fpr_g_I64_x2eofF64, i64_ofF64, 1);
FPR_FN(fpr_g_I64_x2eofF64U, i64_ofF64U, 1);
FPR_FN(fpr_g_I64_x2eofF64Bits, i64_ofF64Bits, 1);
FPR_FN(fpr_g_I64_x2etoF64Bits, i64_toF64Bits, 1);
FPR_FN(fpr_g_I64_x2estr, i64_str, 1);
FPR_FN(fpr_g_I64_x2estrU, i64_strU, 1);
FPR_FN(fpr_g_I64_x2ehex, i64_hex, 1);
FPR_FN(fpr_g_I64_x2eparse, i64_parse, 1);

/* I32 bridges belong to Base's wide numeric runtime. The integer-only
 * implementation lives in i32.c and also links into manual Builtin. */
static V i32_ofI64(V a) { return fpr_i32_pack((uint32_t)u64(a)); }
static V i32_toI64(V a) { return vi64((int32_t)fpr_i32_bits(a)); }
static V i32_toI64U(V a) { return vu64(fpr_i32_bits(a)); }
static V i32_toF64(V a) { return bitsd((double)(int32_t)fpr_i32_bits(a)); }
static V i32_toF64U(V a) { return bitsd((double)fpr_i32_bits(a)); }
static V i32_toF32(V a) { return bitsf((float)(int32_t)fpr_i32_bits(a)); }
static V i32_toF32U(V a) { return bitsf((float)fpr_i32_bits(a)); }
static V i32_ofFloat(double d,int unsign,const char *nan,const char *range) {
  if (d!=d) return err_c(nan);
  /* Bounds apply to the integer after truncation toward zero. Both
   * endpoint+fraction cases have defined int64_t casts and preserve wasm
   * truncation semantics: -0.5 -> 0 unsigned, -2147483648.5 -> INT32_MIN. */
  if (unsign ? !(d>-1.0 && d<4294967296.0)
             : !(d>-2147483649.0 && d<2147483648.0)) return err_c(range);
  return ok_v(fpr_i32_pack((uint32_t)(int64_t)d));
}
static V i32_ofF64(V a) {
  return i32_ofFloat(dbits(a),0,"I32.ofF64: NaN","I32.ofF64: out of range");
}
static V i32_ofF64U(V a) {
  return i32_ofFloat(dbits(a),1,"I32.ofF64U: NaN","I32.ofF64U: out of range");
}
static V i32_ofF32(V a) {
  return i32_ofFloat((double)fbits(a),0,"I32.ofF32: NaN","I32.ofF32: out of range");
}
static V i32_ofF32U(V a) {
  return i32_ofFloat((double)fbits(a),1,"I32.ofF32U: NaN","I32.ofF32U: out of range");
}
static V i32_ofF32Bits(V a) {
  union { float f;uint32_t u; } c;c.f=fbits(a);
  return fpr_i32_pack(c.u);
}
static V i32_toF32Bits(V a) { return fpr_f32_from_bits32(fpr_i32_bits(a)); }
FPR_FN(fpr_g_I32_x2eofI64,i32_ofI64,1);
FPR_FN(fpr_g_I32_x2etoI64,i32_toI64,1); FPR_FN(fpr_g_I32_x2etoI64U,i32_toI64U,1);
FPR_FN(fpr_g_I32_x2etoF64,i32_toF64,1); FPR_FN(fpr_g_I32_x2etoF64U,i32_toF64U,1);
FPR_FN(fpr_g_I32_x2etoF32,i32_toF32,1); FPR_FN(fpr_g_I32_x2etoF32U,i32_toF32U,1);
FPR_FN(fpr_g_I32_x2eofF64,i32_ofF64,1); FPR_FN(fpr_g_I32_x2eofF64U,i32_ofF64U,1);
FPR_FN(fpr_g_I32_x2eofF32,i32_ofF32,1); FPR_FN(fpr_g_I32_x2eofF32U,i32_ofF32U,1);
FPR_FN(fpr_g_I32_x2eofF32Bits,i32_ofF32Bits,1); FPR_FN(fpr_g_I32_x2etoF32Bits,i32_toF32Bits,1);

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
FPR_FN(fpr_g_intMax, g_intMax, 1);
FPR_FN(fpr_g_intMin, g_intMin, 1);
FPR_FN(fpr_g_substr, g_substr, 3);
FPR_FN(fpr_g_strJoin, g_strJoin, 2);
FPR_FN(fpr_g_strCompare, g_strCompare, 2);
FPR_FN(fpr_g__x24fnIs, g_fn_is, 2);
FPR_FN(fpr_g_sortListWith, g_sortListWith, 2);
FPR_FN(fpr_g_drop, g_drop, 1);
FPR_FN(fpr_g_arcLive, g_arcLive, 1);
FPR_FN(fpr_g_heapUsed, g_heapUsed, 1);

