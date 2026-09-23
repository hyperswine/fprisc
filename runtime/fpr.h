/* fpr.h — the value representation contract.
 *
 * Everything is a machine-word V (64-bit on rv64, 32-bit on rv32):
 *   integers: (n << 1) | 1     (XLEN-1 bit, tag in bit 0)
 *   else: 8-aligned pointer to [ u32 typeid | u32 variant | word fields... ]
 *
 * The generated assembly hard-codes exactly this layout (header loads at
 * 0/4, fields at 8 + W*i where W = XLEN/8), so this header and Codegen.hs
 * must move together.  `uw` is the word type: every field the generated
 * code touches is a `uw`, never a fixed-width 64-bit type.
 */
#ifndef FPR_H
#define FPR_H

#include <stddef.h>
#include <stdint.h>

typedef uintptr_t V;
typedef uintptr_t uw; /* one machine word: field / length / count type */
typedef intptr_t sw;

enum {
  T_UNIT = 0, T_BOOL = 1, T_LIST = 2, T_RESULT = 3,
  T_TUP2 = 4, T_TUP3 = 5, T_ATOM = 6,
  /* wide tuples (Codegen builtinCons): 10..14 = Tup4..Tup8 */
  T_TUP4 = 10, T_TUP5 = 11, T_TUP6 = 12, T_TUP7 = 13, T_TUP8 = 14,
  /* a tuple wider than 8 is T_TUPN + its arity (FPRISC.hs tupWideBase): a range
   * of its own between the record shapes and the unit types */
  T_TUPN = 0x10000000, T_TUPN_END = 0x10000000 + (1 << 24),
  /* runtime-internal typeids, far above user types (10+) and shapes (100+) */
  T_STR = 9000, T_PAP = 9001, T_DEVICE = 9002, T_REGISTER = 9003, T_BITS = 9004,
  T_ACTOR = 9005, T_VEC = 9006, T_SSTR = 9007,
};

typedef struct { uint32_t tid, var; } __attribute__((aligned(8))) hdr_t;
typedef struct { uint32_t tid, var; uw fn, arity, nargs, args[]; } __attribute__((aligned(8))) pap_t;
typedef struct { uint32_t tid, var; uw fn, arity, nargs; } __attribute__((aligned(8))) pap0_t;
typedef struct { uint32_t tid, var; uw len; uint8_t bytes[]; } __attribute__((aligned(8))) str_t;
typedef struct { uint32_t tid, var; uw base; } __attribute__((aligned(8))) fpr_dev_t;
typedef struct { uint32_t tid, var /* = width in bytes */; uw addr; } __attribute__((aligned(8))) reg_t;
typedef struct { uint32_t tid, var /* 0 LE, 1 BE; Builtin: 2 Word, 3 Addr */; uw len, val; } __attribute__((aligned(8))) bits_t;

#define TAG(n) ((V)((((uw)(n)) << 1) | 1))
#define UNTAG(v) (((sw)(v)) >> 1)
#define ISINT(v) ((v) & 1)
#define TID(v) (((hdr_t *)(v))->tid)
#define BOOL(b) ((b) ? (V)&fpr_true : (V)&fpr_false)

extern const hdr_t fpr_true, fpr_false, fpr_unit;

/* ---- SMP: the per-hart control block ---------------------------------
 * Every hart's tp register points at its fpr_hart_t FOR THE LIFE OF THE
 * HART (set in boot code, saved/restored verbatim by fpr_ctx_switch --
 * actors never migrate, so an actor's saved tp is always its owner
 * hart's block).  The FIRST field is the fuel counter: generated code
 * decrements 0(tp) at every function entry.  That is the whole
 * codegen<->SMP contract: one register, one offset.
 *
 * The heap is split into per-hart arenas at boot; allocation and the
 * segregated free lists are hart-local and therefore LOCK-FREE.  A
 * block allocated on hart A and freed on hart B simply migrates to B's
 * free list -- the memory is shared and the bump pointers never revisit
 * carved space, so no double-allocation is possible.
 */
#ifndef FPR_NHARTS
#define FPR_NHARTS 2
#endif
#define FPR_NBUCKETS 512
/* argument-spill cells per hart: max supported call arity is
 * 8 (registers) + FPR_ARGSPILL (cells) = 64.  Codegen.hs and callf()
 * both bake this number; change all three together. */
#define FPR_ARGSPILL 56 /* arity ceiling 8+56 = 64.  Cells are cheap
                          * (W bytes x cells x harts); the hard limit is
                          * the rv64 12-bit tp-relative immediate
                          * (~250 cells).  Codegen.hs spillCells and
                          * callf() move with this. */
#define FPR_RBUF_SZ 4096

struct fpr_acb; /* actors.c */

/* ---- per-actor slab pools (the slab refactor) -----------------------
 * Buddy is the ONE lower allocator (init'd over heap+proc regions at
 * boot).  Every actor owns a chain of slabs cut from buddy; fpr_alloc
 * bumps the current slab, actor death returns the chain.  A slab that
 * holds PROMOTED objects (escaped > 0, maintained under the ARC lock)
 * is ORPHANED on death instead of freed (owner = NULL) and returns to
 * buddy when its last promoted object is dropped -- cross-actor
 * references can never dangle.  Stacks are buddy blocks too and never
 * escape, so death always reclaims them: the v2 "stacks leak on death"
 * caveat is structurally gone.  Block header (16 bytes, alignment
 * preserved): [0] = total size, [1] = owning slab. */
typedef struct fpr_slab {
  struct fpr_slab *next;
  struct fpr_pool *owner; /* NULL = orphaned (freed when escaped hits 0) */
  uw escaped;             /* promoted objects resident here (ARC lock) */
  uw holds;               /* an ownerless slab's other keepers (ARC lock):
                           * the sender still packing messages into it,
                           * and every dropper whose borrow window is
                           * still open.  Released when escaped and
                           * holds are both 0 -- see fpr_msg_copy. */
  char *hp, *end;
} fpr_slab_t;

typedef struct fpr_pool {
  fpr_slab_t *cur;  /* bump target; also the chain head */
  void **buckets;   /* FPR_NBUCKETS recycled-block heads, OUT-OF-LINE
                     * (CAS push any hart, owner drains).  Out-of-line
                     * so the array is reclaimed at actor death -- with
                     * it inline, every dead acb kept 4 KiB forever.
                     * Reuse is type-stable under arc_lock; a dead
                     * pool is unreachable by fpr_free (teardown
                     * orphans escaped slabs first).  runtime.c owns
                     * the recycler (bkt_take/bkt_put). */
  uw allocated;     /* gauge: bytes ever bumped by this owner */
  void *bigfree;    /* freed blocks ABOVE the bucket ceiling: an
                     * exact-fit LIFO (CAS push any hart, owner
                     * swaps out on alloc).  Headers stay intact --
                     * [0] total, [1] slab -- link rides the first
                     * payload word.  Cleared at teardown/reset:
                     * the blocks die with their slabs. */
} fpr_pool_t;

/* THE pool constructor.  fpr_pool_t is created in five places (hart
 * init, actor 0, spawn, process entry, Sys.arena); a stack-built pool
 * that hand-initializes fields WILL eventually miss one (Sys.arena
 * shipped with bigfree uninitialized -- a wild-pointer walk on any
 * above-ceiling alloc inside an arena).  Every creation site goes
 * through here; buckets must be zeroed by the caller's source
 * (fpr_bkt_take and the static boot arrays both are). */
static inline void fpr_pool_init(fpr_pool_t *p, void **buckets) {
  p->cur = 0;
  p->buckets = buckets;
  p->allocated = 0;
  p->bigfree = 0;
}
void **fpr_bkt_take(void);   /* runtime.c: bucket-array recycler */
void fpr_bkt_put(void **b);

/* ---- the SHARED SCHEDULER PLANE (transparent ACBs) -----------------
 * The unification: everything that runs is an ACB with a pid on ONE
 * set of per-hart queues -- System.qa's actors are pid 0, a loaded
 * process's actors are pid N, and the same donation/steal machinery
 * moves all of them.  A separately-compiled process image reaches the
 * ONE scheduler by routing its STRUCTURAL operations (send, receive,
 * spawn, arc, slab grow/release, the fuel trap) through this table of
 * the kernel's own functions; pool-local hot paths (bucket take, slab
 * bump, fpr_free) need no routing because the slab refactor made them
 * acb-carried.  fpr_sched is NULL on every normal boot (kernel, qosp,
 * bare-metal: zero behavior change); the loader hands a process its
 * table at entry. */
typedef struct fpr_sched {
  V (*send_as)(uw sender_key, V target, V m);
  V (*receive)(V me);
  V (*receive_from)(V me, V from);
  V (*receive_res)(V me);
  V (*spawn)(V f);                    /* pid inherits from the spawner */
  V (*spawn_at)(V hart, V f);
  V (*spawn_pid)(V f, uw pid);        /* the process root: explicit pid */
  void (*arc_incref)(V v);
  void (*arc_decref)(V v);
  fpr_slab_t *(*slab_new)(uw want);   /* pool growth: the shared buddy */
  void (*slab_release)(fpr_slab_t *sl);
  void (*pool_reset)(void);
  void (*fuel)(void);                 /* fpr_fuel_exhausted, kernel copy */
  uw (*arc_live)(void);
  char *heap_lo, *heap_hi;            /* fpr_in_heap bounds, shared span */
  uw (*stack_grow)(uw sp);            /* the plane owns the actors, so their stacks */
  V (*receive_now)(V me);             /* receive without waiting (actors.c) */
} fpr_sched_t;
extern fpr_sched_t *fpr_sched;        /* NULL = this image is the plane */
void fpr_sched_export(fpr_sched_t *out); /* fill with THIS image's impls */
/* the IMAGE-STATICS window carved out of the heap span: a loaded
 * process's code/rodata/data sit INSIDE the buddy span (the fixed
 * slot), but its cells are statics -- no 16-byte alloc preheader, so
 * the deep-copier and ARC must treat them like any other immortal
 * static.  Set by the kernel at load (slot..image_end) and by the
 * process image itself at shared boot (its own link symbols); empty
 * (0,0) everywhere else. */
extern char *fpr_static_lo, *fpr_static_hi;
fpr_slab_t *fpr_slab_new(uw want);   /* runtime.c: buddy-backed pool slab */
void fpr_pool_reset_c(void);         /* runtime.c: Sys.poolReset, C-callable */
uw fpr_arc_live_count(void);         /* runtime.c: the arc gauge */
int fpr_arc_movable_root(V v);       /* runtime.c: sendLinear's transfer test */
void fpr_arc_promote_share(V v);     /* runtime.c: sendArc's promotion */
V fpr_receive_res_c(V me);           /* actors.c: receiveRes, C-callable */
void fpr_fuel_exhausted(void);       /* actors.c: the fuel trap */

/* deferred message-slab release (the drop-what-you-receive law's
 * runtime half): dropping a received root parks its ownerless slab on
 * the DROPPING actor's pending list instead of freeing it mid-borrow;
 * the next receive -- the boundary where copy-on-retain says every
 * borrow is dead -- returns the batch.  actors.c owns the list;
 * runtime.c owns the actual release. */
void fpr_drop_park(fpr_slab_t *sl);      /* actors.c (arc_lock held) */
void fpr_drop_drain_current(void);       /* actors.c: drain now */
void fpr_slab_release(fpr_slab_t *sl);   /* runtime.c: grant/buddy */
void fpr_vec_release(V v);               /* vec.c: universal vector free */

fpr_pool_t *fpr_acb_pool(struct fpr_acb *a); /* actors.c: &a->pool */
void fpr_pool_reclaim(struct fpr_acb *a);    /* runtime.c: death teardown */
void *buddy_alloc(uw bytes);                 /* buddy.c */
void *buddy_realloc(void *p, uw bytes);      /* grow/shrink; in-place when
                                              * the buddy structure allows
                                              * (see buddy.c), else
                                              * alloc+copy+free.  NULL on
                                              * exhaustion, original intact. */
void buddy_free(void *p);
uw buddy_block_usable_size(void *p);
uw buddy_free_bytes(void);
void *buddy_alloc_try(uw bytes, int *busy); /* inline when the lock is free */
int buddy_free_try(void *p);                /* 1 done, 0 the lock was held */
void *buddy_reserve_range(void *addr, uw bytes);
void buddy_release_range(void *addr, uw bytes);
void buddy_init(void *base, uw size);

typedef struct {
  sw fuel; /* MUST stay at offset 0: generated code does ld/sd 0(tp) */
  /* ARGUMENT SPILL CELLS: the memory lane for call arguments past the
   * eight the IR carries in a0..a7.  Caller stores arg i (i >= 8) to
   * W*(1+i-8)(tp) right before transfer; callee's prologue copies the
   * cells into frame slots BEFORE the fuel check, so the cells are
   * never live across any safepoint (call is not a safepoint, C
   * entries never preempt, fuel runs after the copy).  Per-hart, not
   * per-frame -- which is exactly why known saturated TAIL calls to
   * wide functions stay plain jumps (a tail call just overwrites the
   * cells; no stack-arg-area ownership problem).  MUST stay at offset
   * W: generated code addresses the cells tp-relative (Codegen.hs
   * spillRef).  This is the x64 a6/a7 TLS-cell mechanism promoted to
   * the portable convention. */
  sw argspill[FPR_ARGSPILL];
  /* the running actor's stack segment, as the function-entry check wants it
   * (Codegen.hs stackCheck): there is room iff  sp - stk_lo < stk_span
   * (unsigned).  stk_lo is the segment's low end plus the headroom C calls
   * need; 0 / ~0 means "not an actor's stack: never grow".  MUST stay at
   * offsets W*57 and W*58: generated code reads them tp-relative. */
  uw stk_lo, stk_span;
  uw id;
  fpr_pool_t pool;                /* boot/hart-loop allocs (pre-actor, never freed) */
  struct fpr_acb *current;        /* running actor, 0 = in the hart loop */
  struct fpr_acb *rq_head, *rq_tail; /* local run queue (owner-only) */
  uw sched_ctx[16];               /* the hart loop's context */
  volatile uw idle;               /* 1 while polling with nothing to run */
  volatile uw epoch;              /* hart-loop iteration count: the
                                   * quiescence clock for deferred
                                   * channel-block reuse (actors.c) */
  uw fuel_preempts;
  char rbuf[FPR_RBUF_SZ];         /* per-hart render buffer (str/print) */
  int rpos;
  /* two-tier bounded-latency scheduler (docs/SCHED-MODEL.md) */
  struct fpr_acb *bl_head, *bl_tail; /* ready backlog (owner-only) */
  uw bl_len;
  uw rq_len;
  uw lcg; /* per-hart deterministic PRNG state (weighted default tier) */
  struct fpr_pool *pool_override; /* Sys.arena: non-NULL while a scoped
                                   * arena pool shadows the actor's own
                                   * (appended field: nothing in the
                                   * asm contract addresses past fuel) */
  struct fpr_acb *slp_head; /* actors parked by Sys.sleepUs on this hart,
                             * each with a deadline; the hart loop wakes
                             * them (appended, owner-hart only) */
} fpr_hart_t;

/* the codegen contract for the spill cells: argspill[0] at exactly
 * one word past fuel.  If this fires, a field moved -- fix Codegen.hs
 * spillRef or move argspill back. */
_Static_assert(__builtin_offsetof(fpr_hart_t, argspill) == sizeof(sw),
               "argspill must sit at offset W (tp-relative, Codegen.hs)");
_Static_assert(__builtin_offsetof(fpr_hart_t, stk_lo) == sizeof(sw) * (1 + FPR_ARGSPILL) &&
               __builtin_offsetof(fpr_hart_t, stk_span) == sizeof(sw) * (2 + FPR_ARGSPILL),
               "stk_lo/stk_span must follow the spill cells (Codegen.hs stackCheck)");

extern fpr_hart_t fpr_harts[FPR_NHARTS];
/* how many hart blocks are LIVE this run (threads actually started):
 * FPR_NHARTS is the compile-time cap and the static array size; the
 * hosted boots (posix main.c, qosapp entry.c) may run fewer -- env
 * FPR_HARTS, or the host's resolved core count under qosp.  Scheduler
 * scans, the deadlock detector, and spawnOn bounds all use this. */
extern uw fpr_live_harts;

/* the hart that drains device irqs and the timer bridge: the LAST live
 * hart, so external interrupts land on an auxiliary hart and the prime
 * hart (0) keeps the latency-sensitive work.  Equals 0 on single-hart
 * machines.  Set once in fpr_actors_init, read by plic.c (context
 * selection) and the hart loop (drain gating). */
extern uw fpr_irq_hart;

#if defined(FPR_QOSAPP_SINGLE)
/* Darwin's TLV model has no stable displacement from TPIDR_EL0.  A
 * single-hart loaded image instead owns one plain hart cell. */
#define FPR_TLS
extern fpr_hart_t *fpr_posix_hart;
static inline fpr_hart_t *fpr_hart(void) { return fpr_posix_hart; }
#elif defined(FPR_QOSAPP)
/* a loaded QOS Portable app image (runtime/qosapp): fixed-slot with no
 * dynamic loader behind it -- nothing registers a TLS block for the
 * image, and link-time TLS constants would index the HOST's TCB at
 * meaningless offsets.  Two arch-specific answers:
 *
 * AArch64 (v3): x28 IS the hosted world's tp.  Generated
 * code never allocates it (the IR map is x19..x27 + x29), ctx_a64.S
 * neither saves nor restores it, and every app TU compiles with
 * -ffixed-x28, so the global register declaration below is exact:
 * set once per hart thread by fpr_set_tp, invariant across actor
 * switches and cross-hart migration -- bare metal's tp discipline,
 * with zero TLS and therefore zero Darwin/Linux TLV divergence.
 *
 * x86-64 (v2): BORROW THE HOST'S TLS -- qosp keeps one __thread
 * borrow block {hart, a6, a7} per hart thread and publishes its %fs
 * displacement in the boot record; entry.c lands it in fpr_g_tlsoff.
 * The displacement is identical in every thread (static TLS on
 * Linux, the only x64 host).  fpr_posix_hart/fpr_x64_a6/a7 are
 * lvalue MACROS over the block so shared sources read unchanged. */
#define FPR_TLS
#if defined(__aarch64__)
/* read x28 with a volatile asm (see the hosted AArch64 case below: C must
 * never save x28, so app C is compiled -ffixed-x27 as well, qos-app.mk) */
static inline fpr_hart_t *fpr_hart(void) { fpr_hart_t *h; __asm__ volatile("mov %0, x28" : "=r"(h)); return h; }
#else
extern uw fpr_g_tlsoff; /* entry.c: boot->tls_off */
static inline char *fpr_tls_blk(void) {
  return (char *)__builtin_thread_pointer() + fpr_g_tlsoff;
}
#define fpr_posix_hart (*(fpr_hart_t **)fpr_tls_blk())
#define fpr_x64_a6 (*(uw *)(fpr_tls_blk() + 8))
#define fpr_x64_a7 (*(uw *)(fpr_tls_blk() + 16))
static inline fpr_hart_t *fpr_hart(void) { return fpr_posix_hart; }
#endif
#elif defined(FPR_POSIX) && defined(__aarch64__) && defined(FPR_HART_X28)
/* hosted AArch64 (every fpr build; FPR_HART_X28 travels with
 * -ffixed-x28, without which clang refuses a register variable): x28 is the hart register, as it is for QOS apps above.
 * It used to be a __thread cell -- and an actor is a green thread that
 * MIGRATES between hart pthreads mid-function.  The compiler may compute a
 * thread-local's address once per function (on Darwin that is a call to
 * _tlv_get_addr, which it is entitled to reuse), so a C function that
 * switched away and resumed on another hart went on reading the OLD hart:
 * it saved itself into that hart's `current` (NULL: a fault in
 * fpr_ctx_switch; another actor: "not the current actor's handle") and ran
 * on that hart's scheduler stack.  x28 names the hart of the thread the
 * code is running on, always: fpr build compiles every C file
 * -ffixed-x28, ctx_a64.S neither saves nor restores it, libc preserves it
 * (callee-saved), and each hart thread sets it once (fpr_set_tp).
 * Generated code reads it too (Compile.hs applies deTlsQosAppA64). */
#define FPR_TLS
/* Read with a volatile asm: every read happens where it is written, so none
 * is carried across a switch.  And x28 must never be SAVED by C: AArch64
 * saves callee-saved registers in pairs, and Apple clang saves the whole
 * (x27, x28) pair in any function that uses x27, -ffixed-x28 or not.  A
 * function that saved x28 on hart 0's thread and returned after its actor
 * migrated restored hart 0's pointer onto hart 1's thread (fpr_apply, around
 * an actor's whole body: found by checking x28 against a thread-local shadow
 * when the body returned).  So every C file is compiled -ffixed-x27 as well
 * (compiler/Build.hs), and no C function needs that pair. */
static inline fpr_hart_t *fpr_hart(void) { fpr_hart_t *h; __asm__ volatile("mov %0, x28" : "=r"(h)); return h; }
#elif defined(FPR_POSIX)
/* hosted x86-64: no free per-thread register (fs belongs to libc TLS);
 * the SAME thread-local that X64.hs makes generated code load.  __thread:
 * each hart pthread carries its own, so actors see their OWNER hart's
 * block exactly as tp gives them on bare metal.  (A local-exec %fs load
 * reads the running thread's cell each time; there is no address for the
 * compiler to carry across a migration.) */
#define FPR_TLS __thread
extern __thread fpr_hart_t *fpr_posix_hart;
static inline fpr_hart_t *fpr_hart(void) { return fpr_posix_hart; }
#else
static inline fpr_hart_t *fpr_hart(void) {
  fpr_hart_t *h;
  __asm__("mv %0, tp" : "=r"(h));
  return h;
}
#endif

/* test-and-test-and-set with EXPONENTIAL BACKOFF (AMO acquire/release;
 * A is in imac).  The concurrency rule (docs/MEMORY.md): no spin site
 * may burn a hart at full rate -- a loser backs off exponentially
 * (capped) before retrying, so contention degrades bandwidth instead
 * of livelocking a core.  These locks are TRANSITIONAL: the end-state
 * moves each one behind an owning actor's mailbox (Memory.qa for
 * buddy/grants, ARC.qa for promotion) and deletes it -- see
 * docs/MEMORY-V2-PLAN.md.  Until then, backoff is the law here too. */
typedef struct { volatile uw v; } fpr_lock_t;
#define FPR_BACKOFF_CAP 1024 /* max pause iterations between retries */
static inline void fpr_backoff(uw *delay) {
  for (uw i = 0; i < *delay; i++) __asm__ volatile("nop");
  if (*delay < FPR_BACKOFF_CAP) *delay <<= 1;
}
static inline void fpr_lock(fpr_lock_t *l) {
  uw delay = 1;
  for (;;) {
    if (!__atomic_exchange_n(&l->v, 1, __ATOMIC_ACQUIRE)) return;
    while (__atomic_load_n(&l->v, __ATOMIC_RELAXED)) fpr_backoff(&delay);
  }
}
static inline void fpr_unlock(fpr_lock_t *l) {
  __atomic_store_n(&l->v, 0, __ATOMIC_RELEASE);
}

/* ---- the ONE freelist discipline (docs/MEMORY-V2-PLAN.md phase 1) --
 * Every recycled-block pool in the runtime is the same structure: a
 * locked LIFO of free blocks, each node carrying its capacity, taken
 * first-fit.  Fixed-size users (stacks, bucket arrays, channel
 * blocks) match every node trivially; the grant pool's variable
 * sizes use the capacity for real.  What stays at each call site is
 * POLICY: where a miss is filled from (buddy on a machine boot, the
 * loader's grant in process mode), telemetry, and any deferred-reuse
 * discipline layered on top (the chblk epoch limbo).  The node rides
 * the free block's first two words -- callers must not hand out
 * blocks smaller than one node. */
typedef struct fpr_flnode { struct fpr_flnode *next; uw cap; } fpr_flnode_t;
typedef struct { fpr_flnode_t *head; fpr_lock_t mu; } fpr_freelist_t;
void *fpr_fl_take(fpr_freelist_t *fl, uw want); /* first-fit; NULL = miss */
void fpr_fl_put(fpr_freelist_t *fl, void *p, uw cap);

/* ---- process loading (docs/PROCESS-LOADING.md) ------------------------
 * buddy.c: a power-of-two allocator over the reserved process arena
 * (_proc_arena_start.._proc_arena_end, defined in link.ld). Owned by
 * whichever image calls buddy_init -- System.qa, in this design.
 */
void buddy_init(void *base, uw size);
void *buddy_alloc(uw bytes);   /* NULL on exhaustion */
void *buddy_realloc(void *p, uw bytes);
void buddy_free(void *p);
uw buddy_arena_size(void);
uw buddy_free_bytes(void);
void *buddy_reserve_range(void *addr, uw bytes);
void buddy_release_range(void *addr, uw bytes);
uw buddy_block_usable_size(void *p);

extern char _proc_arena_start[], _proc_arena_end[]; /* boards with a linked process slot only */

/* The heap's span, decided at run time by the machine layer:
 *   [*lo, *hi)       what the buddy runs over
 *   [*lo, *span_hi)  what fpr_in_heap calls heap (a board's process slot
 *                    follows its heap; elsewhere span_hi == hi)
 * A board answers with its RAM.  A hosted system answers with a RESERVATION
 * of address space, committed by the OS page by page as it is touched, so
 * the heap has no size of its own.  hal_heap_release gives the pages of a
 * large free block back (weak no-op where there is nobody to give them to). */
void hal_heap_span(char **lo, char **hi, char **span_hi);
void hal_heap_release(void *p, uw bytes);
/* machine/posix: the largest span in [min, max] (halving) the system will
 * reserve, at `at` if given -- committed only as it is touched */
void *fpr_heap_reserve(void *at, uw max, uw min, uw *bytes);
extern char *fpr_heap_lo, *fpr_heap_hi;

/* the memory-growth grant a process's fpr_alloc asks for on bump
 * exhaustion (runtime.c) -- ptr NULL means denied. fpr_grow_memory is
 * NULL for a normal machine boot (unchanged hard-panic-on-exhaustion
 * behavior there); a loaded process's entry point wires it to a
 * callback into System.qa's buddy allocator. */
typedef struct { void *ptr; uw size; } fpr_grant_t;
extern fpr_grant_t (*fpr_grow_memory)(uw want_bytes);
fpr_grant_t fpr_grow_counted(uw want_bytes, uw site); /* the counted gateway;
  site names the caller (fpr_growsite_name): 1 slab, 2 slab-spare,
  3 buckets, 4 big-block, 5 stack -- attributed in the growlog ring */
const char *fpr_growsite_name(uw site);

/* ---- the MEMORY ACTOR (docs/MEMORY.md: Memory.qa, stage 1) ----------
 * The image that runs buddy_init (a machine boot, the qosp app over
 * the arena the host hands it) sets fpr_mem_own and spawns ONE actor
 * that owns the buddy: every block the runtime needs from actor
 * context -- slabs, stacks, acb and channel carves, ring growth, the
 * ARC table -- is a message to it (an Int request: no allocation on
 * the request path) and the reply lands in the requester's acb with a
 * wake, never in a mailbox that could be full.  Frees are one-way
 * messages.  Contexts with no actor to park (boot, the hart loop's
 * reaper, IRQ delivery), the memory actor itself, and a request that
 * could not be queued go to the buddy directly -- those direct
 * callers are why buddy_lock still exists (fpr_mem_direct counts
 * them).  A loaded process without its own buddy (fpr_mem_own == 0)
 * keeps the loader-grant path above. */
extern int fpr_mem_own;            /* 1: this image runs the buddy + the actor */
void *fpr_mem_take(uw bytes);      /* a buddy block (>= bytes usable); 0 = denied */
void *fpr_mem_take_direct(uw bytes); /* the same, never waits (under a spinlock) */
void fpr_mem_give(void *p);        /* one-way; safe from any context */
void fpr_mem_spawn(void);          /* actors.c: after actor 0, before any hart runs */
int fpr_hal_sleep_us(uw us);      /* the host sleep: Sys.sleepUs's fallback (runtime.c weak) */
extern uw fpr_mem_reqs, fpr_mem_waits, fpr_mem_direct, fpr_mem_frees, fpr_mem_denied,
    fpr_mem_inline; /* takes served on the spot (the lock was free) */

/* elfload.c: a minimal ELF32/ELF64 PT_LOAD segment loader. FIXED-SLOT
 * ONLY -- p_vaddr must already equal the intended physical load
 * address (no relocation is performed; see docs/PROCESS-LOADING.md for
 * why that is a real, stated scope limit, not an oversight). Segments
 * must fall entirely within [slot_base, slot_base+slot_size). */
typedef struct { void *entry; void *image_end; int ok; const char *err;
                 void *exec_end; /* high-water mark of PF_X PT_LOADs (0 if none) */
                 void *rw_start; /* low-water mark of PF_W PT_LOADs ((void*)-1 if
                                  * none); together these let a hosted loader
                                  * mprotect code r-x and leave data rw (macOS
                                  * arm64 forbids w+x on one page) */
} fpr_elf_load_t;

/* qaimg.c -- placing a QAR2 flat image (docs/QA-FORMAT.md).  The LOAD
 * section's TEXT is read in FP-RISC (QOS programs/mods/qaimg.fpr: the six
 * numbers, the sha line, the consistency refusals) by whoever is loading --
 * the portable host, an app attaching a plugin, the native kernel.  What is
 * left for C is the part that guards and performs a copy: the image must lie
 * inside the window it was given; then copy, and zero the tail. */
typedef struct { uw base, entry, execsz, rwoff, memsz; } fpr_qaimg_t;
fpr_elf_load_t fpr_qaimg_place(const fpr_qaimg_t *q, const unsigned char *img, uw img_len,
                               void *window, uw window_size);
/* the first n Ints of an FP-RISC List, for a C primitive handed numbers that
 * FP-RISC computed (qaimg.fpr's `nums`); 0 if the list is short or not Ints */
int fpr_list_ints(V list, uw *out, uw n);

/* proc_entry.c: compiled into an APP image (not the top-level boot).
 * Plain callable function -- ENTRY(fpr_process_entry) in link-app.ld
 * just points the ELF header's e_entry at it, no assembly needed. */
V fpr_process_entry(void *heap_base, uw heap_size, fpr_grant_t (*grow)(uw want_bytes),
                    const unsigned char *caps, uw caps_len,
                    sw (*syscall_fn)(uw, const char *, uw, char *, uw),
                    void *shared_boot); /* NULL = legacy nested scheduler */

/* actors.c: process-mode flags/result (see the essay in actors.c) */
extern volatile int fpr_is_process;
extern volatile int fpr_process_done;
V fpr_process_result_get(void);
V fpr_prim_fn_str(V v); /* runtime.c: render() a value to a String, same as `str`/print */
extern void fpr_hart_main(int id); /* actors.c: runs hart_loop; returns when fpr_process_done */
extern void fpr_actors_init(void); /* actors.c: sets up actor 0 on hart 0 */
void fpr_proc_arena_init(void);
void fpr_set_tp(fpr_hart_t *h); /* runtime.c */
/* park-forever, portably: rv wfi on metal, a libc pause when hosted
 * (only reached if hal_poweroff ever returns -- real-HW behavior) */
#ifdef FPR_POSIX
void fpr_park(void);
#define FPR_PARK() fpr_park()
#else
#define FPR_PARK() __asm__ volatile("wfi")
#endif
/* boot entry points (virt: called from crt0.S; posix: from main.c) */
void fpr_rt_init(void);          /* runtime.c: buddy, harts, actor 0 */
void fpr_hart_main(int id);      /* actors.c: hart 0's loop */
void fpr_hart_secondary(int id); /* actors.c: secondary hart's loop */
void fpr_ctx_fabricate(uw *ctx, void (*entry)(void), uw stack_top16,
                       fpr_hart_t *owner); /* ctx layer (virt/posix) */ /* process.c: buddy_init over _proc_arena_start.._end */

V fpr_alloc(V raw_bytes); /* runtime allocator; RAW byte count, not tagged */
V fpr_realloc(V obj, V raw_bytes); /* grow to a new payload size (copy-based;
                                    * the freed block recycles exactly) */
void fpr_free(V obj);     /* runtime-specific deallocation; not a recursive ADT drop */
int fpr_in_heap(V v);     /* heap pointer (promotable) vs int/immortal static */
V fpr_msg_copy(V v);      /* deep copy into the sender's message slab (packed) */
V fpr_msg_copy_fresh(V v); /* ... into a slab of its own (Sys.arena's transfer) */
fpr_slab_t **fpr_acb_msg_slot(struct fpr_acb *a); /* actors.c: the packing slab */
void fpr_slab_unhold(fpr_slab_t *sl, int locked); /* runtime.c: holds--, release
                                                   * when nothing keeps it */
void fpr_slabs_unhold(fpr_slab_t **sls, uw n);   /* the same, one lock */
void fpr_arc_incref(V v);
void fpr_arc_decref(V v);
uw fpr_arc_live(void);
V fpr_apply(V f, V a);
V fpr_applyN(V f, uw n, V *rargs);
V fpr_send_as(uw sender_key, V av, V m); /* Result Unit String: Ok queued */
int fpr_sent(V r);                          /* 1 when a send's Result is Ok */
void *fpr_syscall_mailbox(void);
V fpr_syscall_wait_result(void);
V fpr_mkresult(uw variant, const char *s);
V fpr_mkresultn(uw variant, const char *s, uw n);
void fpr_panic(V str_obj) __attribute__((noreturn));
void fpr_cpanic(const char *msg) __attribute__((noreturn));
/* the /logs rings (runtime.c): sev 0 normal / 1 warn / 2 error / 3 host */
void fpr_logput(int sev, const char *line, uw n);
/* #24: set by hosted entries (qosp) to persist a panic's last words */
extern void (*fpr_panic_persist)(const char *msg, uw n);
str_t *fpr_mkstr(const uint8_t *src, uw n);

void hal_putc(char c); /* hal.c: raw console for panics + runtime */
uint64_t hal_mtime(void); /* hal.c: the machine timer (actors.c has the weak zero) */
/* the stack guard (actors.c): a HAL that can make memory inaccessible does
 * so at a stack's low end, and reports the overflow by name when it faults */
/* Growable stacks (actors.c): generated code calls this when the entry check
 * fails; it answers the sp to continue on (a fresh, larger segment) or 0
 * (there was room after all -- the segment sp is in was not the newest).
 * fpr_stack_max is the POLICY ceiling on one actor's stack, all segments
 * together: run-away recursion is a named panic, not the machine's memory. */
uw fpr_stack_grow(void);
extern uw fpr_stack_max;
void hal_stack_guard(void *lo, uw size);
void hal_stack_unguard(void *lo, uw size);
void *fpr_current_stack(uw *id, uw *size);
void hal_poweroff(int code); /* hal.c: terminate the machine if the
                              * platform can (QEMU virt: sifive test
                              * finisher).  May return (real silicon:
                              * no-op); callers park in wfi after. */

/* static PAP definition helper: NAME must already be mangled */
#define FPR_FN(sym, cfn, ar) \
  const pap0_t sym = {T_PAP, 0, (uw)(uintptr_t)(cfn), (ar), 0}

/* SString: fixed 128-byte inline string (sstr.c). len is the live count. */
#define SSTR_CAP 128
typedef struct { uint32_t tid, var; uw len; uint8_t bytes[SSTR_CAP]; } __attribute__((aligned(8))) sstr_t;

#endif /* FPR_H */
